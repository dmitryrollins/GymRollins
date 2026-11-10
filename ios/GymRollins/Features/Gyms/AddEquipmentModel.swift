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
        /// The signed-in account; nil while signed out.
        var signedInUser: () -> UUID? = { nil }
        /// Queue the share (`forceNew` once the user said it is a different one), mark the listing synced, queue the
        /// +1 confirm. Each needs a signed-in account.
        var shareListing: (UUID, Bool) throws -> Void = { _, _ in }
        var syncListing: (UUID) throws -> Void = { _ in }
        var confirmListing: (UUID) throws -> Void = { _ in }
        /// Branded models: this phone's and the server's. It can be slow, so the step doesn't wait for it.
        var items: (String) async -> [CatalogueItem] = { _ in [] }
        /// Stores a model picked from the server before a listing of it is created.
        var upsertItem: (CatalogueItem) throws -> Void = { _ in }
    }

    /// What waits for a sign-in.
    enum Pending: Equatable { case save, confirm(GymListing) }

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
    /// The model picked from the server or My gyms, stored before the listing is created.
    private var chosenItem: CatalogueItem?
    private var pending: Pending?
    /// The user answered "No, it's a different one": the server isn't asked about duplicates again.
    private var saidDifferent = false

    var brand = ""
    var modelName = ""
    var note = ""
    var loads = ListingLoads.none
    /// Who sees the listing. "This phone only" until the user picks otherwise.
    var visibility = GymVisibility.device

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
            existing = Self.ordered(try ports.listings(kindId))
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
        saidDifferent = false
        step = existing.isEmpty ? .details : .duplicate
    }

    /// A photo was taken but the listing has its own: it stays, and the new one isn't saved.
    func keepsItsPhoto(_ listing: GymListing) -> Bool { photo != nil && listing.photoFile != nil }

    /// The photo taken here goes nowhere: someone else's listing keeps its own picture, and mine once it is shared is
    /// read-only (the server never gets a photo added afterwards, and a sign-out would delete it).
    func photoIsNotUsed(for listing: GymListing) -> Bool {
        photo != nil && listing.visibility == .shared && (!listing.isOwn || listing.photoFile == nil)
    }

    /// "Yes, that's it": no new listing. One of mine with no photo gets the photo just taken, unless it is shared;
    /// one with a photo keeps it.
    func sameAsExisting(_ listing: GymListing) {
        guard let photo, listing.photoFile == nil, listing.visibility != .shared else {
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
        saidDifferent = false
        chosenItem = item
        brand = item.item.brand ?? ""
        modelName = item.item.model ?? ""
        showsBrandFields = false
        step = .details
    }

    func chooseGeneric() {
        clearItem()
        saidDifferent = false
        step = .details
    }

    /// "No, it's a different one": the next step also asks for an optional brand and model.
    func different() {
        clearItem()
        saidDifferent = true
        showsBrandFields = true
        step = .details
    }

    func back() {
        pending = nil
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
        chosenItem = nil
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

    /// Saves the photo file, then the listing; if the listing can't be added the file just written goes again. Sharing
    /// or syncing it asks for a sign-in first and saves nothing until there is one.
    func save() {
        guard canSave, let kind else { return }
        errorText = nil
        photoSaveFailed = false
        if visibility != .device, ports.signedInUser() == nil {
            pending = .save
            return
        }
        let file: String?
        do { file = try photo.map(ports.savePhoto) }
        catch {
            AppEnvironment.log.error("Save gym photo failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't save the photo. Try again or save without it."
            photoSaveFailed = true
            return
        }
        do {
            if let chosenItem { try ports.upsertItem(chosenItem) }
            let listing = try ports.addListing(NewListing(
                gymId: gym.id, kindId: kind.id, brand: brand, model: modelName, loads: loads,
                notes: String(note.prefix(Self.noteLimit)), photoFile: file))
            outcome = .created(listing)
            queue(listing)
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

/// The sharing side of the add flow: who is asked to sign in, what is queued, and how step 3 lists the gym's rows.
extension AddEquipmentModel {
    /// A Maps gym can be shared; a private gym can be synced to the account. Both start at "This phone only".
    var visibilityOptions: [GymVisibility] { gym.isPrivate ? [.device, .synced] : [.device, .shared] }

    /// A share, sync or confirmation is waiting for the user to sign in.
    var signInNeeded: Bool { pending != nil }

    /// What the sign-in sheet says it is for.
    var signInPurpose: SignInPurpose {
        switch pending {
        case .confirm: .confirm
        case .save, nil: visibility == .synced ? .sync : .share
        }
    }

    /// Signed in: the action the user asked for goes ahead. If nobody is signed in after all, nothing is done.
    func signInFinished() {
        guard let action = pending else { return }
        pending = nil
        guard ports.signedInUser() != nil else {
            errorText = "Couldn't sign in. Nothing was shared."
            return
        }
        switch action {
        case .save: save()
        case let .confirm(listing): confirmExisting(listing)
        }
    }

    /// The sheet was closed without a sign-in: nothing was saved or queued.
    func signInCancelled() { pending = nil }

    // MARK: Step 3

    /// Mine can't be confirmed by me.
    func isAlreadyAdded(_ listing: GymListing) -> Bool { listing.isOwn }

    func hasConfirmed(_ listing: GymListing) -> Bool { !listing.isOwn && listing.confirmedByMe }

    func canConfirm(_ listing: GymListing) -> Bool {
        !listing.isOwn && !listing.confirmedByMe && listing.visibility == .shared && listing.uploadState == .uploaded
    }

    /// "Yes, that's it (+1 confirm)" on someone else's listing: queues the confirmation and ends the flow. The photo
    /// taken for this flow is not put on their listing.
    func confirmExisting(_ listing: GymListing) {
        guard canConfirm(listing) else { return }
        guard ports.signedInUser() != nil else {
            pending = .confirm(listing)
            return
        }
        do {
            try ports.confirmListing(listing.id)
            errorText = nil
            outcome = .confirmed(listing)
        } catch {
            AppEnvironment.log.error("Confirm listing failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't confirm this. Try again."
        }
    }

    /// Adds the server's models to the ones on this phone, unless the user has moved on from the step.
    func loadCatalogueItems() async {
        guard step == .duplicate, let kindId = kind?.id else { return }
        let items = await ports.items(kindId)
        guard step == .duplicate, kind?.id == kindId, !items.isEmpty else { return }
        known = items
    }

    /// Other people's rows first, the most confirmed on top; mine after.
    static func ordered(_ listings: [GymListing]) -> [GymListing] {
        let others = listings.filter { !$0.isOwn }.sorted {
            $0.confirmCount != $1.confirmCount ? $0.confirmCount > $1.confirmCount : $0.createdAt < $1.createdAt
        }
        return others + listings.filter(\.isOwn)
    }

    /// Queues the share or marks the listing synced. The listing is already saved on this phone, so a failure here
    /// leaves it as "Only me" for the detail screen to offer again.
    private func queue(_ listing: GymListing) {
        do {
            switch visibility {
            case .device: break
            case .shared: try ports.shareListing(listing.id, saidDifferent)
            case .synced: try ports.syncListing(listing.id)
            }
        } catch {
            AppEnvironment.log.error("Share new listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
