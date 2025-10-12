import SwiftUI

// MARK: - Small compat helpers

extension View {
    /// Use .snappy on iOS-17+, fall back to .easeInOut elsewhere.
    func animationSnappyCompat<Value: Equatable>(_ value: Value,
                                                 duration: Double = 0.18,
                                                 extraBounce: Double = 0.02) -> some View {
        if #available(iOS 17.0, *) {
            return self.animation(.snappy(duration: duration, extraBounce: extraBounce), value: value)
        } else {
            return self.animation(.easeInOut(duration: duration), value: value)
        }
    }
}

// MARK: - Theme & Focus

private struct GameTheme {
    let accent: Color
    let bgStart: Color
    let bgEnd: Color
    let chipBG: Color

    static func `for`(_ g: Game) -> GameTheme {
        switch g {
        case .pokemon:
            return .init(accent: .yellow,
                         bgStart: Color(red: 0.12, green: 0.20, blue: 0.55),
                         bgEnd:   Color(red: 0.05, green: 0.08, blue: 0.22),
                         chipBG:  Color.yellow.opacity(0.18))
        case .magic:
            return .init(accent: .orange,
                         bgStart: Color(red: 0.26, green: 0.10, blue: 0.06),
                         bgEnd:   Color(red: 0.06, green: 0.04, blue: 0.10),
                         chipBG:  Color.orange.opacity(0.18))
        case .yugioh:
            return .init(accent: .red,
                         bgStart: Color(red: 0.28, green: 0.00, blue: 0.07),
                         bgEnd:   Color(red: 0.06, green: 0.02, blue: 0.10),
                         chipBG:  Color.red.opacity(0.18))
        }
    }
}

private enum FocusField: Hashable { case name, number }

// MARK: - Entry

struct ContentView: View {
    var body: some View { HomeScreen() }
}

// MARK: - Main screen

private struct HomeScreen: View {
    @EnvironmentObject var favorites: FavoritesStore
    @StateObject private var vm = CardSearchViewModel()

    @State private var showScanner = false
    @State private var isScanning = false
    @State private var showFavorites = false

    @State private var showCardDetail = false
    @State private var selectedCard: UICard?

    @State private var searchBump: Int = 0
    @State private var debounceWork: DispatchWorkItem?
    @FocusState private var focus: FocusField?

    private let grid: [GridItem] = [GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)]
    private var isBusy: Bool { vm.isLoading || isScanning }
    private var theme: GameTheme { GameTheme.for(vm.game) }

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [theme.bgStart, theme.bgEnd],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                // ---- The ScrollView section is now isolated and wrapped by availability
                Group {
                    if #available(iOS 16.0, *) {
                        scrollSection
                            .scrollIndicators(.hidden)
                            .scrollDismissesKeyboard(.interactively)
                    } else {
                        scrollSection
                    }
                }
                // --------------------------------------------------------------
            }
            .navigationTitle("Card Sense ✨")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showFavorites = true } label: {
                        Image(systemName: "heart.text.square").imageScale(.large)
                    }
                    .tint(theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)

        // Bottom Search / Scan
        .safeAreaInset(edge: .bottom) {
            ControlBarView(
                theme: theme,
                isBusy: isBusy,
                isScanning: isScanning,
                onSearch: {
                    guard !isBusy else { return }
                    triggerSearch()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                },
                onScan: {
                    guard !isBusy else { return }
                    isScanning = true
                    showScanner = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            )
        }

        // Scanner sheet
        .sheet(isPresented: $showScanner, onDismiss: { isScanning = false }) {
            ScannerView(game: vm.game) { name, number in
                isScanning = false
                showScanner = false
                vm.applyScan(name: name ?? "", number: number)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .onAppear { isScanning = true }
            .tint(theme.accent)
        }

        // Favorites sheet
        .sheet(isPresented: $showFavorites) {
            FavoritesSheet(
                cards: favorites.cards,
                onRemove: { favorites.remove($0) },
                onSelect: { card in
                    showFavorites = false
                    selectedCard = card
                    showCardDetail = true
                }
            )
        }

        // Card detail sheet
        .sheet(isPresented: $showCardDetail) {
            if let c = selectedCard {
                CardDetailView(card: c)
            } else {
                Color.clear
            }
        }

        // Animations
        .animationSnappyCompat(vm.results)
        .animationSnappyCompat(vm.isLoading)

        // UX hooks
        .onChange(of: vm.isLoading) { if $0 { focus = nil } }
        .onChange(of: vm.selectedRarity) { _ in autoSearchDebounced() }
        .onChange(of: vm.numberFilter)   { _ in if vm.game != .yugioh { autoSearchDebounced() } }
        .onChange(of: vm.game) { _ in
            debounceWork?.cancel()
            vm.query = ""
            vm.numberFilter = ""
            vm.selectedRarity = nil
            vm.priceBadges = [:]
            searchBump &+= 1
            focus = .name
        }
    }

    // MARK: - Extracted ScrollView

    private var scrollSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(theme: theme)

                GamePickerView(theme: theme, selection: $vm.game)

                FilterSectionView(
                    theme: theme,
                    game: vm.game,
                    query: $vm.query,
                    number: $vm.numberFilter,
                    rarityOptions: vm.rarityOptions,
                    selectedRarity: vm.selectedRarity,
                    onSelectRarity: { vm.selectedRarity = $0 },
                    onSearch: triggerSearch
                )
                .id(searchBump)
                .zIndex(2)

                if let err = cleanErrorText(vm.errorText, whileLoading: vm.isLoading) {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                ResultsGridView(
                    theme: theme,
                    grid: grid,
                    results: vm.results,
                    priceBadges: vm.priceBadges
                )
                .onTapGesture {
                    focus = nil
                    // iOS 15 keyboard dismiss
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }

                if vm.isLoading {
                    ProgressView()
                        .tint(theme.accent)
                        .padding(.bottom, 24)
                }
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Actions / Helpers

    private func triggerSearch() {
        focus = nil
        searchBump &+= 1
        vm.startSearch()
    }

    private func autoSearchDebounced(interval: TimeInterval = 0.35) {
        debounceWork?.cancel()
        let work = DispatchWorkItem { triggerSearch() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func cleanErrorText(_ text: String?, whileLoading: Bool) -> String? {
        guard !whileLoading else { return nil }
        guard var t = text, !t.isEmpty else { return nil }
        let lower = t.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("cancelled") { return nil }
        if let newline = t.firstIndex(of: "\n") { t = String(t[..<newline]) }
        return t
    }
}

// MARK: - Subviews (tiny = fast compile)

private struct HeaderView: View {
    let theme: GameTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: "sparkles").foregroundStyle(theme.accent)
                }
                Text("Card Sense")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text("Search · See Art · Learn")
                .foregroundStyle(.white.opacity(0.72))
                .font(.subheadline)
        }
        .padding(.horizontal)
    }
}

private struct GamePickerView: View {
    let theme: GameTheme
    @Binding var selection: Game
    var body: some View {
        Picker("Game", selection: $selection) {
            ForEach(Game.allCases) { g in Text(g.rawValue).tag(g) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06))
        )
        .padding(.horizontal)
    }
}

private struct FilterSectionView: View {
    let theme: GameTheme
    let game: Game
    @Binding var query: String
    @Binding var number: String
    let rarityOptions: [String]
    let selectedRarity: String?
    let onSelectRarity: (String?) -> Void
    let onSearch: () -> Void

    @FocusState private var focus: FocusField?

    var body: some View {
        VStack(spacing: 12) {
            // Name
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name…", text: $query)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .name)
                    .submitLabel(.search)
                    .onTapGesture { focus = .name }
                    .onSubmit { onSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical)
                    }
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(glassBG(), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

            // Number + Rarity
            HStack(spacing: 12) {
                if game != .yugioh {
                    HStack(spacing: 8) {
                        Image(systemName: "number").foregroundStyle(.secondary)
                        TextField("Card number (optional)…", text: $number)
                            .textFieldStyle(.plain)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focus, equals: .number)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(glassBG(), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }

                Menu {
                    Button("All Rarities") { onSelectRarity(nil) }
                    ForEach(rarityOptions, id: \.self) { r in
                        if !r.isEmpty {
                            Button(r) { onSelectRarity(r) }
                        }
                    }
                } label: {
                    Label(selectedRarity ?? "All Rarities",
                          systemImage: "line.3.horizontal.decrease.circle")
                        .frame(maxWidth: 180, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)
                .id(game)
                .zIndex(3)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(glassBG())
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        )
        .padding(.horizontal)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Search") { onSearch() }
            }
        }
    }
}

private struct ResultsGridView: View {
    let theme: GameTheme
    let grid: [GridItem]
    let results: [UICard]
    let priceBadges: [String: PriceBadge]

    var body: some View {
        LazyVGrid(columns: grid, spacing: 14) {
            ForEach(results) { card in
                NavigationLink(destination: CardDetailView(card: card)) {
                    CardTile(theme: theme, card: card, badge: priceBadges[card.id])
                        .transition(.scale.combined(with: .opacity))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}

private struct CardTile: View {
    let theme: GameTheme
    let card: UICard
    let badge: PriceBadge?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: card.imageSmallURL ?? card.imageLargeURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.white.opacity(0.06))
            }
            .frame(height: 210)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text(card.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(card.game.rawValue).font(.caption).foregroundStyle(.white.opacity(0.75))
                if let num = card.number {
                    Text("#\(num)").font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                if let badge {
                    if let usd = badge.usd, !usd.isEmpty {
                        Text("$\(usd)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(theme.chipBG).clipShape(Capsule())
                    }
                    if let eur = badge.eur, !eur.isEmpty {
                        Text("€\(eur)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.10)).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(glassBG())
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)
    }
}

private struct ControlBarView: View {
    let theme: GameTheme
    let isBusy: Bool
    let isScanning: Bool
    let onSearch: () -> Void
    let onScan: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { if !isBusy { onSearch() } }) {
                Text(isBusy ? "Searching…" : "Search")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .opacity(isBusy ? 0.6 : 1.0)

            Button(action: { if !isBusy { onScan() } }) {
                Label(isScanning ? "Scanning…" : "Scan", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(theme.accent)
            .opacity(isBusy ? 0.6 : 1.0)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(
            Rectangle().fill(
                LinearGradient(colors: [Color.black.opacity(0.14), Color.black.opacity(0.10)],
                               startPoint: .top, endPoint: .bottom)
            )
        )
        .overlay(Divider().opacity(0.25), alignment: .top)
        .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: -2)
    }
}

// MARK: - Simple “glass” background (no Materials)

@ViewBuilder
private func glassBG() -> some ShapeStyle {
    LinearGradient(
        colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Favorites Sheet

struct FavoritesSheet: View {
    let cards: [UICard]
    let onRemove: (UICard) -> Void
    let onSelect: (UICard) -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(cards) { card in
                    Button { onSelect(card) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: card.imageSmallURL ?? card.imageLargeURL) { img in
                                img.resizable().scaledToFill()
                            } placeholder: { Color.secondary.opacity(0.15) }
                            .frame(width: 54, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.name).font(.subheadline.weight(.semibold))
                                HStack(spacing: 6) {
                                    Text(card.game.rawValue).font(.caption).foregroundStyle(.secondary)
                                    if let n = card.number { Text("#\(n)").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { onRemove(card) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Favorites")
        }
        .navigationViewStyle(.stack)
    }
}
