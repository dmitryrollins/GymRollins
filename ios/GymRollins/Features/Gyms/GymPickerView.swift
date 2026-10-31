import GymCore
import GymData
import SwiftUI

/// "Where are you training?": the gym nearby, an Apple Maps search, My gyms, a new private gym, or no gym at all.
struct GymPickerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var current: Gym?
    @State private var gyms: [Gym] = []
    @State private var itemCounts: [UUID: Int] = [:]
    @State private var photos: [UUID: String] = [:]
    @State private var nearby: NearbyGym?
    @State private var here: GymCoordinate?
    @State private var query = ""
    @State private var results: [GymPlace] = []
    @State private var searchFailed = false
    @State private var showAdd = false
    @State private var pendingDelete: Gym?
    @State private var equipmentGym: Gym?
    @State private var errorText: String?
    @State private var syncing: Gym?
    @State private var askingSignIn = false

    var body: some View {
        NavigationStack {
            List {
                if let pendingDelete { deleteConfirmation(pendingDelete) }
                if let current { currentRow(current) }
                if let nearby { nearbySection(nearby) }
                searchSection
                myGymsSection
                actionsSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Where are you training?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("gymPicker.close")
                }
            }
            .navigationDestination(item: $equipmentGym) { equipmentDestination($0) }
            .signInForSharing(isPresented: $askingSignIn) {
                if let gym = syncing { sync(gym) }
                syncing = nil
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showAdd) { AddPrivateGymSheet { _ in reload() } }
        .task { reload() }
        .onChange(of: env.gymRevision) { reload() }
        .task { await findNearby() }
        .task(id: query) { await search() }
    }

    private func equipmentDestination(_ gym: Gym) -> some View { GymEquipmentView(gym: gym) }

    // MARK: Sections

    /// Asks first, naming how much goes: a gym's equipment and photos can't be brought back.
    private func deleteConfirmation(_ gym: Gym) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(deleteTitle).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(deleteMessage(gym)).font(.footnote).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                SecondaryGlassButton(title: "Cancel", identifier: "gymPicker.delete.cancel") { pendingDelete = nil }
                PrimaryGlassButton(title: "Delete", identifier: "gymPicker.delete.confirm") { deletePending() }
            }
        }
        .listRowBackground(Theme.card)
        .accessibilityElement(children: .contain)
    }

    private func currentRow(_ gym: Gym) -> some View {
        Button { equipmentGym = gym } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRAINING AT").font(.caption.weight(.bold)).kerning(1).foregroundStyle(Theme.textTertiary)
                    Text(gym.name).font(.headline).foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.textTertiary)
            }
            .frame(minHeight: Theme.minTapSize)
            .contentShape(.rect)
        }
        .accessibilityHint("Opens this gym's equipment")
        .accessibilityIdentifier("gymPicker.currentEquipment")
        .listRowBackground(Theme.card)
    }

    private func nearbySection(_ nearby: NearbyGym) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(nearby.name).font(.headline).foregroundStyle(Theme.textPrimary)
                if let address = nearby.address {
                    Text(address).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                PrimaryGlassButton(title: "Train here", identifier: "gymPicker.nearby.train") { trainHere(nearby) }
            }
            .listRowBackground(Theme.card)
        } header: {
            SectionLabel(text: "Nearby \u{00B7} \(NearbyGymRule.distanceText(meters: nearby.distanceMeters, unit: env.profile.unit))")
        }
    }

    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search gyms on Apple Maps", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("gymPicker.search")
            }
            .frame(minHeight: Theme.minTapSize)
            .listRowBackground(Theme.card)
            if searchFailed {
                Text("Maps isn't available right now. You can still add a private gym.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("gymPicker.searchOffline")
                    .listRowBackground(Theme.card)
            }
            ForEach(results) { place in
                Button { choose(place) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        if let address = place.address {
                            Text(address).font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Theme.minTapSize, alignment: .leading)
                    .contentShape(.rect)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("gymPicker.place.\(place.placeId)")
                .listRowBackground(Theme.card)
            }
        }
    }

    @ViewBuilder
    private var myGymsSection: some View {
        if !gyms.isEmpty {
            Section {
                ForEach(gyms) { gym in gymRow(gym) }
            } header: {
                SectionLabel(text: "My gyms")
            }
        }
    }

    private func gymRow(_ gym: Gym) -> some View {
        Button { choose(gym) } label: {
            HStack(spacing: 12) {
                GymPhotoView(fileName: photos[gym.id], width: 44, placeholderSymbol: "mappin.and.ellipse")
                VStack(alignment: .leading, spacing: 4) {
                    Text(gym.name).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text(itemsText(itemCounts[gym.id] ?? 0)).font(.footnote).foregroundStyle(Theme.textSecondary)
                        Badge(text: Self.badgeText(for: gym), kind: .neutral)
                    }
                }
                Spacer(minLength: 8)
                if gym.id == current?.id { Image(systemName: "checkmark").foregroundStyle(Theme.primaryFill) }
            }
            .frame(minHeight: Theme.minTapSize)
            .contentShape(.rect)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(gym.id == current?.id ? .isSelected : [])
        .accessibilityAction(named: "Delete") { askToDelete(gym) }
        .accessibilityAction(named: Self.syncTitle) { if Self.canSync(gym) { askToSync(gym) } }
        .accessibilityIdentifier("gymPicker.gym.\(gym.name)")
        .listRowBackground(Theme.card)
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { askToDelete(gym) }
            if Self.canSync(gym) { syncButton(gym).tint(Theme.primaryFill) }
        }
        .contextMenu {
            if Self.canSync(gym) { syncButton(gym) }
        }
    }

    private func syncButton(_ gym: Gym) -> some View {
        Button(Self.syncTitle) { askToSync(gym) }.accessibilityIdentifier("picker.sync.\(gym.id.uuidString)")
    }

    private var actionsSection: some View {
        Section {
            if let errorText { Text(errorText).foregroundStyle(Theme.destructive).listRowBackground(Theme.card) }
            Button { showAdd = true } label: {
                Label("Add a private gym", systemImage: "plus").frame(maxWidth: .infinity, minHeight: Theme.minTapSize,
                                                                    alignment: .leading)
            }
            .accessibilityIdentifier("gymPicker.addPrivate")
            .listRowBackground(Theme.card)
            Button { chooseNone() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No gym").foregroundStyle(Theme.textPrimary)
                    Text("Use my plan as written").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: Theme.minTapSize, alignment: .leading)
                .contentShape(.rect)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gymPicker.none")
            .listRowBackground(Theme.card)
        }
    }

    // MARK: Text

    /// Where the gym's equipment lives: only here, in the account, or in the shared catalogue.
    static func badgeText(for gym: Gym) -> String {
        if gym.visibility == .synced { return "Synced" }
        return !gym.isPrivate && gym.remoteId != nil ? "Shared" : "Only me"
    }

    static let syncTitle = "Sync to my account"

    /// A private gym that only this phone has. A Maps gym is shared, not synced.
    static func canSync(_ gym: Gym) -> Bool { gym.isPrivate && gym.visibility == .device }

    private func itemsText(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    private var deleteTitle: String { pendingDelete.map { "Delete \($0.name)?" } ?? "Delete gym?" }

    private func deleteMessage(_ gym: Gym) -> String {
        let count = itemCounts[gym.id] ?? 0
        return count == 0 ? "This gym has no equipment listed yet."
            : "Its \(itemsText(count)) and their photos will be deleted from this phone. This can't be undone."
    }

    // MARK: Actions

    private func reload() {
        current = env.currentGym
        do {
            gyms = try env.gyms.gyms()
            itemCounts = try env.gyms.itemCounts()
            photos = try gyms.reduce(into: [:]) { result, gym in
                if let file = try env.gyms.listings(gymId: gym.id).compactMap(\.photoFile).first { result[gym.id] = file }
            }
            if case .saved(let saved) = nearby?.target, !gyms.contains(where: { $0.id == saved.id }) { nearby = nil }
            errorText = nil
        } catch {
            AppEnvironment.log.error("Read gyms failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't load your gyms."
        }
    }

    private func findNearby() async {
        here = await env.gymLocator.locate(askingPermission: true)
        guard let here else { return }
        nearby = await env.nearbyGym(at: here)
    }

    /// Waits 300 ms after the last keystroke (a new query cancels this task) before asking Maps.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            searchFailed = false
            return
        }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        do {
            let found = try await env.gymPlaces.search(query: text, near: here)
            guard !Task.isCancelled else { return }
            results = found
            searchFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            AppEnvironment.log.error("Gym search failed: \(error.localizedDescription, privacy: .public)")
            results = []
            searchFailed = true
        }
    }

    private func choose(_ gym: Gym) {
        guard env.setCurrentGym(gym.id) else {
            reload()
            errorText = GymChoiceError.gymGone.errorDescription
            return
        }
        dismiss()
    }

    private func choose(_ place: GymPlace) {
        perform("Couldn't add that gym. Try again.") { try env.chooseMapsGym(place) }
    }

    private func trainHere(_ nearby: NearbyGym) {
        do {
            try env.trainHere(nearby)
            dismiss()
        } catch GymChoiceError.gymGone {
            reload() // drops the suggestion whose gym is gone
            errorText = GymChoiceError.gymGone.errorDescription
        } catch {
            AppEnvironment.log.error("Train here failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't switch gyms. Try again."
        }
    }

    private func chooseNone() {
        env.setCurrentGym(nil)
        dismiss()
    }

    private func askToDelete(_ gym: Gym) {
        pendingDelete = gym
    }

    /// Needs an account: signed out, the sign-in sheet comes first and cancelling it uploads nothing.
    private func askToSync(_ gym: Gym) {
        guard env.sharingUserId != nil else {
            syncing = gym
            askingSignIn = true
            return
        }
        sync(gym)
    }

    private func sync(_ gym: Gym) {
        do {
            try env.syncGym(gym.id)
            reload()
        } catch {
            AppEnvironment.log.error("Sync gym failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't sync this gym. Try again."
        }
    }

    private func deletePending() {
        guard let gym = pendingDelete else { return }
        pendingDelete = nil
        delete(gym)
    }

    private func delete(_ gym: Gym) {
        do {
            try env.deleteGym(gym.id)
            reload()
        } catch {
            AppEnvironment.log.error("Delete gym failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't delete the gym. Try again."
        }
    }

    private func perform(_ failure: String, _ work: () throws -> Void) {
        do {
            try work()
            dismiss()
        } catch {
            AppEnvironment.log.error("Pick gym failed: \(error.localizedDescription, privacy: .public)")
            errorText = failure
        }
    }
}
