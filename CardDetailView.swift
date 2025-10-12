import SwiftUI

struct CardDetailView: View {
    let card: UICard
    @EnvironmentObject var favorites: FavoritesStore

    @State private var priceRows: [PriceRow] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var sourceURLOverride: URL?   // prefer exact vendor page used by prices

    private var isFavorite: Bool { favorites.isFavorite(card.id) }

    // Prefer the exact page we used for prices; then the vendor page from search; finally apiURL
    private var openSourceURL: URL? {
        sourceURLOverride ?? card.webURL ?? card.apiURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // MARK: Image + Favorite
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: card.imageLargeURL ?? card.imageSmallURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.12))
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 0.8)
                    )

                    Button {
                        favorites.toggle(card)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label(isFavorite ? "Favorited" : "Favorite",
                              systemImage: isFavorite ? "heart.fill" : "heart")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
                .padding(.top, 8)
                .padding(.horizontal, 12)

                // MARK: Meta
                VStack(alignment: .leading, spacing: 10) {
                    Text(card.name)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))

                    HStack(spacing: 10) {
                        Text(card.game.rawValue).detailBadge()
                        if let setName = card.setName, !setName.isEmpty {
                            Text(setName).detailBadge()
                        } else if let set = card.setCode, !set.isEmpty {
                            Text(set).detailBadge()
                        }
                        if let n = card.number, !n.isEmpty {
                            Text("#\(n)").detailBadge()
                        }
                        if let r = card.rarity, !r.isEmpty {
                            Text(r).detailBadge()
                        }
                    }

                    if let url = openSourceURL {
                        Link(destination: url) {
                            Label("Open in Source", systemImage: "safari")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 16)

                // MARK: Prices
                Group {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Fetching prices…").foregroundStyle(.secondary)
                        }
                    } else if let err = errorText {
                        Text(err).foregroundStyle(.red).font(.subheadline)
                    } else if priceRows.isEmpty {
                        Text("No prices available for this card.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(priceRows) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.source).font(.subheadline.weight(.semibold))
                                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(row.value ?? "—")
                                        .font(.headline.weight(.semibold))
                                        .monospacedDigit()
                                    if let url = row.url {
                                        Link(destination: url) {
                                            Image(systemName: "arrow.up.right.square")
                                                .imageScale(.medium)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Open \(row.source) page")
                                    }
                                }
                                .padding(12)
                                .background(.thinMaterial,
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { openInSourceToolbar }
        .task { await loadPrices() }
    }

    // MARK: Toolbar button (top-right)
    @ToolbarContentBuilder
    private var openInSourceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let url = openSourceURL {
                Link(destination: url) {
                    Image(systemName: "safari")
                        .imageScale(.large)
                        .accessibilityLabel("Open in Source")
                }
            }
        }
    }
}

// MARK: - Logic

private extension CardDetailView {
    func loadPrices() async {
        await MainActor.run {
            isLoading = true
            errorText = nil
        }
        do {
            let rows = await MultigameService.loadPricesOptional(for: card) ?? []
            await MainActor.run {
                priceRows = rows
                isLoading = false
                errorText = rows.isEmpty ? "No price data found." : nil

                // Capture the exact vendor page the prices used (prefer first concrete URL)
                if sourceURLOverride == nil {
                    sourceURLOverride = rows.compactMap { $0.url }.first
                }
            }
        } catch is CancellationError {
            await MainActor.run { isLoading = false }
        } catch {
            await MainActor.run {
                isLoading = false
                errorText = "Couldn’t load prices. Please try again."
            }
        }
    }
}

// MARK: - Styling

private extension Text {
    func detailBadge() -> some View {
        self.font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }
}
