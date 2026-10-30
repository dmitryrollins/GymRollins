import GymData
import SwiftUI

/// The add-equipment sheet (spec §5): photo, kind, "already here?", weights. It owns its own navigation stack and
/// closes itself when the flow ends. `onFinished` tells Build's `+ Add equipment` what was added.
struct AddEquipmentFlow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let gym: Gym
    var onFinished: (AddEquipmentModel.Outcome) -> Void = { _ in }
    @State private var model: AddEquipmentModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model { content(model) } else { Theme.background }
            }
            .navigationTitle("Add equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("addEquipment.cancel")
                }
            }
        }
        .task {
            guard model == nil else { return }
            model = AddEquipmentModel(gym: gym, catalog: env.gymCatalog, unit: env.profile.unit, ports: .live(env, gymId: gym.id))
        }
    }

    private func content(_ model: AddEquipmentModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.step == .duplicate || model.step == .details { backButton(model) }
                switch model.step {
                case .photo: AddEquipmentPhotoStep(model: model)
                case .kind: AddEquipmentKindStep(model: model)
                case .duplicate: AddEquipmentDuplicateStep(model: model)
                case .details: AddEquipmentDetailsStep(model: model)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .onChange(of: model.outcome) { _, outcome in
            guard let outcome else { return }
            if case .created = outcome { env.gymsChanged() }
            onFinished(outcome)
            dismiss()
        }
    }

    private func backButton(_ model: AddEquipmentModel) -> some View {
        Button { model.back() } label: {
            Label("Back", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
                .frame(minHeight: Theme.minTapSize)
        }
        .accessibilityIdentifier("addEquipment.back")
    }
}

extension AddEquipmentModel.Ports {
    /// The real stores: the gym's listings, the photo folder, and the catalogue.
    @MainActor
    static func live(_ env: AppEnvironment, gymId: UUID) -> Self {
        Self(
            listings: { kindId in try env.gyms.listings(gymId: gymId).filter { $0.item.kindId == kindId } },
            catalogueItems: { try env.gyms.catalogueItems(kindId: $0) },
            savePhoto: { try env.gymPhotos.save($0) },
            deletePhoto: { env.removeGymPhotos([$0]) },
            addListing: { try env.gyms.addListing($0) },
            attachPhoto: { photo, id in
                try env.attachPhoto(photo, to: id)
                guard let listing = try env.gyms.listing(id) else { throw GymDataError.invalidInput("That equipment was removed.") }
                return listing
            })
    }
}
