import Foundation

enum AppSecrets {

    // Final fallback so you never ship the literal placeholder by accident.
    // You can update this if you rotate keys.
    private static let hardcodedPokemonKey = "3d451fe7-3ff7-49ce-a1bc-a7f2edd254a2"

    /// Returns the PokémonTCG.io API key in this order:
    /// 1) Info.plist -> POKEMON_TCG_API_KEY
    /// 2) Environment variable POKEMON_TCG_API_KEY
    /// 3) Hardcoded fallback (above)
    static func pokemonTCGApiKey() -> String {
        // 1) Info.plist
        if let raw = Bundle.main.object(forInfoDictionaryKey: "POKEMON_TCG_API_KEY") as? String {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // treat placeholders as unset
            if !v.isEmpty, v.uppercased() != "POKEMON_TCG_API_KEY", v != "$(POKEMON_TCG_API_KEY)" {
                return v
            }
        }
        // 2) ENV
        if let env = ProcessInfo.processInfo.environment["POKEMON_TCG_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        // 3) fallback
        return hardcodedPokemonKey
    }
}
