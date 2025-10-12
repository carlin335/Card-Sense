import SwiftUI
import Foundation

struct ScanBridgeView: View {
    // Keep synthesized init(game:onResult:) available
    var game: Game = .pokemon
    let onResult: (_ name: String?, _ number: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bestName: String = ""
    @State private var bestNumber: String = ""

    private var languages: [String] {
        switch game {
        case .pokemon:
            return ["en-US", "en", "ja"]
        case .magic, .yugioh:
            return ["en-US", "en", "fr-FR", "de-DE", "es-ES", "it-IT"]
        }
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack { content }
            } else {
                NavigationView { content }
            }
        }
    }

    // Extracted to avoid code dup for NavigationStack/View
    private var content: some View {
        VStack(spacing: 16) {

            // TEMP scanner (no external dependency), replace with your real camera later
            StubScannerView { guess in
                let cleaned = guess.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                if let match = cleaned.range(of: #"\d[\dA-Za-z\-]*$"#, options: .regularExpression) {
                    bestNumber = String(cleaned[match])
                    bestName = cleaned.replacingCharacters(in: match, with: "")
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                } else {
                    bestName = cleaned
                }
            }
            .frame(height: 300)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Manual overrides
            VStack(alignment: .leading, spacing: 8) {
                Text("Manual Entry").font(.headline)
                TextField("Card name", text: $bestName)
                    .textInputAutocapitalization(.words)
                    .textFieldStyle(.roundedBorder)
                TextField("Card number (optional)", text: $bestNumber)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            Button {
                onResult(bestName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? nil : bestName,
                         bestNumber.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? nil : bestNumber)
                dismiss()
            } label: {
                Text(bestName.isEmpty ? "Use Manual Entry" : "Use “\(bestName)”")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(bestName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .navigationTitle("Scan Card")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

// Convenience-only init with different signature (no collision)
extension ScanBridgeView {
    init(onResult: @escaping (_ name: String?, _ number: String?) -> Void) {
        self.init(game: .pokemon, onResult: onResult)
    }
}

/// Temporary stand-in for your camera scanner. Tap a chip to simulate a guess.
fileprivate struct StubScannerView: View {
    var onGuess: (String) -> Void
    private let samples = [
        "Charizard ex 201",
        "Pikachu 025",
        "Blue-Eyes White Dragon",
        "Black Lotus"
    ]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder").font(.system(size: 48))
            Text("Scanner placeholder — tap a guess")
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(samples, id: \.self) { s in
                        Button(s) { onGuess(s) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
