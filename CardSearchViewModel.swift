import Foundation
import SwiftUI

@MainActor
final class CardSearchViewModel: ObservableObject {

    // Inputs
    @Published var query: String = ""
    @Published var numberFilter: String = ""
    @Published var selectedRarity: String? = nil
    @Published var game: Game = .pokemon {
        didSet { handleGameSwitch(from: oldValue, to: game) }
    }

    // Outputs
    @Published var results: [UICard] = []
    @Published var priceBadges: [String: PriceBadge] = [:]
    @Published var isLoading: Bool = false
    @Published var errorText: String? = nil
    @Published var rarityOptions: [String] = [""]

    // Pokémon paging (now disabled; kept for compatibility with UI)
    @Published var hasMore: Bool = false
    private var nextPage: Int = 2
    private var lastSearchKey: SearchKey?

    // Badge streaming
    private var streamingTask: Task<Void, Never>?

    init() { updateRarityOptions() }

    // MARK: - Search

    func startSearch() {
        streamingTask?.cancel()
        errorText = nil
        isLoading = true
        results = []
        priceBadges.removeAll()
        hasMore = false
        nextPage = 2
        lastSearchKey = nil

        let text   = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = numberFilter.isEmpty ? nil : numberFilter
        let rarity = selectedRarity
        let key    = SearchKey(game: game, text: text, number: number, rarity: rarity)

        Task {
            do {
                switch game {
                case .pokemon:
                    // Simplified: single resilient call via PokemonProvider.search(...)
                    let uiCards = try await PokemonProvider.search(text: text, number: number, rarity: rarity)

                    self.results = uiCards
                    self.hasMore = false          // pagination disabled for Pokémon
                    self.nextPage = 2
                    self.lastSearchKey = key
                    self.isLoading = false

                    if !uiCards.isEmpty { streamBadges(for: uiCards) }

                case .magic:
                    let first = try await MultigameService.searchFirstPage(game: .magic, text: text, rarity: rarity, number: number)
                    self.results = first.cards
                    self.hasMore = first.hasMore
                    self.nextPage = 2
                    self.lastSearchKey = key
                    self.isLoading = false
                    if !first.cards.isEmpty { streamBadges(for: first.cards) }

                case .yugioh:
                    let first = try await MultigameService.searchFirstPage(game: .yugioh, text: text, rarity: rarity, number: number)
                    self.results = first.cards
                    self.hasMore = first.hasMore
                    self.nextPage = 2
                    self.lastSearchKey = key
                    self.isLoading = false
                    if !first.cards.isEmpty { streamBadges(for: first.cards) }
                }
            } catch is CancellationError {
                // ignore
            } catch {
                self.isLoading = false
                self.results = []
                self.priceBadges = [:]
                self.errorText = "Search failed. " + (error as NSError).localizedDescription
            }
        }
    }

    func loadMoreIfAvailable() {
        guard hasMore, let key = lastSearchKey, !isLoading else { return }

        // Pokémon no longer paginates; just bail out cleanly.
        if key.game == .pokemon {
            hasMore = false
            return
        }

        isLoading = true
        Task {
            do {
                let pageIndex = nextPage
                switch key.game {
                case .magic, .yugioh:
                    let next = try await MultigameService.searchNextPage(
                        game: key.game, text: key.text, rarity: key.rarity, number: key.number, afterPage: pageIndex - 1
                    )
                    self.results += next.cards
                    self.hasMore = next.hasMore
                    self.nextPage = pageIndex + 1
                    self.isLoading = false
                    if !next.cards.isEmpty { streamBadges(for: next.cards) }

                case .pokemon:
                    // already handled above; keep compiler happy
                    self.isLoading = false
                }
            } catch {
                self.isLoading = false
                self.errorText = error.localizedDescription
            }
        }
    }

    func applyScan(name: String, number: String?) {
        self.query = name
        self.numberFilter = number ?? ""
        self.selectedRarity = nil
        startSearch()
    }

    // MARK: - Price badges
    private func streamBadges(for cards: [UICard]) {
        streamingTask?.cancel()
        let items = cards

        streamingTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let maxConcurrent = 8
            await withTaskGroup(of: (String, PriceBadge?).self) { group in
                var idx = 0, inflight = 0
                func enqueue() {
                    while idx < items.count && inflight < maxConcurrent {
                        let card = items[idx]; idx += 1; inflight += 1
                        group.addTask {
                            let badge = await MultigameService.fetchBadge(for: card)
                            return (card.id, badge)
                        }
                    }
                }
                enqueue()
                for await (id, badge) in group {
                    inflight -= 1
                    if Task.isCancelled { break }
                    if let badge { await MainActor.run { self.priceBadges[id] = badge } }
                    enqueue()
                }
            }
        }
    }

    // MARK: - Rarities / game switch
    private func updateRarityOptions() {
        switch game {
        case .pokemon:
            rarityOptions = ["", "Common","Uncommon","Rare","Rare Holo","Rare Holo EX","Rare Ultra","Illustration Rare","Special Illustration Rare","Hyper Rare","Promo"]
        case .magic:
            rarityOptions = ["", "Common","Uncommon","Rare","Mythic"]
        case .yugioh:
            rarityOptions = ["", "Common","Rare","Super Rare","Ultra Rare","Secret Rare","Ultimate Rare","Ghost Rare","Starlight Rare"]
        }
    }

    private func handleGameSwitch(from old: Game, to new: Game) {
        streamingTask?.cancel()
        query = ""; numberFilter = ""; selectedRarity = nil
        isLoading = false; errorText = nil
        results = []; priceBadges = [:]
        hasMore = false; nextPage = 2; lastSearchKey = nil
        updateRarityOptions()
    }

    private struct SearchKey: Hashable {
        let game: Game
        let text: String
        let number: String?
        let rarity: String?
    }
}
