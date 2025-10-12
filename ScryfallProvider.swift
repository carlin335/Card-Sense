import Foundation

struct ScryfallProvider {
    static func search(text: String, number: String?, rarity: String?) async throws -> [UICard] {
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        if let n = number, !n.isEmpty { parts.append("number:\(n)") }
        if let r = rarity, !r.isEmpty { parts.append("r:\(r)") }
        let query = parts.joined(separator: " ")

        var comps = URLComponents(string: "https://api.scryfall.com/cards/search")!
        comps.queryItems = [.init(name: "q", value: query)]

        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        struct Page: Decodable { let data: [Card] }
        struct Card: Decodable {
            let id: String
            let name: String
            let collector_number: String?
            let image_uris: [String:String]?
            let scryfall_uri: String?
        }

        let page = try JSONDecoder().decode(Page.self, from: data)
        return page.data.map {
            let small = URL(string: $0.image_uris?["normal"] ?? $0.image_uris?["small"] ?? "")
            let large = URL(string: $0.image_uris?["large"] ?? $0.image_uris?["png"] ?? "")
            return UICard(
                id: $0.id, game: .magic, name: $0.name, number: $0.collector_number,
                setCode: nil, imageSmallURL: small, imageLargeURL: large,
                apiURL: nil, webURL: URL(safe: $0.scryfall_uri),
                priceUSD: nil, priceEUR: nil, sets: nil, rarity: nil, setName: nil
            )
        }
    }

    static func loadPrices(forID id: String) async throws -> [PriceRow] {
        let url = URL(string: "https://api.scryfall.com/cards/\(id)")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        struct Card: Decodable {
            let prices: Prices
            let scryfall_uri: String
            struct Prices: Decodable { let usd: String?; let usd_foil: String?; let eur: String?; let eur_foil: String? }
        }

        let card = try JSONDecoder().decode(Card.self, from: data)
        var rows: [PriceRow] = []
        let page = URL(string: card.scryfall_uri)

        func add(_ label: String, _ v: String?) { if let v, !v.isEmpty { rows.append(.init(source:"Scryfall", label: label, value: v, url: page)) } }
        add("USD", card.prices.usd)
        add("USD Foil", card.prices.usd_foil)
        add("EUR", card.prices.eur)
        add("EUR Foil", card.prices.eur_foil)
        return rows
    }

    static func fetchPriceBadge(id: String) async throws -> PriceBadge? {
        let url = URL(string: "https://api.scryfall.com/cards/\(id)")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct Card: Decodable { struct Prices: Decodable { let usd: String?; let eur: String? }; let prices: Prices }
        let card = try JSONDecoder().decode(Card.self, from: data)
        let usd = (card.prices.usd?.isEmpty ?? true) ? nil : card.prices.usd
        let eur = (card.prices.eur?.isEmpty ?? true) ? nil : card.prices.eur
        if usd == nil && eur == nil { return nil }
        return PriceBadge(usd: usd, eur: eur)
    }
}
