import SwiftUI

@MainActor
final class FavoritesStore: ObservableObject {
    // Keep writes inside the store; views read only
    @Published private(set) var cards: [UICard] = []

    // MARK: - Query
    func isFavorite(_ id: String) -> Bool {
        cards.contains { $0.id == id }
    }

    // MARK: - Mutations
    func toggle(_ card: UICard) {
        if let i = cards.firstIndex(where: { $0.id == card.id }) {
            cards.remove(at: i)
        } else {
            cards.append(card)
        }
    }

    func remove(_ card: UICard) {
        cards.removeAll { $0.id == card.id }
    }
}
