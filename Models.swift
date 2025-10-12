import Foundation

// MARK: - Game

public enum Game: String, CaseIterable, Identifiable, Codable {
    case pokemon = "Pokémon"
    case magic   = "Magic"
    case yugioh  = "Yu-Gi-Oh!"

    public var id: String { rawValue }
}

// MARK: - ScanHit (scanner result)

/// Result of one scan pass. Fields are optional so the engine can emit
/// partial guesses (e.g., a name before a number) without blocking.
public struct ScanHit: Equatable, Sendable, Codable {
    public let name: String?
    public let number: String?

    public init(name: String?, number: String?) {
        self.name = name
        self.number = number
    }

    /// True if at least one field is non-empty after trimming.
    public var hasContent: Bool {
        let ws = CharacterSet.whitespacesAndNewlines
        return !(name?.trimmingCharacters(in: ws).isEmpty ?? true)
            || !(number?.trimmingCharacters(in: ws).isEmpty ?? true)
    }

    /// Normalized (trimmed) values.
    public var normalized: ScanHit {
        let ws = CharacterSet.whitespacesAndNewlines
        return ScanHit(
            name: name?.trimmingCharacters(in: ws),
            number: number?.trimmingCharacters(in: ws)
        )
    }

    /// Merge two hits, preferring non-empty fields from `rhs`.
    public func merging(_ rhs: ScanHit) -> ScanHit {
        let ws = CharacterSet.whitespacesAndNewlines
        let leftName = name?.trimmingCharacters(in: ws)
        let rightName = rhs.name?.trimmingCharacters(in: ws)
        let leftNum = number?.trimmingCharacters(in: ws)
        let rightNum = rhs.number?.trimmingCharacters(in: ws)

        return ScanHit(
            name: (rightName?.isEmpty == false ? rightName : leftName),
            number: (rightNum?.isEmpty == false ? rightNum : leftNum)
        )
    }
}

// MARK: - UICard

/// Lightweight UI model used across the app for grid tiles & detail pages.
/// Keep this independent from any specific provider’s raw API schema.
public struct UICard: Identifiable, Hashable, Codable {
    // Stable identity for navigation/favorites. Prefer provider ID (UUID/string/int) as string.
    public let id: String

    public let game: Game
    public let name: String

    /// Printed card/collector number (e.g., "096", "96", "123a"). Optional for YGO.
    public var number: String?

    /// Provider set code (e.g., Scryfall's "khm", Poke Set ID like "base1")
    public var setCode: String?

    /// Preferred images
    public var imageSmallURL: URL?
    public var imageLargeURL: URL?

    /// Source links
    public var apiURL: URL?
    public var webURL: URL?

    /// Basic price snapshots (strings so we can show "—" or formatted)
    public var priceUSD: String?
    public var priceEUR: String?

    /// Optional set info list (useful for YGO client-side rarity filtering)
    public var sets: [SetInfo]?

    // Extra metadata that some views show
    public var rarity: String?
    public var setName: String?

    public init(
        id: String,
        game: Game,
        name: String,
        number: String? = nil,
        setCode: String? = nil,
        imageSmallURL: URL? = nil,
        imageLargeURL: URL? = nil,
        apiURL: URL? = nil,
        webURL: URL? = nil,
        priceUSD: String? = nil,
        priceEUR: String? = nil,
        sets: [SetInfo]? = nil,
        rarity: String? = nil,
        setName: String? = nil
    ) {
        self.id = id
        self.game = game
        self.name = name
        self.number = number
        self.setCode = setCode
        self.imageSmallURL = imageSmallURL
        self.imageLargeURL = imageLargeURL
        self.apiURL = apiURL
        self.webURL = webURL
        self.priceUSD = priceUSD
        self.priceEUR = priceEUR
        self.sets = sets
        self.rarity = rarity
        self.setName = setName
    }

    // Hash/Equatable by (id + game) to keep favorites stable across sessions
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(game.rawValue)
    }

    public static func == (lhs: UICard, rhs: UICard) -> Bool {
        lhs.id == rhs.id && lhs.game == rhs.game
    }

    // Normalizes numbers like "096" -> "96" (keeps letters like "123a")
    public var normalizedNumber: String? {
        guard let n = number, !n.isEmpty else { return nil }
        let prefix = n.prefix { $0.isNumber }
        if prefix.isEmpty { return n }
        let trimmed = String(prefix).drop { $0 == "0" }
        let normalizedDigits = trimmed.isEmpty ? "0" : String(trimmed)
        if prefix.count == n.count {
            return normalizedDigits
        } else {
            // preserve trailing letters/suffix after the numeric portion
            let suffix = n.dropFirst(prefix.count)
            return normalizedDigits + suffix
        }
    }

    // Nested set info used by YGO rarity filtering and display
    public struct SetInfo: Hashable, Codable {
        public var name: String?
        public var code: String?
        public var rarity: String?

        public init(name: String? = nil, code: String? = nil, rarity: String? = nil) {
            self.name = name
            self.code = code
            self.rarity = rarity
        }
    }
}

// MARK: - PriceBadge (for grid tiles)

public struct PriceBadge: Codable, Hashable {
    public var usd: String? = nil
    public var eur: String? = nil

    public init(usd: String? = nil, eur: String? = nil) {
        self.usd = usd
        self.eur = eur
    }
}

// MARK: - PriceRow (detail view list items)

/// If your detail page shows multiple sources (TCGplayer/Cardmarket/etc.)
/// this compact model renders well in a simple list.
public struct PriceRow: Identifiable, Hashable, Codable {
    public var id: String { source + "|" + label + "|" + (value ?? "—") }

    public let source: String          // e.g. "TCGplayer", "Cardmarket", "Scryfall"
    public let label: String           // e.g. "Market", "Trend", "Low", "Foil Market"
    public let value: String?          // e.g. "$3.25", "€2.10"
    public let url: URL?               // deep link to the source page

    public init(source: String, label: String, value: String?, url: URL?) {
        self.source = source
        self.label = label
        self.value = value
        self.url = url
    }
}

// MARK: - Small URL helpers

public extension URL {
    /// Convenience: URL(string:) that accepts nil/empty gracefully.
    init?(safe string: String?) {
        guard let s = string, !s.isEmpty else { return nil }
        self.init(string: s)
    }
}

public extension String {
    /// Percent-encode for use in a single query value.
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
