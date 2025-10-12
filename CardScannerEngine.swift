//
//  CardScannerEngine.swift
//  CardSenseApp
//
//  Created by Carlin Jon Soorenian on 10/7/25.
//
// CardScannerEngine.swift — fast + stable top/bottom OCR with rectangle correction
//
//  CardScannerEngine.swift
//  CardSenseApp
//
//  Created by Carlin Jon Soorenian on 10/7/25.
//
//
//  CardScannerEngine.swift
//  Multilingual (JP + EN) scanning with minimal churn
//
//  - Keeps your top/bottom ROIs, rectangle+dwell gate, cadence limiter, consensus smoothing
//  - Two-pass OCR per ROI: mixed hints + auto-detect → JP-only (or EN-only) fallback
//  - Name uses tallest-line heuristic to avoid tiny "Evolves from ..." text
//  - Returns ScanHit(name:number:) exactly like before
//

import Foundation
import Vision
import CoreImage
import CoreMedia
import CoreImage.CIFilterBuiltins
import QuartzCore   // CACurrentMediaTime()

// MARK: - Sliding-window consensus

final class Consensus<T: Hashable> {
    private let k: Int
    private var buf: [T] = []
    init(k: Int = 7) { self.k = max(1, k) }
    func push(_ v: T) { buf.append(v); if buf.count > k { buf.removeFirst(buf.count - k) } }
    var best: T? {
        guard !buf.isEmpty else { return nil }
        let counts = buf.reduce(into: [T:Int]()) { $0[$1, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }
    func clear() { buf.removeAll() }
}

// MARK: - Tuning

private struct Tune {
    // Rectangle detector + dwell gate
    static let minAspect: Float = 0.62
    static let maxAspect: Float = 0.90
    static let minSize:   Float = 0.10
    static let iouThresh: CGFloat = 0.25      // allow some slack vs. dashed frame
    static let dwellSeconds: CFTimeInterval = 1.0

    // Frame cadence limiter
    static let minGap: CFTimeInterval = 0.28

    // OCR thresholds
    static let needNameConf: Float = 0.45
    static let needNumConf:  Float = 0.40
}

// MARK: - Helpers

private extension String {
    /// Detects any Japanese script (Hiragana, Katakana incl. half-width, Kanji, 々/〆/ヵ/ヶ/ー).
    var containsJapaneseScript: Bool {
        range(of: #"[ぁ-んァ-ンｦ-ﾟ一-龯々〆ヵヶー]"#, options: .regularExpression) != nil
    }
    var isMostlyNumericLike: Bool {
        let digits = filter { $0.isNumber }.count
        return digits >= max(3, count / 2)
    }
}

// MARK: - Engine

public final class CardScannerEngine {

    private let ciContext = CIContext()
    private let handlerOpts: [VNImageOption: Any] = [:]

    // Smoothers
    private let nameVote = Consensus<String>(k: 7)
    private let numVote  = Consensus<String>(k: 7)

    // Cadence & dwell
    private var last: CFTimeInterval = 0
    private var dwellStart: CFTimeInterval?

    // Guide frame (normalized). Matches your dashed frame: x:18% y:10% w:64% h:80%
    private let frameROI = CGRect(x: 0.18, y: 0.10, width: 0.64, height: 0.80)

    // Language hints
    private let mixedHints = ["ja-JP", "ja", "en-US", "en"]
    private let jaHints    = ["ja-JP", "ja"]
    private let enHints    = ["en-US", "en"]

    private let languages: [String]
    public init(languages: [String] = ["ja-JP","ja","en-US","en"]) {
        self.languages = languages.isEmpty ? ["ja-JP","ja","en-US","en"] : languages
    }

    public func reset() {
        nameVote.clear()
        numVote.clear()
        dwellStart = nil
        last = 0
    }

    // MARK: - Main

    public func process(sampleBuffer: CMSampleBuffer) -> ScanHit? {
        let now = CACurrentMediaTime()
        guard now - last >= Tune.minGap else { return nil }
        last = now

        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        var ci = CIImage(cvImageBuffer: pixel)
        ci = preprocess(ci)

        // 1) Detect rectangle + dwell gate
        let detect = VNDetectRectanglesRequest()
        detect.minimumAspectRatio   = Tune.minAspect
        detect.maximumAspectRatio   = Tune.maxAspect
        detect.minimumSize          = Tune.minSize
        detect.maximumObservations  = 1
        if #available(iOS 16.0, *) { detect.minimumConfidence = 0.2 }

        var rectObs: VNRectangleObservation?
        do {
            try VNImageRequestHandler(ciImage: ci, options: handlerOpts).perform([detect])
            rectObs = detect.results?.first as? VNRectangleObservation
        } catch {
            rectObs = nil
        }

        let paddedFrame = frameROI.insetBy(dx: -0.04, dy: -0.04)
        if let r = rectObs {
            let overlap = intersectionOverUnion(r.boundingBox, paddedFrame)
            if overlap >= Tune.iouThresh {
                if dwellStart == nil { dwellStart = now }
            } else {
                dwellStart = nil
            }
        } else {
            dwellStart = nil
        }
        // Require dwell to actually emit a hit; proceed with OCR but no emit until settled:
        let dwellSatisfied = (dwellStart != nil) && (now - (dwellStart ?? now) >= Tune.dwellSeconds)

        // 2) Perspective-correct (or center fallback)
        var corrected: CIImage
        if let r = rectObs {
            corrected = perspectiveCorrect(ci, rect: r)
            if !rectIsUsable(corrected.extent) { corrected = centerFallback(ci) }
        } else {
            corrected = centerFallback(ci)
        }
        if corrected.extent.width > corrected.extent.height { corrected = corrected.oriented(.left) }
        guard rectIsUsable(corrected.extent) else { return nil }

        // 3) ROIs (pixel space) — BLUE name band & GREEN number band
        let ext = corrected.extent
        let W = ext.width, H = ext.height
        let nameBand = CGRect(x: W*0.06, y: H*0.76, width: W*0.62, height: H*0.18)
        let numBand  = CGRect(x: W*0.06, y: H*0.06, width: W*0.46, height: H*0.16)

        // ---- NAME: two-pass ----
        var nameResult = ocrName(corrected, roiPixel: nameBand, hints: mixedHints, autodetect: true)
        if (nameResult?.1 ?? 0) < Tune.needNameConf || (nameResult?.0.containsJapaneseScript ?? false) {
            if let r2 = ocrName(corrected, roiPixel: nameBand, hints: jaHints, autodetect: false),
               r2.1 >= (nameResult?.1 ?? 0) {
                nameResult = r2
            }
        } else {
            if (nameResult?.1 ?? 0) < (Tune.needNameConf + 0.10),
               let r2 = ocrName(corrected, roiPixel: nameBand, hints: enHints, autodetect: false),
               r2.1 > (nameResult?.1 ?? 0) {
                nameResult = r2
            }
        }

        // ---- NUMBER: two-pass ----
        var numResult = ocrAll(corrected, roiPixel: numBand, hints: mixedHints, autodetect: true)
        if (numResult?.1 ?? 0) < Tune.needNumConf {
            if let r2 = ocrAll(corrected, roiPixel: numBand, hints: enHints, autodetect: false),
               r2.1 >= (numResult?.1 ?? 0) {
                numResult = r2
            }
        }

        // Optional widen if weak
        var nameBest = cleanName(nameResult?.0)
        var nameConf = nameResult?.1 ?? 0
        var rawNum   = extractNumberRaw(numResult?.0 ?? "")
        var shortNum = reduceLeftNumber(rawNum)
        var numConf  = numResult?.1 ?? 0

        if (nameBest == nil || nameConf < Tune.needNameConf) || (shortNum == nil || numConf < Tune.needNumConf) {
            let nameWide = inflate(nameBand, w: W, h: H, dx: 0.04, dy: 0.02)
            let numWide  = inflate(numBand,  w: W, h: H, dx: 0.03, dy: 0.00)

            var nm = ocrName(corrected, roiPixel: nameWide, hints: mixedHints, autodetect: true)
            if (nm?.1 ?? 0) < Tune.needNameConf || (nm?.0.containsJapaneseScript ?? false) {
                if let r2 = ocrName(corrected, roiPixel: nameWide, hints: jaHints, autodetect: false),
                   r2.1 >= (nm?.1 ?? 0) { nm = r2 }
            } else if (nm?.1 ?? 0) < (Tune.needNameConf + 0.10) {
                if let r2 = ocrName(corrected, roiPixel: nameWide, hints: enHints, autodetect: false),
                   r2.1 > (nm?.1 ?? 0) { nm = r2 }
            }
            if let n2 = nm, n2.1 > nameConf { nameBest = cleanName(n2.0); nameConf = n2.1 }

            var nb = ocrAll(corrected, roiPixel: numWide, hints: mixedHints, autodetect: true)
            if (nb?.1 ?? 0) < Tune.needNumConf {
                if let r2 = ocrAll(corrected, roiPixel: numWide, hints: enHints, autodetect: false),
                   r2.1 >= (nb?.1 ?? 0) { nb = r2 }
            }
            if let m2 = nb, m2.1 > numConf {
                rawNum   = extractNumberRaw(m2.0) ?? rawNum
                shortNum = reduceLeftNumber(rawNum) ?? shortNum
                numConf  = m2.1
            }
        }

        // Last-ditch number sweep
        if shortNum == nil || numConf < Tune.needNumConf {
            let fullBottom = CGRect(x: W*0.04, y: H*0.02, width: W*0.92, height: H*0.20)
            if let sweep = ocrAll(corrected, roiPixel: fullBottom, hints: enHints, autodetect: false),
               let r = extractNumberRaw(sweep.0) {
                rawNum   = r
                shortNum = reduceLeftNumber(r)
                numConf  = max(numConf, sweep.1)
            }
        }

        // Stabilize
        if let n = nameBest, !n.isEmpty { nameVote.push(n) }
        if let m = shortNum, !m.isEmpty { numVote.push(m) }

        guard dwellSatisfied else { return nil } // only emit after dwell is satisfied

        guard let lockedName = nameVote.best ?? nameBest,
              let lockedNum  = numVote.best  ?? shortNum else { return nil }

        // Use your existing ScanHit initializer (not redeclared here)
        return ScanHit(name: lockedName, number: lockedNum)
    }

    // MARK: - OCR helpers

    /// Name OCR that prefers tallest/confident line (title), skips "Evolves from ..." noise.
    private func ocrName(_ image: CIImage,
                         roiPixel: CGRect,
                         hints: [String],
                         autodetect: Bool) -> (String, Float)? {
        guard let (text, conf, _) = ocrTallestLine(image, roiPixel: roiPixel, hints: hints, autodetect: autodetect) else {
            return nil
        }
        let cleaned = cleanName(text) ?? text
        return (cleaned, conf)
    }

    /// Returns joined text + max confidence (for number sweeps).
    private func ocrAll(_ image: CIImage,
                        roiPixel: CGRect,
                        hints: [String],
                        autodetect: Bool) -> (String, Float)? {
        let norm = normalize(roiPixel, in: image.extent)
        guard norm.width > 0, norm.height > 0 else { return nil }
        let req = makeRequest(hints: hints, autodetect: autodetect)
        req.regionOfInterest = norm
        let h = VNImageRequestHandler(ciImage: image, options: handlerOpts)
        try? h.perform([req])
        let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
        var joined = ""
        var conf: Float = 0
        for o in obs {
            if let t = o.topCandidates(1).first {
                joined += " " + t.string
                conf = max(conf, Float(t.confidence))
            }
        }
        joined = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : (joined, conf)
    }

    /// Pick tallest line (good proxy for card title) with tie-break on confidence.
    private func ocrTallestLine(_ image: CIImage,
                                roiPixel: CGRect,
                                hints: [String],
                                autodetect: Bool) -> (String, Float, CGFloat)? {
        let norm = normalize(roiPixel, in: image.extent)
        guard norm.width > 0, norm.height > 0 else { return nil }
        let req = makeRequest(hints: hints, autodetect: autodetect)
        req.regionOfInterest = norm
        let h = VNImageRequestHandler(ciImage: image, options: handlerOpts)
        try? h.perform([req])

        let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
        var best: (String, Float, CGFloat)?
        for o in obs {
            guard let t = o.topCandidates(1).first else { continue }
            var s = t.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if s.isMostlyNumericLike { continue }
            // Skip tiny English template text; avoid stripping JP glyphs.
            if s.range(of: #"(?i)\bevolves\s+from\b"#, options: .regularExpression) != nil { continue }

            let lineH = o.boundingBox.height // normalized [0,1]
            let conf  = Float(t.confidence)
            if let b = best {
                if lineH > b.2 + 0.01 || (abs(lineH - b.2) <= 0.01 && conf > b.1) {
                    best = (s, conf, lineH)
                }
            } else {
                best = (s, conf, lineH)
            }
        }
        return best
    }

    private func makeRequest(hints: [String], autodetect: Bool) -> VNRecognizeTextRequest {
        let r = VNRecognizeTextRequest(completionHandler: nil)
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        r.minimumTextHeight = 0.015
        if #available(iOS 16.0, *) {
            r.automaticallyDetectsLanguage = autodetect
            r.usesCPUOnly = false
            r.customWords = [
                // EN
                "Pokemon","Pokémon","GX","EX","VSTAR","V-UNION","SAR","AR","CHR","HP",
                "Charizard","Pikachu",
                // JP (tokens help model focus; non-destructive)
                "ポケモン","GX","EX","VSTAR","V-UNION","SAR","AR","CHR","ＨＰ","リザードン","ピカチュウ"
            ]
        }
        // Use the provided hints if any, else defaults
        r.recognitionLanguages = hints.isEmpty ? mixedHints : hints
        return r
    }

    // MARK: - Text cleanup & numbers

    private func cleanName(_ s: String?) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // Remove obvious EN UI tokens without harming JP text
        t = t.replacingOccurrences(of: #"(?i)\b(BASIC|STAGE\s*[12]|RESTORED|VSTAR|V-UNION)\b"#,
                                   with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)HP\s*\d{2,3}"#,
                                   with: "", options: .regularExpression)
        // Normalize whitespace
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func extractNumberRaw(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        let patterns = [
            #"(?i)\b\d{1,3}\s*/\s*\d{1,3}\b"#,                               // 096/165
            #"(?i)\bS?V?P?[- ]?(EN|JP|ES|FR|DE|IT|PT|KO|ZH)\s*-?\s*\d{1,4}\b"#, // SVP-EN123
            #"(?i)\bSWSH\s*\d{1,4}\b"#,
            #"(?i)\bNo\.?\s*\d{1,4}\b"#
        ]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression) {
                return String(s[r]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func stripLeadingZeros(_ s: String) -> String {
        let noZeros = s.replacingOccurrences(of: "^0+(?=\\d)", with: "", options: .regularExpression)
        return noZeros.isEmpty ? "0" : noZeros
    }

    private func reduceLeftNumber(_ raw: String?) -> String? {
        guard var raw = raw else { return nil }
        raw = raw.replacingOccurrences(of: " ", with: "")

        // 1) fraction like 096/165 → take left part
        if let _ = raw.range(of: #"^\d{1,3}/\d{1,3}$"#, options: .regularExpression) {
            let left = raw.split(separator: "/").first.map { String($0) } ?? ""
            return stripLeadingZeros(left)
        }

        // 2) No. 0123 → digits only
        if let r = raw.range(of: #"^No\.?\s*\d{1,4}$"#, options: .regularExpression) {
            let digits = raw[r]
                .replacingOccurrences(of: "No.", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "\\D", with: "", options: .regularExpression)
            return stripLeadingZeros(digits)
        }

        // 3) Promo/code → trailing digits
        if let r = raw.range(of: #"S(WSH|V|VP)?[- ]?(EN|JP|ES|FR|DE|IT|PT|KO|ZH)-?\d{1,4}"#, options: .regularExpression) {
            let str = String(raw[r])
            if let m = str.range(of: #"\d{1,4}$"#, options: .regularExpression) {
                return stripLeadingZeros(String(str[m]))
            }
        }

        // 4) Fallback first 1–3 digit token
        if let m = raw.range(of: #"\b\d{1,3}\b"#, options: .regularExpression) {
            return stripLeadingZeros(String(raw[m]))
        }
        return nil
    }

    // MARK: - Geometry

    private func rectIsUsable(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite &&
        r.width.isFinite && r.height.isFinite &&
        r.width > 8 && r.height > 8
    }

    private func normalize(_ roi: CGRect, in extent: CGRect) -> CGRect {
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            return .zero
        }
        let x = max(0, min(1, roi.origin.x / extent.width))
        let y = max(0, min(1, roi.origin.y / extent.height))
        let w = max(0, min(1, roi.width  / extent.width))
        let h = max(0, min(1, roi.height / extent.height))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func inflate(_ r: CGRect, w: CGFloat, h: CGFloat, dx: CGFloat, dy: CGFloat) -> CGRect {
        let x = max(0, r.minX - dx * w)
        let y = max(0, r.minY - dy * h)
        let W = max(0.0, min(w, r.maxX + dx * w) - x)
        let H = max(0.0, min(h, r.maxY + dy * h) - y)
        return CGRect(x: x, y: y, width: W, height: H)
    }

    private func perspectiveCorrect(_ image: CIImage, rect: VNRectangleObservation) -> CIImage {
        let pts = [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]
        guard pts.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return image }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = image
        func pt(_ n: CGPoint) -> CGPoint {
            CGPoint(x: n.x * image.extent.width, y: n.y * image.extent.height)
        }
        f.topLeft     = pt(rect.topLeft)
        f.topRight    = pt(rect.topRight)
        f.bottomLeft  = pt(rect.bottomLeft)
        f.bottomRight = pt(rect.bottomRight)
        return f.outputImage ?? image
    }

    private func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return interArea / max(unionArea, 1e-6)
    }

    private func centerFallback(_ image: CIImage) -> CIImage {
        let W = image.extent.width
        let H = image.extent.height
        guard W.isFinite, H.isFinite, W > 0, H > 0 else { return image }
        let w = max(32, W * 0.62)
        let h = max(32, min(H * 0.85, w / 0.72))
        let x = max(0, (W - w) / 2)
        let y = max(0, (H - h) / 2)
        let crop = CGRect(x: x, y: y, width: min(w, W - x), height: min(h, H - y))
        if crop.width <= 0 || crop.height <= 0 { return image }
        return image.cropped(to: crop)
    }

    // MARK: - Preprocess

    private func preprocess(_ img: CIImage) -> CIImage {
        var image = img
        let opts: [CIImageAutoAdjustmentOption: Any] = [.enhance: true]
        for f in image.autoAdjustmentFilters(options: opts) {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }
        let color = CIFilter.colorControls()
        color.inputImage = image
        color.saturation = 0.0
        color.contrast = 1.18
        image = color.outputImage ?? image

        let sharp = CIFilter.sharpenLuminance()
        sharp.inputImage = image
        sharp.sharpness = 0.45
        image = sharp.outputImage ?? image

        let denoise = CIFilter.noiseReduction()
        denoise.inputImage = image
        denoise.noiseLevel = 0.02
        denoise.sharpness = 0.4
        return denoise.outputImage ?? image
    }
}
