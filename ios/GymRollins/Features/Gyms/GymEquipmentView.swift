import GymCore
import GymData
import SwiftUI

/// A gym's equipment (spec §6): title, address and count, a coverage badge per muscle chip, and photo tiles grouped
/// by category. Reached from the gym picker.
struct GymEquipmentView: View {
    @Environment(AppEnvironment.self) private var env
    let gym: Gym
    @State private var model: GymEquipmentModel?
    @State private var errorText: String?
    @State private var selected: GymListing?
    @State private var showAdd = false
    @State private var gridWidth: CGFloat = 330

    private static let columnSpacing: CGFloat = 10
    private var tileWidth: CGFloat { max(120, (gridWidth - Self.columnSpacing) / 2) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let errorText { Text(errorText).foregroundStyle(Theme.destructive).accessibilityIdentifier("gymEquipment.error") }
                if let model {
                    if !model.coverage.isEmpty { coverage(model.coverage) }
                    if model.isEmpty { emptyState } else { ForEach(model.sections) { section($0) } }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 24)
        }
        // Measured outside the content: tiles sized from their own container's width would grow it every pass.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { gridWidth = $0 - 2 * Theme.gutter }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            PrimaryGlassButton(title: "+ Add equipment", identifier: "gymEquipment.add") { showAdd = true }
                .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
        }
        .navigationDestination(item: $selected) { ListingDetailView(listing: $0, gym: gym) }
        .sheet(isPresented: $showAdd) { AddEquipmentFlow(gym: gym) }
        .task(id: env.gymRevision) { await load() }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisplayTitle(text: gym.name, size: 34).lineLimit(2).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("gymEquipment.title")
            Text(model?.subtitle ?? gym.address ?? "").font(.subheadline).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("gymEquipment.subtitle")
        }
    }

    private func coverage(_ items: [GymEquipmentModel.Coverage]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Coverage")
            FlowLayout {
                ForEach(items) { item in
                    Badge(text: item.text, kind: item.isThin ? .record : .neutral)
                        .accessibilityLabel("\(item.muscle.rawValue.capitalized), \(item.count) items\(item.isThin ? ", thin" : "")")
                        .accessibilityIdentifier("gymEquipment.coverage.\(item.muscle.rawValue)")
                }
            }
        }
    }

    private var emptyState: some View {
        Text("Nothing here yet. Add the first piece of equipment.")
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityIdentifier("gymEquipment.empty")
    }

    private func section(_ section: GymEquipmentModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: section.title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth), spacing: Self.columnSpacing,
                                         alignment: .top)], spacing: Self.columnSpacing) {
                ForEach(section.tiles) { tile($0) }
            }
        }
    }

    private func tile(_ tile: GymEquipmentModel.Tile) -> some View {
        Button { selected = tile.listing } label: {
            VStack(alignment: .leading, spacing: 0) {
                GymPhotoView(fileName: tile.listing.photoFile, width: tileWidth, height: 96, cornerRadius: 0,
                             placeholderSymbol: "dumbbell")
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if let brand = tile.brandAndModel {
                        Text(brand).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    detailLine(tile)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: tileWidth, alignment: .topLeading)
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .clipShape(.rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gymEquipment.listing.\(tile.listing.item.kindId)")
    }

    private func detailLine(_ tile: GymEquipmentModel.Tile) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 4) {
            if let loads = tile.loadsText { Text(loads).font(.caption).foregroundStyle(Theme.textSecondary) }
            if let quantity = tile.quantityText {
                Text(quantity).font(.caption.weight(.bold)).foregroundStyle(Theme.textSecondary)
            }
            if let badge = tile.badge { Badge(text: badge.text, kind: badge.kind) }
        }
    }

    // MARK: Loading

    /// Shows the tiles at once, then the coverage once the rules have counted.
    private func load() async {
        let listings: [GymListing]
        do { listings = try env.gyms.listings(gymId: gym.id) }
        catch {
            AppEnvironment.log.error("Read gym equipment failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't load this gym's equipment."
            return
        }
        errorText = nil
        let unit = env.profile.unit
        model = GymEquipmentModel(gym: gym, listings: listings, catalog: env.gymCatalog, unit: unit,
                                  coverage: model?.coverage ?? [])
        let coverage = await env.gymCoverage(gymId: gym.id)
        guard !Task.isCancelled else { return }
        model = GymEquipmentModel(gym: gym, listings: listings, catalog: env.gymCatalog, unit: unit, coverage: coverage)
    }
}
