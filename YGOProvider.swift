import Foundation

struct YGOProvider {

    // MARK: - Wire models we need from YGOPRODeck

    private struct APIWrap<T: Decodable>: Decodable { let data: [T] }

    private struct APICard: Decodable {
        let id: Int
        let name: String
        let ygoprodeck_url: String?
        let card_images: [APIImage]
        let card_sets: [APISet]?
        let card_prices: [APIPrice]?
    }

    private struct APIImage: Decodable {
        let image_url_small: String
        let image_url: String
    }

    private struct APISet: Decodable {
        let set_code: String?
        let set_name: String?
        let set_rarity: String?
    }

    private struct APIPrice: Decodable {
        let tcgplayer_price: String?
        let cardmarket_price: String?
        let ebay_price: String?
        let amazon_price: String?
        let coolstuffinc_price: String?
    }

    // MARK: - Search (now sets priceUSD / priceEUR so badges render)

    static func search(text: String, rarity: String?, number: String?) async throws -> [UICard] {
        guard !text.isEmpty else { return [] }

        var comps = URLComponents(string: "https://db.ygoprodeck.com/api/v7/cardinfo.php")!
        // `fname` = fuzzy; best UX for typing
        comps.queryItems = [ URLQueryItem(name: "fname", value: text) ]

        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let page = try JSONDecoder().decode(APIWrap<APICard>.self, from: data)

        var out: [UICard] = []
        out.reserveCapacity(page.data.count)

        for c in page.data {
            // Optional rarity filtering (client-side is more reliable for YGO)
            if let want = rarity, !want.isEmpty {
                let hasWantedRarity = c.card_sets?.contains(where: {
                    ($0.set_rarity ?? "").caseInsensitiveCompare(want) == .orderedSame
                }) ?? false
                if !hasWantedRarity { continue }
            }

            // First assets
            let img = c.card_images.first
            let firstSet = c.card_sets?.first
            let firstPrice = c.card_prices?.first

            // A light “number” guess: many UIs like to show the set code
            let numberGuess = firstSet?.set_code

            let ui = UICard(
                id: String(c.id),
                game: .yugioh,
                name: c.name,
                number: number ?? numberGuess,                         // prefer explicit user filter if provided
                setCode: firstSet?.set_code,
                imageSmallURL: URL(safe: img?.image_url_small),
                imageLargeURL: URL(safe: img?.image_url),
                apiURL: nil,
                webURL: URL(safe: c.ygoprodeck_url),                   // deep link to exact card page
                priceUSD: firstPrice?.tcgplayer_price,                 // <-- badges use these two fields
                priceEUR: firstPrice?.cardmarket_price,                // <--
                sets: c.card_sets?.map { .init(name: $0.set_name, code: $0.set_code, rarity: $0.set_rarity) },
                rarity: firstSet?.set_rarity,
                setName: firstSet?.set_name
            )

            out.append(ui)
        }

        // Stable sort feels nicer
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Prices (detail rows; all point to the same YGOPRODeck page)

    static func loadPrices(forID id: String) async throws -> [PriceRow] {
        guard let intID = Int(id) else { return [] }
        var comps = URLComponents(string: "https://db.ygoprodeck.com/api/v7/cardinfo.php")!
        comps.queryItems = [ URLQueryItem(name: "id", value: String(intID)) ]

        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let wrap = try JSONDecoder().decode(APIWrap<APICard>.self, from: data)
        guard let c = wrap.data.first, let p = c.card_prices?.first else { return [] }

        let exactPage = URL(safe: c.ygoprodeck_url) ?? URL(string: "https://ygoprodeck.com")!

        var rows: [PriceRow] = []
        func add(_ label: String, _ value: String?) {
            guard let v = value, !v.isEmpty else { return }
            rows.append(.init(source: "YGOPRODeck", label: label, value: v, url: exactPage))
        }

        add("TCGplayer (USD)",   p.tcgplayer_price)
        add("Cardmarket (EUR)",  p.cardmarket_price)
        add("eBay (USD)",        p.ebay_price)
        add("Amazon (USD)",      p.amazon_price)
        add("CoolStuffInc (USD)", p.coolstuffinc_price)

        return rows
    }

    // MARK: - Badge (now returns a compact badge for the grid)

    static func fetchPriceBadge(id: String) async throws -> PriceBadge? {
        guard let intID = Int(id) else { return nil }
        var comps = URLComponents(string: "https://db.ygoprodeck.com/api/v7/cardinfo.php")!
        comps.queryItems = [ URLQueryItem(name: "id", value: String(intID)) ]

        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let wrap = try JSONDecoder().decode(APIWrap<APICard>.self, from: data)
        guard let price = wrap.data.first?.card_prices?.first else { return nil }

        // Your UI wants strings (already formatted like "2.10")
        return PriceBadge(usd: price.tcgplayer_price, eur: price.cardmarket_price)
    }
}

