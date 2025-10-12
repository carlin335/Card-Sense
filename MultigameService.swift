import Foundation

enum MultigameService {

    // MARK: - Price rows (detail view)

    static func loadPrices(for card: UICard) async throws -> [PriceRow] {
        switch card.game {
        case .pokemon:
            return try await PokemonProvider.loadPrices(forID: card.id)
        case .magic:
            return try await ScryfallProvider.loadPrices(forID: card.id)
        case .yugioh:
            return try await YGOProvider.loadPrices(forID: card.id)
        }
    }

    static func loadPricesOptional(for card: UICard) async -> [PriceRow]? {
        do { return try await loadPrices(for: card) }
        catch { return nil }
    }

    // MARK: - Tile price badge (lightweight, per-card)

    static func fetchBadge(for card: UICard) async -> PriceBadge? {
        switch card.game {
        case .pokemon:
            return try? await PokemonProvider.fetchPriceBadge(id: card.id)
        case .magic:
            return try? await ScryfallProvider.fetchPriceBadge(id: card.id)
        case .yugioh:
            return try? await YGOProvider.fetchPriceBadge(id: card.id)
        }
    }

    // MARK: - Prewarm (Pokémon only)

    /// Old code prewarmed by calling searchLitePage; now we just issue the same resilient search once.
    /// `page` is ignored because Pokémon pagination is disabled in this simplified flow.
    static func prewarmPokemon(text: String, rarity: String?, number: String?, page: Int) {
        Task.detached(priority: .utility) {
            _ = try? await PokemonProvider.search(text: text, number: number, rarity: rarity)
        }
    }

    // MARK: - Search facade

    struct SearchPage { let cards: [UICard]; let hasMore: Bool }

    /// First page search across games.
    /// - Important: Pokémon uses a single resilient call (no pagination).
    static func searchFirstPage(
        game: Game,
        text: String,
        rarity: String?,
        number: String?
    ) async throws -> SearchPage {
        switch game {
        case .pokemon:
            let cards = try await PokemonProvider.search(text: text, number: number, rarity: rarity)
            return SearchPage(cards: cards, hasMore: false)

        case .magic:
            // Scryfall signature expects number before rarity.
            let cards = try await ScryfallProvider.search(text: text, number: number, rarity: rarity)
            // If your Scryfall provider paginates, adjust hasMore accordingly.
            return SearchPage(cards: cards, hasMore: false)

        case .yugioh:
            // YGO provider signature is (text, rarity, number).
            let cards = try await YGOProvider.search(text: text, rarity: rarity, number: number)
            // Adjust hasMore if your YGO path supports paging.
            return SearchPage(cards: cards, hasMore: false)
        }
    }

    /// Next page search for games that support it.
    /// Pokémon returns an empty page by design (pagination disabled).
    static func searchNextPage(
        game: Game,
        text: String,
        rarity: String?,
        number: String?,
        afterPage: Int
    ) async throws -> SearchPage {
        switch game {
        case .pokemon:
            // No further pages in the simplified Pokémon flow.
            return .init(cards: [], hasMore: false)

        case .magic:
            // If you have a paged Scryfall implementation, forward to it here.
            // Example (adjust to your provider’s API):
            // let next = try await ScryfallProvider.searchNextPage(text: text, number: number, rarity: rarity, afterPage: afterPage)
            // return SearchPage(cards: next.cards, hasMore: next.hasMore)
            return .init(cards: [], hasMore: false)

        case .yugioh:
            // If you add YGO paging later, wire it here similarly.
            return .init(cards: [], hasMore: false)
        }
    }
}

