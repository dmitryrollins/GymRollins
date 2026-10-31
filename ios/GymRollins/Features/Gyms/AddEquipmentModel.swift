import Foundation
import GymCore
import GymData
import Observation

/// The add-equipment flow (spec §5): photo, kind, "already here?", weights. It holds the step and the draft, and
/// writes nothing until `save()`: a photo is only a processed value in memory until then, so cancelling leaves no file.
@MainActor
@Observable
final class AddEquipmentModel {
    enum Step: Equatable { case photo, kind, duplicate, details }

    /// How the flow ended.
    enum Outcome: Equatable {
        case created(GymListing)
        /// "Yes, that's it" on the gym's own listing: no new row (the +1 confirm is plan 21's).
        case confirmed(GymListing)
    }

    /// What the flow reads and writes, so tests and screens bring their own store.
    struct Ports {
        let listings: (String) throws -> [GymListing]
        let catalogueItems: (String) throws -> [CatalogueItem]
        let savePhoto: (ProcessedGymPhoto) throws -> String
        let deletePhoto: (String) -> Void
        let addListing: (NewListing) throws -> GymListing
        /// Saves the photo and attaches it to a listing that has none; returns the listing as it is now.
        let attachPhoto: (ProcessedGymPhoto, UUID) throws -> GymListing
    }

    static let noteLimit = GymRepository.maxNotesLength
    static let brandLimit = GymRepository.maxBrandLength
    static let modelLimit = GymRepository.maxModelLength

    let gym: Gym
    let unit: WeightUnit
    private let catalog: GymEquipmentCatalog
    private let ports: Ports

    private(set) var step = Step.photo
    private(set) var kind: EquipmentKind?
    private(set) var existing: [GymListing] = []
    private(set) var known: [CatalogueItem] = []
    private(set) var showsBrandFields = false
    private(set) var photoError: String?
    private(set) var errorText: String?
    /// Saving the photo file failed: the details step then offers to save without it.
    private(set) var photoSaveFailed = false
    /// "Yes, that's it" couldn't save the photo on this listing: the step then offers to keep the listing without it.
    private var attachFailedFor: GymListing?
    private(set) var outcome: Outcome?
    private var photo: ProcessedGymPhoto?

    var brand = ""
    var modelName = ""
    var note = ""
    var loads = ListingLoads.none

    init(gym: Gym, catalog: GymEquipmentCatalog, unit: WeightUnit, ports: Ports) {
        self.gym = gym
        self.catalog = catalog
        self.unit = unit
        self.ports = ports
    }

    var hasPhoto: Bool { photo != nil }

    // MARK: Step 1

    /// A result that arrives after Skip (a library photo still processing) is dropped: whoever tapped Skip has moved on.
    func photoProcessed(_ processed: ProcessedGymPhoto) {
        guard step == .photo else { return }
        photo = processed
        photoError = nil
        step = .kind
    }

    /// Stays on the photo step, which offers another try or Skip.
    func photoFailed(_ message: String) {
        guard step == .photo else { return }
        photoError = message
    }

    func skipPhoto() {
        photo = nil
        photoError = nil
        step = .kind
    }

    // MARK: Step 2 and 3

    /// Moves on to "Already here?" when the gym lists the kind, else straight to the weights.
    func chooseKind(_ kindId: String) {
        guard let chosen = catalog.kind(kindId) else { return }
        do {
            existing = try ports.listings(kindId)
            known = existing.isEmpty ? [] : try ports.catalogueItems(kindId)
        } catch {
            AppEnvironment.log.error("Read listings for a kind failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't read this gym's equipment. Try again."
            return
        }
        errorText = nil
        kind = chosen
        loads = ListingLoadsEditing(kind: chosen, unit: unit, loads: .none).loads
        clearItem()
        step = existing.isEmpty ? .details : .duplicate
    }

    /// A photo was taken but the listing has its own: it stays, and the new one isn't saved.
    func keepsItsPhoto(_ listing: GymListing) -> Bool { photo != nil && listing.photoFile != nil }

    /// "Yes, that's it": no new listing. One with no photo gets the photo just taken; one with a photo keeps it.
    func sameAsExisting(_ listing: GymListing) {
        guard let photo, listing.photoFile == nil else {
            outcome = .confirmed(listing)
            return
        }
        do {
            outcome = .confirmed(try ports.attachPhoto(photo, listing.id))
            errorText = nil
        } catch {
            AppEnvironment.log.error("Attach gym photo failed: \(error.localizedDescription, privacy: .public)")
            attachFailedFor = listing
            errorText = "Couldn't save the photo. Try again, or keep the listing without it."
        }
    }

    var canConfirmWithoutPhoto: Bool { attachFailedFor != nil }

    /// The way out of a failed attach: the gym's listing is kept as it is and the photo is dropped.
    func confirmWithoutPhoto() {
        guard let listing = attachFailedFor else { return }
        attachFailedFor = nil
        outcome = .confirmed(listing)
    }

    func chooseCatalogueItem(_ item: CatalogueItem) {
        brand = item.item.brand ?? ""
        modelName = item.item.model ?? ""
        showsBrandFields = false
        step = .details
    }

    func chooseGeneric() {
        clearItem()
        step = .details
    }

    /// "No, it's a different one": the next step also asks for an optional brand and model.
    func different() {
        clearItem()
        showsBrandFields = true
        step = .details
    }

    func back() {
        errorText = nil
        photoSaveFailed = false
        attachFailedFor = nil
        switch step {
        case .photo, .kind: break
        case .duplicate: step = .kind
        case .details: step = existing.isEmpty ? .kind : .duplicate
        }
    }

    private func clearItem() {
        brand = ""
        modelName = ""
        showsBrandFields = false
    }

    // MARK: Step 4

    var editing: ListingLoadsEditing? { kind.map { ListingLoadsEditing(kind: $0, unit: unit, loads: loads) } }

    var canSave: Bool { step == .details && (editing?.isValid ?? false) }

    func stepStack(_ direction: Int) {
        guard let editing else { return }
        loads = editing.steppedStack(direction)
    }

    func toggleWeight(_ kg: Double) {
        guard let editing else { return }
        loads = editing.toggled(kg)
    }

    func toggleAllWeights() {
        guard let editing else { return }
        loads = editing.togglingAll()
    }

    /// Saves the photo file, then the listing; if the listing can't be added the file just written goes again.
    func save() {
        guard canSave, let kind else { return }
        errorText = nil
        photoSaveFailed = false
        let file: String?
        do { file = try photo.map(ports.savePhoto) }
        catch {
            AppEnvironment.log.error("Save gym photo failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't save the photo. Try again or save without it."
            photoSaveFailed = true
            return
        }
        do {
            let listing = try ports.addListing(NewListing(
                gymId: gym.id, kindId: kind.id, brand: brand, model: modelName, loads: loads,
                notes: String(note.prefix(Self.noteLimit)), photoFile: file))
            outcome = .created(listing)
        } catch {
            if let file { ports.deletePhoto(file) }
            errorText = Self.message(for: error)
        }
    }

    /// The way out of a failed photo save: drops the photo and saves the listing.
    func saveWithoutPhoto() {
        photo = nil
        photoSaveFailed = false
        save()
    }

    private static func message(for error: Error) -> String {
        if case GymDataError.invalidInput(let message) = error { return message }
        AppEnvironment.log.error("Add listing failed: \(error.localizedDescription, privacy: .public)")
        return "Couldn't save this equipment. Try again."
    }
}
