import GymCore
import GymData
import SwiftUI

/// Step 3: the gym already lists this kind. Reuse its listing, a known model, or go on with something new.
struct AddEquipmentDuplicateStep: View {
    @Environment(AppEnvironment.self) private var env
    let model: AddEquipmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AddEquipmentStepHeader(number: 3, title: "Already here?")
            Text("\(model.gym.name) already lists \(model.kind?.name.lowercased() ?? "this").")
                .foregroundStyle(Theme.textSecondary)
            ForEach(model.existing) { listing in existingCard(listing) }
            if let error = model.errorText {
                Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("addEquipment.error")
            }
            if !model.known.isEmpty { knownModels }
            SecondaryGlassButton(title: "Generic \(model.kind?.name.lowercased() ?? "item")",
                                 identifier: "addEquipment.generic") { model.chooseGeneric() }
            SecondaryGlassButton(title: "No, it's a different one", identifier: "addEquipment.different") {
                model.different()
            }
        }
    }

    private func existingCard(_ listing: GymListing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                GymPhotoView(fileName: listing.photoFile, width: 64, placeholderSymbol: "dumbbell")
                    .clipShape(.rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(listing)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    if let loads = ListingLoadsText.text(listing.loads, unit: env.profile.unit) {
                        Text(loads).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if model.keepsItsPhoto(listing) {
                Text("Keeps its photo. Your new one isn't saved.").font(.caption).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("addEquipment.keepsPhoto.\(listing.id.uuidString)")
            }
            PrimaryGlassButton(title: "Yes, that's it", identifier: "addEquipment.same.\(listing.id.uuidString)") {
                model.sameAsExisting(listing)
            }
        }
        .padding(12).background(Theme.card, in: .rect(cornerRadius: 14))
    }

    private var knownModels: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Or a known model")
            ForEach(model.known) { known in
                Button { model.chooseCatalogueItem(known) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([known.item.brand, known.item.model].compactMap { $0 }.joined(separator: " "))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text("listed at \(known.gymCount) \(known.gymCount == 1 ? "gym" : "gyms")")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: Theme.minTapSize, alignment: .leading)
                    .padding(12).background(Theme.card, in: .rect(cornerRadius: 14)).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addEquipment.known.\(known.item.id.uuidString)")
            }
        }
    }

    private static func title(_ listing: GymListing) -> String {
        let named = [listing.item.brand, listing.item.model].compactMap { $0 }.joined(separator: " ")
        return named.isEmpty ? "Generic" : named
    }
}

/// Step 4: the weights for the kind, an optional note, and Save. Everything scrolls, so Save stays reachable at
/// large text sizes.
struct AddEquipmentDetailsStep: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: AddEquipmentModel

    private var note: Binding<String> {
        Binding(get: { model.note }, set: { model.note = String($0.prefix(AddEquipmentModel.noteLimit)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AddEquipmentStepHeader(number: 4, title: model.editing?.hasInput == true ? "Weights and sharing" : "Details")
            if let kind = model.kind {
                Text(kind.name).font(.headline).foregroundStyle(Theme.textPrimary)
                ListingLoadsEditor(loads: $model.loads, kind: kind, unit: env.profile.unit, idPrefix: "addEquipment")
            }
            identity
            visibility
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Note (optional)")
                TextField("Note", text: note, axis: .vertical).lineLimit(1...4)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("addEquipment.note")
            }
            if let error = model.errorText {
                Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("addEquipment.error")
            }
            PrimaryGlassButton(title: "Save", identifier: "addEquipment.save") { model.save() }
                .disabled(!model.canSave)
            if model.photoSaveFailed {
                SecondaryGlassButton(title: "Save without the photo", identifier: "add.saveWithoutPhoto") {
                    model.saveWithoutPhoto()
                }
            }
        }
    }

    @ViewBuilder
    private var identity: some View {
        if model.showsBrandFields {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Brand and model (optional)")
                TextField("Brand", text: $model.brand).textInputAutocapitalization(.words)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("addEquipment.brand")
                TextField("Model", text: $model.modelName).textInputAutocapitalization(.words)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("addEquipment.model")
            }
        } else if !model.brand.isEmpty || !model.modelName.isEmpty {
            Text([model.brand, model.modelName].filter { !$0.isEmpty }.joined(separator: " "))
                .foregroundStyle(Theme.textSecondary).accessibilityIdentifier("addEquipment.item")
        }
    }

    private var visibility: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Who sees it")
            Text("This phone only").foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("addEquipment.visibility")
        }
    }
}
