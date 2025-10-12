import SwiftUI

@main
struct CardSenseApp: App {
    @StateObject private var favorites = FavoritesStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favorites)
        }
    }
}
