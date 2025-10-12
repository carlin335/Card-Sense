import Foundation

/// Single-source Pokémon provider using PokemonTCG API only.
/// - Search returns lightweight UI cards (and seeds badge cache).
/// - Detail prices come from tcgplayer & cardmarket.
/// - Badges are fast (in-memory cached).
struct PokemonProvider {

    // MARK: - Public API -------------------------------------------------------

    /// First-page search. Returns UI cards; badges will be populated from cache quickly.
    static func search(text: String, number: String?, rarity: String?) async throws -> [UICard] {
        let (_, ui) = try await resilientSearch(
            name: text, number: number, rarity: rarity,
            page: 1, pageSize: 12, overallDeadline: 45
        )
        return ui
    }

    /// Detail price rows (Card Detail screen).
    static func loadPrices(forID id: String) async throws -> [PriceRow] {
        let d = try await fetchCardDetail(id: id, select: "id,name,tcgplayer,cardmarket")
        var rows: [PriceRow] = []

        if let tp = d.tcgplayer {
            let link = URL(safe: tp.url)
            let p = tp.prices
            func usd(_ v: Double?) -> String? { v.map { String(format: "$%.2f", $0) } }
            func add(_ label: String, _ v: Double?) { if let s = usd(v) { rows.append(.init(source: "TCGplayer", label: label, value: s, url: link)) } }
            add("Market", bestUSDMarket(from: p))
            add("Mid",    bestUSDMid(from: p))
            add("Low",    bestUSDLow(from: p))
        }

        if let cm = d.cardmarket {
            let link = URL(safe: cm.url)
            let p = cm.prices
            func eur(_ v: Double?) -> String? { v.map { String(format: "€%.2f", $0) } }
            func add(_ label: String, _ v: Double?) { if let s = eur(v) { rows.append(.init(source: "Cardmarket", label: label, value: s, url: link)) } }
            add("Trend",    p?.trendPrice)
            add("Avg Sold", p?.averageSellPrice)
            add("Low",      p?.lowPrice)
        }

        return rows
    }

    /// Lightweight price badge for grid tiles (USD/EUR); cached.
    static func fetchPriceBadge(id: String) async throws -> PriceBadge? {
        if let cached = await badgeCache.get(id) { return cached }                 // cache hit

        let d = try await fetchCardDetail(id: id, select: "id,tcgplayer,cardmarket")
        let usd = bestUSDMarket(from: d.tcgplayer?.prices).map { String(format: "%.2f", $0) }
        let eur = bestEUR(from: d.cardmarket?.prices).map { String(format: "%.2f", $0) }

        let badge = (usd == nil && eur == nil) ? nil : PriceBadge(usd: usd, eur: eur)
        await badgeCache.set(id, badge)
        return badge
    }

    // MARK: - Internals: networking & search ----------------------------------

    private enum Net {
        static let base = URL(string: "https://api.pokemontcg.io/v2")!
        static let requestTimeout: TimeInterval  = 30
        static let resourceTimeout: TimeInterval = 90
        static let maxConnections = 8
    }

    private static let decoder: JSONDecoder = .init()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.httpMaximumConnectionsPerHost = Net.maxConnections
        c.timeoutIntervalForRequest = Net.requestTimeout
        c.timeoutIntervalForResource = Net.resourceTimeout
        c.allowsConstrainedNetworkAccess = true
        c.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: c)
    }()

    /// Use AppSecrets if present; else fall back to your provided key.
    private static var apiKey: String {
        let v = AppSecrets.pokemonTCGApiKey().trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "3d451fe7-3ff7-49ce-a1bc-a7f2edd254a2" : v
    }

    /// Core GET with correct header + retries for timeouts/429/5xx.
    private static func getJSON(_ url: URL, attempt: Int = 1) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")   // ✅ correct header

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw URLError(.userAuthenticationRequired)
            case 429, 500..<600:
                guard attempt < 6 else { throw URLError(.badServerResponse) }
                try? await Task.sleep(nanoseconds: UInt64(200_000_000 * attempt)) // 0.2, 0.4, …
                return try await getJSON(url, attempt: attempt + 1)
            default:
                throw URLError(.badServerResponse)
            }
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut, attempt < 6 {
                try? await Task.sleep(nanoseconds: UInt64(250_000_000 * attempt))
                return try await getJSON(url, attempt: attempt + 1)
            }
            throw error
        }
    }

    /// Patient search with a fast exact path, then fallbacks; seeds badge cache from the search payload.
    private static func resilientSearch(
        name: String,
        number: String?,
        rarity: String?,
        page: Int,
        pageSize: Int,
        overallDeadline: TimeInterval
    ) async throws -> (hasMore: Bool, cards: [UICard]) {

        let deadline = Date().addingTimeInterval(overallDeadline)

        // --- Fast path: exact quoted name + number (when both present) ----------
        do {
            let (cleanName, inferred) = splitNameAndNumber(rawName: name, explicitNumber: number)
            let effectiveNumber = (number?.isEmpty == false) ? number! : (inferred ?? "")
            let hasName = !cleanName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasName, !effectiveNumber.isEmpty {
                var items: [URLQueryItem] = [
                    .init(name: "q", value: #"name:"\#(cleanName)" AND number:"\#(effectiveNumber)""#),
                    .init(name: "page", value: "1"),
                    .init(name: "pageSize", value: String(pageSize)),
                    .init(name: "select", value: "id,name,number,rarity,images,tcgplayer,cardmarket")
                ]
                if let r = rarity?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
                    items[0].value = (items[0].value ?? "") + #" AND rarity:"\#(r)""#
                }
                var comps = URLComponents(url: Net.base.appendingPathComponent("cards"), resolvingAgainstBaseURL: false)!
                comps.queryItems = items

                let data = try await getJSON(comps.url!)
                struct Resp: Decodable { let data: [APICard]; let totalCount: Int? }
                let dec = try decoder.decode(Resp.self, from: data)
                if !dec.data.isEmpty { return ( (dec.totalCount ?? 0) > pageSize, await mapAndSeed(cards: dec.data) ) }
            }
        } catch {
            // ignore and fall through to the general loop
        }

        // --- General loop with robust name handling -----------------------------
        var attempt = 0
        func runQuery(simple: Bool, noOrder: Bool) async throws -> (Bool, [APICard]) {
            let q = buildQuery(name: name, number: number, rarity: rarity, simplePrefixOnly: simple)

            var items: [URLQueryItem] = [
                .init(name: "q", value: q),
                .init(name: "page", value: String(page)),
                .init(name: "pageSize", value: String(pageSize)),
                .init(name: "select", value: "id,name,number,rarity,images,tcgplayer,cardmarket"),
            ]
            if !noOrder { items.append(.init(name: "orderBy", value: "name")) }

            var comps = URLComponents(url: Net.base.appendingPathComponent("cards"), resolvingAgainstBaseURL: false)!
            comps.queryItems = items

            let data = try await getJSON(comps.url!)
            struct Resp: Decodable { let data: [APICard]; let totalCount: Int? }
            let decoded = try decoder.decode(Resp.self, from: data)
            let hasMore = decoded.totalCount.map { page * pageSize < $0 } ?? false
            return (hasMore, decoded.data)
        }

        while true {
            attempt += 1

            // Try no-order first (faster), then ordered, then simple prefix
            if let r = try? await runQuery(simple: false, noOrder: true),  !r.1.isEmpty { return (r.0, await mapAndSeed(cards: r.1)) }
            if let r = try? await runQuery(simple: false, noOrder: false), !r.1.isEmpty { return (r.0, await mapAndSeed(cards: r.1)) }
            if let r = try? await runQuery(simple: true,  noOrder: true),  !r.1.isEmpty { return (r.0, await mapAndSeed(cards: r.1)) }

            if Date() > deadline { return (false, []) }
            let delay = min(1.2, 0.2 * Double(attempt))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    // MARK: - Query building (spaces/'/./accent-safe) --------------------------

    /// Build the `q=` expression for PokemonTCG search.
    /// - Always includes a quoted exact clause so spaces/periods/apostrophes match.
    /// - Adds a tokenized **prefix AND** clause (name:Mr* AND name:Mime*) to catch partials.
    /// - If UI didn't supply a number, we try to peel one off the tail of the name (e.g., "Mr. Mime 179/161" -> 179).
    private static func buildQuery(name: String, number: String?, rarity: String?, simplePrefixOnly: Bool) -> String {
        // Normalize curly quotes/dashes and collapse whitespace
        func normalize(_ s: String) -> String {
            let map: [(String, String)] = [
                ("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'"),
                ("–", "-"), ("—", "-"), ("·", " "), ("•", " ")
            ]
            var out = s
            for (a,b) in map { out = out.replacingOccurrences(of: a, with: b) }
            out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let (rawName, inferredNumber) = splitNameAndNumber(rawName: name, explicitNumber: number)
        let cleanName = normalize(rawName)
        let effectiveNumber = (number?.isEmpty == false) ? number : inferredNumber

        var clauses: [String] = []

        if !cleanName.isEmpty {
            // Exact clause (quoted): handles spaces, periods, apostrophes safely
            let exact = #"name:"\#(cleanName)""#
            if simplePrefixOnly {
                // Prefix-only mode for very fuzzy typing: AND per-token prefixes
                let tokenPrefixes = tokenizedPrefixes(from: cleanName)
                if tokenPrefixes.isEmpty {
                    clauses.append(exact)
                } else {
                    clauses.append("(\(exact) OR (\(tokenPrefixes.joined(separator: " AND "))))")
                }
            } else {
                // Normal mode: exact + tokenized prefix as a fallback (keeps results broad but relevant)
                let tokenPrefixes = tokenizedPrefixes(from: cleanName)
                if tokenPrefixes.isEmpty {
                    clauses.append(exact)
                } else {
                    clauses.append("(\(exact) OR (\(tokenPrefixes.joined(separator: " AND "))))")
                }
            }
        }

        if let num = effectiveNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !num.isEmpty {
            clauses.append(#"number:"\#(num)""#)
        }
        if let r = rarity?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
            clauses.append(#"rarity:"\#(r)""#)
        }

        return clauses.isEmpty ? "*" : clauses.joined(separator: " AND ")
    }

    /// Break "Mr. Mime" or "Farfetch'd" into safe prefix terms → ["name:Mr*", "name:Mime*"].
    /// We keep letters/digits and strip leading punctuation from each token.
    private static func tokenizedPrefixes(from name: String) -> [String] {
        // Split on whitespace and common punctuation, but keep apostrophes inside words (Farfetch'd)
        let parts = name
            .replacingOccurrences(of: "[\\.\\-:,;·•]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'\"()[]{}")) }
            .filter { !$0.isEmpty }

        // Build name:<token>* for each token
        return parts.map { "name:\($0)*" }
    }

    /// If UI didn't supply a number, try to peel one off the end of the name:
    ///  - "#179" or "179/161" or trailing "179a"
    private static func splitNameAndNumber(rawName: String, explicitNumber: String?) -> (String, String?) {
        // UI Number field wins if present
        if let n = explicitNumber, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (rawName, n.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Patterns: "#179", "179/161", "179a" at end
        let patterns = [
            #"(?:^|[\s])#\s*([0-9]+[A-Za-z]?)\s*$"#,
            #"(?:^|[\s])([0-9]+[A-Za-z]?)\s*/\s*[0-9A-Za-z\-]+\s*$"#,
            #"(?:^|[\s])([0-9]+[A-Za-z]?)\s*$"#
        ]

        for pat in patterns {
            if let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive),
               let match = re.firstMatch(in: name, options: [], range: NSRange(location: 0, length: name.utf16.count)),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: name) {

                let extracted = String(name[r])
                // Remove the matched suffix from name for a cleaner name search
                if let rf = Range(match.range(at: 0), in: name) { name.removeSubrange(rf) }
                // Collapse extra spaces & trim punctuation (but NOT periods/apostrophes inside the string)
                name = name.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                           .trimmingCharacters(in: CharacterSet(charactersIn: "-–—·•,;:")) // note: no '.' here
                return (name, extracted)
            }
        }

        return (name, nil)
    }

    // MARK: - Mapping & detail fetch ------------------------------------------

    /// Map API cards to UI and seed badge cache (so tiles don't need another round-trip).
    private static func mapAndSeed(cards: [APICard]) async -> [UICard] {
        for c in cards {
            let usd = bestUSDMarket(from: c.tcgplayer?.prices)
            let eur = bestEUR(from: c.cardmarket?.prices)
            if usd != nil || eur != nil {
                let badge = PriceBadge(
                    usd: usd.map { String(format: "%.2f", $0) },
                    eur: eur.map { String(format: "%.2f", $0) }
                )
                await badgeCache.set(c.id, badge)
            }
        }
        return cards.map { $0.asUICard }
    }

    private static func fetchCardDetail(id: String, select: String) async throws -> APIDetail {
        var comps = URLComponents(url: Net.base.appendingPathComponent("cards/\(id)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [ .init(name: "select", value: select) ]
        let data = try await getJSON(comps.url!)
        struct Wrap: Decodable { let data: APIDetail }
        return try decoder.decode(Wrap.self, from: data).data
    }

    // MARK: - Internal API models ---------------------------------------------

    private struct APICard: Decodable {
        let id: String
        let name: String
        let number: String?
        let rarity: String?
        let images: Images?
        let tcgplayer: TCGPlayerBlock?       // included to seed badge cache
        let cardmarket: CardmarketBlock?

        struct Images: Decodable { let small: String?; let large: String? }

        var asUICard: UICard {
            // Prefer human-friendly commerce page; fallback to pokemontcg.io card page
            let humanURL =
                URL(safe: tcgplayer?.url) ??
                URL(safe: cardmarket?.url) ??
                URL(string: "https://pokemontcg.io/card/\(id)")

            return UICard(
                id: id,
                game: .pokemon,
                name: name,
                number: number,
                setCode: nil,
                imageSmallURL: URL(safe: images?.small),
                imageLargeURL: URL(safe: images?.large),
                apiURL: URL(string: "https://api.pokemontcg.io/v2/cards/\(id)"),
                webURL: humanURL, // ✅ now points to a real product/details page
                priceUSD: nil,
                priceEUR: nil,
                sets: nil,
                rarity: rarity,
                setName: nil
            )
        }
    }

    private struct APIDetail: Decodable {
        let id: String
        let name: String
        let tcgplayer: TCGPlayerBlock?
        let cardmarket: CardmarketBlock?
    }

    private struct TCGPlayerBlock: Decodable {
        let url: String?
        let prices: TCGPrices?
    }
    private struct TCGPrices: Decodable {
        let normal: TCGPrice?
        let holofoil: TCGPrice?
        let reverseHolofoil: TCGPrice?
        let firstEdition: TCGPrice?
        let firstEditionHolofoil: TCGPrice?
        private enum CodingKeys: String, CodingKey {
            case normal, holofoil, reverseHolofoil
            case firstEdition = "1stEdition"
            case firstEditionHolofoil = "1stEditionHolofoil"
        }
    }
    private struct TCGPrice: Decodable {
        let low: Double?
        let mid: Double?
        let high: Double?
        let market: Double?
    }

    private struct CardmarketBlock: Decodable {
        let url: String?
        let prices: CardmarketPrices?
    }
    private struct CardmarketPrices: Decodable {
        let averageSellPrice: Double?
        let lowPrice: Double?
        let trendPrice: Double?
    }

    // MARK: - Price helpers ----------------------------------------------------

    private static func bestUSDMarket(from p: TCGPrices?) -> Double? {
        guard let p = p else { return nil }
        return p.holofoil?.market
            ?? p.reverseHolofoil?.market
            ?? p.normal?.market
            ?? p.firstEditionHolofoil?.market
            ?? p.firstEdition?.market
    }
    private static func bestUSDMid(from p: TCGPrices?) -> Double? {
        guard let p = p else { return nil }
        return p.holofoil?.mid
            ?? p.reverseHolofoil?.mid
            ?? p.normal?.mid
            ?? p.firstEditionHolofoil?.mid
            ?? p.firstEdition?.mid
    }
    private static func bestUSDLow(from p: TCGPrices?) -> Double? {
        guard let p = p else { return nil }
        return p.holofoil?.low
            ?? p.reverseHolofoil?.low
            ?? p.normal?.low
            ?? p.firstEditionHolofoil?.low
            ?? p.firstEdition?.low
    }
    private static func bestEUR(from p: CardmarketPrices?) -> Double? {
        guard let p = p else { return nil }
        return p.trendPrice ?? p.averageSellPrice ?? p.lowPrice
    }

    // MARK: - Badge cache ------------------------------------------------------

    private actor BadgeCache {
        private var map: [String: PriceBadge?] = [:]  // store nil to remember “no badge”
        func get(_ id: String) -> PriceBadge?? { map[id] }
        func set(_ id: String, _ value: PriceBadge?) { map[id] = value }
    }
    private static let badgeCache = BadgeCache()
}
