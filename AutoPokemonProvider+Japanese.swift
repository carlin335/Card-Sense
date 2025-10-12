//
//  AutoPokemonProvider+Japanese.swift
//  CardSense
//
//  Created by Carlin Jon Soorenian on 10/10/25.
//
//
//  AutoPokemonProvider+Japanese.swift
//
//  One-file, zero-UI auto-router for Pokémon EN/JA search
//  - Auto-routes to Japanese provider if the query contains Japanese script
//  - Japanese provider uses TCGdex v2 (ja-locale) with USD/EUR pricing
//  - No changes to existing models/views/providers
//
//  AutoPokemonProvider+Japanese.swift
//  JP searches use multiple APIs in parallel and merge results.
//  - PokemonTCG.io v2 (foreignData.name:"<JP>")  [optional API key]
//  - TCGdex v2 (locale: ja)
//  Prices/Badges resolve from the source that produced the card.

import Foundation
import CoreFoundation

// MARK: - Lightweight logging

#if DEBUG
@inline(__always) private func JPLOG(_ msg: @autoclosure () -> String) { print("JPProvider:", msg()) }
#else
@inline(__always) private func JPLOG(_ msg: @autoclosure () -> String) {}
#endif

// MARK: - String helpers

private extension String {
    /// True if the string contains any Japanese script (Hiragana/Katakana/Kanji)
    var containsJapaneseScript: Bool {
        range(of: #"[ぁ-んァ-ンｦ-ﾟ一-龯々〆ヵヶー]"#, options: .regularExpression) != nil
    }

    /// Normalize common OCR noise and separators found in JP searches
    var jpNormalized: String {
        // 1) collapse whitespace; 2) convert full-width space to regular; 3) strip common mid-dots & slashes; 4) trim
        let s1 = self.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "　", with: " ") // full-width space
        let s2 = s1.replacingOccurrences(of: "[·•・／/，,。．.、:：;；'’\"“”`´^~〜-]", with: " ", options: .regularExpression)
        return s2.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Utilities

private enum HTTPDump {
    static func peek(_ data: Data, prefix: String, cap: Int = 240) {
        let s = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        JPLOG("\(prefix): \(s.prefix(cap))")
    }
}

// MARK: - Public router

enum CardLocaleRoute { case en, ja }

/// Drop-in provider that the app can call directly. When the user types Japanese,
/// this provider queries multiple JP APIs in parallel and merges the results.
/// Prices/badges route back to the right source transparently.
struct AutoPokemonProvider {

    // Track which locale (en/ja) we believe a given id belongs to
    private actor RouteMap {
        private var m: [String: CardLocaleRoute] = [:]
        func seed(_ cards: [UICard], as r: CardLocaleRoute) { for c in cards { m[c.id] = r } }
        func get(_ id: String) -> CardLocaleRoute? { m[id] }
    }
    private static let routeMap = RouteMap()

    // Track which backend produced a given id (for prices/badges)
    private enum Source { case ptcg, tcgdex }
    private actor SourceMap {
        private var m: [String: Source] = [:]
        func seed(_ cards: [UICard], _ s: Source) { for c in cards { m[c.id] = s } }
        func get(_ id: String) -> Source? { m[id] }
    }
    private static let srcMap = SourceMap()

    // MARK: Search

    /// Unified search. If the input contains JP script, run all JP sources in parallel and merge.
    /// If not, return empty (so your EN provider can handle non-JP queries as usual).
    static func search(text: String, number: String?, rarity: String?) async throws -> [UICard] {
        let query = text.jpNormalized
        guard query.containsJapaneseScript else {
            JPLOG("Non-JP input; JP router returns [] so EN path can handle.")
            return []
        }

        JPLOG("JP search: \"\(query)\" number=\(number ?? "-")")

        async let pkmn = JP_PokemonTCG.search(nameJP: query, number: number)    // PokemonTCG.io
        async let dex  = JP_TCGdex.search(name: query, number: number)          // TCGdex

        let (a, b) = try await (pkmn, dex)

        // Prefer PokemonTCG.io results, then append unique TCGdex hits
        let merged = mergeUnique(primary: a, secondary: b)

        await routeMap.seed(merged, as: .ja)
        await srcMap.seed(a, .ptcg)
        await srcMap.seed(b, .tcgdex)

        JPLOG("JP merged results: \(merged.count) (PTCG: \(a.count), TCGdex: \(b.count))")
        return merged
    }

    // MARK: Prices / Badges

    static func loadPrices(forID id: String) async throws -> [PriceRow] {
        if let s = await srcMap.get(id) {
            switch s {
            case .ptcg:   return try await JP_PokemonTCG.loadPrices(forID: id)
            case .tcgdex: return try await JP_TCGdex.loadPrices(forID: id)
            }
        }
        // Unknown producer; try both gracefully
        if let rows = try? await JP_PokemonTCG.loadPrices(forID: id) { return rows }
        return try await JP_TCGdex.loadPrices(forID: id)
    }

    static func fetchPriceBadge(id: String) async throws -> PriceBadge? {
        if let s = await srcMap.get(id) {
            switch s {
            case .ptcg:   return try await JP_PokemonTCG.fetchPriceBadge(id: id)
            case .tcgdex: return try await JP_TCGdex.fetchPriceBadge(id: id)
            }
        }
        if let b = try? await JP_PokemonTCG.fetchPriceBadge(id: id) { return b }
        return try await JP_TCGdex.fetchPriceBadge(id: id)
    }

    // MARK: Merge helper
    private static func mergeUnique(primary: [UICard], secondary: [UICard]) -> [UICard] {
        var seen = Set<String>()
        var out: [UICard] = []
        out.reserveCapacity(primary.count + secondary.count)
        for c in primary where seen.insert(c.id).inserted { out.append(c) }
        for c in secondary where seen.insert(c.id).inserted { out.append(c) }
        return out
    }
}

// ============================================================================
// Source A (Primary): PokemonTCG.io v2 using foreignData.name:"<JP>"
// ============================================================================

private enum JP_PokemonTCG {

    private enum Net { static let api = URL(string: "https://api.pokemontcg.io/v2")! }
    private enum Limits {
        static let reqTimeout: TimeInterval = 12
        static let resTimeout: TimeInterval = 22
        static let retries = 2
        static let pageSize = 64
    }

    private static let decoder = JSONDecoder()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = Limits.reqTimeout
        c.timeoutIntervalForResource = Limits.resTimeout
        c.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Encoding": "gzip, deflate",
            "User-Agent": "CardSense/1.0 (iOS) JPPtcg"
        ]
        return URLSession(configuration: c)
    }()

    /// API key read from Info.plist (`POKEMONTCG_API_KEY`) or environment. If absent, we skip this source.
    private static var apiKey: String? {
        (Bundle.main.object(forInfoDictionaryKey: "POKEMONTCG_API_KEY") as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? ProcessInfo.processInfo.environment["POKEMONTCG_API_KEY"]
    }

    // Models
    struct CardList: Decodable { let data: [Card] }
    struct OneCard: Decodable { let data: Card }
    struct Card: Decodable {
        let id: String
        let name: String
        let number: String?
        let images: Images
        let tcgplayer: TCGPlayerInfo?
        let cardmarket: CardmarketInfo?
        struct Images: Decodable { let small: String; let large: String }
        struct TCGPlayerInfo: Decodable {
            let url: String?
            let prices: [String: PriceSlice]?
            struct PriceSlice: Decodable { let market: Double?; let mid: Double?; let low: Double? }
        }
        struct CardmarketInfo: Decodable {
            let url: String?
            let prices: CMPrices?
            struct CMPrices: Decodable { let trendPrice: Double?; let averageSellPrice: Double?; let lowPrice: Double? }
        }
    }

    static func search(nameJP: String, number: String?) async throws -> [UICard] {
        guard let key = apiKey, !key.isEmpty else {
            JPLOG("PokemonTCG.io key missing; skipping PTCG source.")
            return []
        }

        var clauses = [
            #"foreignData.name:"\#(nameJP)""#,
            #"foreignData.language:"Japanese""#
        ]
        if let n = number?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            clauses.append(#"number:"\#(n)""#)
        }
        // Also OR against main name field (some entries mirror JP name there)
        let q = "(" + clauses.joined(separator: " AND ") + ") OR name:\"\(nameJP)\""

        var comps = URLComponents(url: Net.api.appendingPathComponent("cards"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "q", value: q),
            .init(name: "orderBy", value: "name"),
            .init(name: "pageSize", value: String(Limits.pageSize))
        ]

        let data = try await getJSON(comps.url!, apiKey: key)
        let list = (try? decoder.decode(CardList.self, from: data).data)
            ?? (try? decoder.decode(OneCard.self, from: data).data).map { [$0] }
            ?? []

        JPLOG("PTCG returned \(list.count)")
        return list.map { c in
            UICard(
                id: c.id,
                game: .pokemon,
                name: c.name,                          // EN display name; API has JP in foreignData
                number: c.number,
                setCode: nil,
                imageSmallURL: URL(string: c.images.small),
                imageLargeURL: URL(string: c.images.large),
                apiURL: Net.api.appendingPathComponent("cards/\(c.id)"),
                webURL: URL(string: c.tcgplayer?.url ?? c.cardmarket?.url ?? ""),
                priceUSD: c.tcgplayer?.prices?.values.compactMap { $0.market }.first.map { String(format: "%.2f", $0) },
                priceEUR: c.cardmarket?.prices?.trendPrice.map { String(format: "%.2f", $0) },
                sets: nil,
                rarity: nil,
                setName: nil
            )
        }
    }

    static func loadPrices(forID id: String) async throws -> [PriceRow] {
        guard let key = apiKey, !key.isEmpty else { return [] }
        let c = try await getCard(id: id, apiKey: key)
        var rows: [PriceRow] = []
        if let tp = c.tcgplayer, let url = URL(string: tp.url ?? "") {
            if let m = tp.prices?.values.compactMap({ $0.market }).first { rows.append(.init(source: "TCGplayer", label: "Market", value: String(format: "$%.2f", m), url: url)) }
            if let mid = tp.prices?.values.compactMap({ $0.mid }).first { rows.append(.init(source: "TCGplayer", label: "Mid", value: String(format: "$%.2f", mid), url: url)) }
            if let low = tp.prices?.values.compactMap({ $0.low }).first { rows.append(.init(source: "TCGplayer", label: "Low", value: String(format: "$%.2f", low), url: url)) }
        }
        if let cm = c.cardmarket, let url = URL(string: cm.url ?? "") {
            if let t = cm.prices?.trendPrice { rows.append(.init(source: "Cardmarket", label: "Trend", value: String(format: "€%.2f", t), url: url)) }
            if let a = cm.prices?.averageSellPrice { rows.append(.init(source: "Cardmarket", label: "Avg", value: String(format: "€%.2f", a), url: url)) }
            if let l = cm.prices?.lowPrice { rows.append(.init(source: "Cardmarket", label: "Low", value: String(format: "€%.2f", l), url: url)) }
        }
        return rows
    }

    static func fetchPriceBadge(id: String) async throws -> PriceBadge? {
        guard let key = apiKey, !key.isEmpty else { return nil }
        let c = try await getCard(id: id, apiKey: key)
        let usd = c.tcgplayer?.prices?.values.compactMap { $0.market }.first
        let eur = c.cardmarket?.prices?.trendPrice
        if usd == nil && eur == nil { return nil }
        return PriceBadge(
            usd: usd.map { String(format: "%.2f", $0) },
            eur: eur.map { String(format: "%.2f", $0) }
        )
    }

    // -- HTTP helpers

    private static func getCard(id: String, apiKey: String) async throws -> Card {
        var comps = URLComponents(url: Net.api.appendingPathComponent("cards"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [ .init(name: "q", value: #"id:"\#(id)""#) ]
        let data = try await getJSON(comps.url!, apiKey: apiKey)
        if let many = try? decoder.decode(CardList.self, from: data).data.first { return many }
        return try decoder.decode(OneCard.self, from: data).data
    }

    private static func getJSON(_ url: URL, apiKey: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        let (d, r) = try await session.data(for: req)
        guard let http = r as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        JPLOG("PTCG HTTP \(http.statusCode) \(url.absoluteString)")
        if !(200..<300).contains(http.statusCode) { HTTPDump.peek(d, prefix: "PTCG body"); throw URLError(.badServerResponse) }
        return d
    }
}

// ============================================================================
// Source B (Fallback): TCGdex v2 / ja
// ============================================================================

private enum JP_TCGdex {

    private enum Net {
        static let api  = URL(string: "https://api.tcgdex.net/v2/ja")!
        static let site = URL(string: "https://www.tcgdex.net/ja")!
    }
    private enum Limits {
        static let reqTimeout: TimeInterval = 10
        static let resTimeout: TimeInterval = 22
        static let retries = 2
    }

    private static let decoder = JSONDecoder()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = Limits.reqTimeout
        c.timeoutIntervalForResource = Limits.resTimeout
        c.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Language": "ja",
            "Accept-Encoding": "gzip, deflate",
            "User-Agent": "CardSense/1.0 (iOS) JPTcgDex"
        ]
        return URLSession(configuration: c)
    }()

    struct SearchWrap: Decodable { let data: [Brief] }
    struct Brief: Decodable {
        let id: String
        let localId: String?
        let name: String
        let image: String?
        let images: Images?
        struct Images: Decodable { let small: String?; let large: String? }

        var asUICard: UICard {
            let small = URL(string: images?.small ?? image ?? "")
            let large = URL(string: images?.large ?? image ?? "")
            return UICard(
                id: id, game: .pokemon, name: name, number: localId, setCode: nil,
                imageSmallURL: small, imageLargeURL: large,
                apiURL: Net.api.appendingPathComponent("cards/\(id)"),
                webURL: Net.site.appendingPathComponent("card/\(id)"),
                priceUSD: nil, priceEUR: nil, sets: nil, rarity: nil, setName: nil
            )
        }
    }

    struct Detail: Decodable {
        let pricing: Pricing?
        struct Pricing: Decodable {
            let cardmarket: Cardmarket?
            let tcgplayer: TCGplayer?
            struct Cardmarket: Decodable { let trend: Double?; let avg: Double?; let avg30: Double?; let low: Double? }
            struct TCGplayer: Decodable {
                let market: Double?; let mid: Double?; let low: Double?
                let normal: Slice?; let holo: Slice?; let reverse: Slice?
                struct Slice: Decodable { let marketPrice: Double?; let midPrice: Double?; let lowPrice: Double? }
                var bestMarket: Double? { normal?.marketPrice ?? holo?.marketPrice ?? reverse?.marketPrice ?? market }
                var bestMid: Double?    { normal?.midPrice ?? holo?.midPrice ?? reverse?.midPrice ?? mid }
                var bestLow: Double?    { normal?.lowPrice ?? holo?.lowPrice ?? reverse?.lowPrice ?? low }
            }
        }
    }

    static func search(name: String, number: String?) async throws -> [UICard] {
        // Try by localId (number), then name, then q fuzzy
        if let n = number?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            if let list = try? await fetchCards(params: ["localId": n]), !list.isEmpty { return list.map { $0.asUICard } }
        }
        if let list = try? await fetchCards(params: ["name": name]), !list.isEmpty { return list.map { $0.asUICard } }
        if let list = try? await fetchCards(params: ["q": name]), !list.isEmpty { return list.map { $0.asUICard } }
        return []
    }

    static func loadPrices(forID id: String) async throws -> [PriceRow] {
        let d = try await detail(id: id)
        var rows: [PriceRow] = []
        if let tp = d.pricing?.tcgplayer {
            func usd(_ v: Double?) -> String? { v.map { String(format: "$%.2f", $0) } }
            func add(_ label: String, _ v: Double?) { if let s = usd(v) { rows.append(.init(source: "TCGplayer", label: label, value: s, url: nil)) } }
            add("Market", tp.bestMarket); add("Mid", tp.bestMid); add("Low", tp.bestLow)
        }
        if let cm = d.pricing?.cardmarket {
            func eur(_ v: Double?) -> String? { v.map { String(format: "€%.2f", $0) } }
            func add(_ label: String, _ v: Double?) { if let s = eur(v) { rows.append(.init(source: "Cardmarket", label: label, value: s, url: nil)) } }
            add("Trend", cm.trend ?? cm.avg ?? cm.avg30); add("Avg 30d", cm.avg30); add("Low", cm.low)
        }
        return rows
    }

    static func fetchPriceBadge(id: String) async throws -> PriceBadge? {
        let d = try? await detail(id: id)
        let usd = d?.pricing?.tcgplayer?.bestMarket
        let eur = d?.pricing?.cardmarket?.trend ?? d?.pricing?.cardmarket?.avg ?? d?.pricing?.cardmarket?.avg30
        if usd == nil && eur == nil { return nil }
        return PriceBadge(
            usd: usd.map { String(format: "%.2f", $0) },
            eur: eur.map { String(format: "%.2f", $0) }
        )
    }

    // -- HTTP

    private static func fetchCards(params: [String:String]) async throws -> [Brief] {
        var comps = URLComponents(url: Net.api.appendingPathComponent("cards"), resolvingAgainstBaseURL: false)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (d, http) = try await get(comps.url!)
        if !(200..<300).contains(http.statusCode) { HTTPDump.peek(d, prefix: "TCGdex list"); throw URLError(.badServerResponse) }
        if let arr = try? decoder.decode([Brief].self, from: d) { return arr }
        if let wrap = try? decoder.decode(SearchWrap.self, from: d) { return wrap.data }
        return []
    }

    private static func detail(id: String) async throws -> Detail {
        let url = Net.api.appendingPathComponent("cards/\(id)")
        let (d, http) = try await get(url)
        if !(200..<300).contains(http.statusCode) { HTTPDump.peek(d, prefix: "TCGdex detail"); throw URLError(.badServerResponse) }
        return try decoder.decode(Detail.self, from: d)
    }

    private static func get(_ url: URL, attempt: Int = 1) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (d, r) = try await session.data(for: req)
        guard let http = r as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        JPLOG("TCGdex HTTP \(http.statusCode) \(url.absoluteString)")
        if (http.statusCode == 429 || (500..<600).contains(http.statusCode)), attempt < Limits.retries {
            try? await Task.sleep(nanoseconds: UInt64(220_000_000 * attempt))
            return try await get(url, attempt: attempt + 1)
        }
        return (d, http)
    }
}
