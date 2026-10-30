import GymCore
import GymData
import SwiftUI

/// One listing: its photo, loads, quantity and note, with Save and a confirmed Delete. A listing with no photo can
/// get one here.
struct ListingDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let listing: GymListing
    let gym: Gym
    @State private var photoFile: String?
    @State private var loads: ListingLoads
    @State private var quantity: Int
    @State private var notes: String
    @State private var errorText: String?
    @State private var confirmingDelete = false
    @State private var photoWidth: CGFloat = 330

    init(listing: GymListing, gym: Gym) {
        self.listing = listing
        self.gym = gym
        _photoFile = State(initialValue: listing.photoFile)
        _loads = State(initialValue: listing.loads)
        _quantity = State(initialValue: listing.quantity)
        _notes = State(initialValue: listing.notes ?? "")
    }

    private var kind: EquipmentKind? { env.gymCatalog.kind(listing.item.kindId) }
    private var title: String { kind?.name ?? GymEquipmentModel.unknownKindTitle }
    private var editing: ListingLoadsEditing? {
        kind.map { ListingLoadsEditing(kind: $0, unit: env.profile.unit, loads: loads) }
    }
    private var canSave: Bool { editing?.isValid ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                photo
                headerText
                if kind == nil {
                    Text("This item came from a newer version of the app. Update the app to use it.")
                        .foregroundStyle(Theme.textSecondary).accessibilityIdentifier("listing.unknown")
                } else {
                    fields
                }
                if let errorText { Text(errorText).foregroundStyle(Theme.destructive).accessibilityIdentifier("listing.error") }
                if kind != nil {
                    PrimaryGlassButton(title: "Save", identifier: "listing.save", action: save).disabled(!canSave)
                }
                deleteSection
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { photoWidth = $0 - 2 * Theme.gutter }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Parts

    private var photo: some View {
        VStack(spacing: 10) {
            GymPhotoView(fileName: photoFile, width: photoWidth, height: photoWidth * 0.7, full: true,
                         cornerRadius: Theme.cardRadius, placeholderSymbol: "dumbbell")
            if photoFile == nil, kind != nil {
                GymPhotoPicker(title: "Add a photo", identifier: "listing.addPhoto", onPhoto: attach) { errorText = $0 }
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisplayTitle(text: title, size: 30).lineLimit(2).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("listing.title")
            let brand = [listing.item.brand, listing.item.model].compactMap { $0 }.joined(separator: " ")
            if kind != nil, !brand.isEmpty { Text(brand).foregroundStyle(Theme.textSecondary) }
        }
    }

    @ViewBuilder
    private var fields: some View {
        if let kind {
            ListingLoadsEditor(loads: $loads, kind: kind, unit: env.profile.unit, idPrefix: "listing")
        }
        Stepper(value: $quantity, in: 1...GymRepository.maxQuantity) {
            Text("Quantity: \(quantity)").foregroundStyle(Theme.textPrimary)
        }
        .frame(minHeight: Theme.minTapSize)
        .accessibilityIdentifier("listing.quantity")
        TextField("Note (optional)", text: $notes, axis: .vertical)
            .lineLimit(1...4)
            .padding(12).frame(minHeight: Theme.minTapSize)
            .background(Theme.cardInner, in: .rect(cornerRadius: 12))
            .onChange(of: notes) { _, text in
                if text.count > GymRepository.maxNotesLength { notes = String(text.prefix(GymRepository.maxNotesLength)) }
            }
            .accessibilityIdentifier("listing.notes")
    }

    /// An inline card rather than a system dialog: those didn't confirm reliably under UI tests in the gym picker.
    @ViewBuilder
    private var deleteSection: some View {
        if confirmingDelete {
            VStack(alignment: .leading, spacing: 10) {
                Text("Delete \(title)?").font(.headline).foregroundStyle(Theme.textPrimary)
                Text("It and its photo will be deleted from this phone. This can't be undone.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    SecondaryGlassButton(title: "Cancel", identifier: "listing.delete.cancel") { confirmingDelete = false }
                    PrimaryGlassButton(title: "Delete", identifier: "listing.delete.confirm", action: delete)
                }
            }
            .padding(12)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            .accessibilityElement(children: .contain)
        } else {
            SecondaryGlassButton(title: "Delete", identifier: "listing.delete") { confirmingDelete = true }
        }
    }

    // MARK: Actions

    private func save() {
        guard let editing else { return }
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try env.gyms.updateListing(listing.id, loads: editing.loads, quantity: quantity,
                                       notes: note.isEmpty ? nil : note)
            env.gymsChanged()
            dismiss()
        } catch GymDataError.invalidInput(let message) {
            errorText = message
        } catch {
            AppEnvironment.log.error("Save listing failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't save. Try again."
        }
    }

    private func delete() {
        do {
            try env.removeListing(listing.id)
            dismiss()
        } catch {
            AppEnvironment.log.error("Delete listing failed: \(error.localizedDescription, privacy: .public)")
            confirmingDelete = false
            errorText = "Couldn't delete this item. Try again."
        }
    }

    private func attach(_ processed: ProcessedGymPhoto) {
        do {
            try env.attachPhoto(processed, to: listing.id)
            photoFile = try env.gyms.listing(listing.id)?.photoFile
            errorText = nil
        } catch {
            AppEnvironment.log.error("Attach photo failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't save the photo. Try again."
        }
    }
}
