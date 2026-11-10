import GymCore
import GymData
import SwiftUI
import UIKit

/// One listing: its photo, loads, quantity and note, with Save and a confirmed Delete, and how it is shared. A listing
/// with no photo can get one here. Someone else's listing, and my own once it is shared, is shown but not edited.
struct ListingDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let listing: GymListing
    let gym: Gym
    /// The listing as it is now: sharing changes it from outside this screen (the queue, a refresh).
    @State private var current: GymListing
    @State private var duplicates: [RemoteListing] = []
    @State private var signIn = SignInGate()
    @State private var photoFile: String?
    @State private var loads: ListingLoads
    @State private var quantity: Int
    @State private var notes: String
    @State private var errorText: String?
    @State private var confirmingDelete = false
    @State private var photoWidth: CGFloat = 330
    @State private var showCamera = false
    @State private var isProcessingCamera = false
    @State private var showReport = false
    @State private var reportSubject = ReportContentModel.Subject.listing
    @State private var didReport = false
    @State private var confirmingBlock = false
    @State private var borrowedShown = false

    init(listing: GymListing, gym: Gym) {
        self.listing = listing
        self.gym = gym
        _current = State(initialValue: listing)
        _photoFile = State(initialValue: listing.photoFile)
        _loads = State(initialValue: listing.loads)
        _quantity = State(initialValue: listing.quantity)
        _notes = State(initialValue: listing.notes ?? "")
    }

    private var kind: EquipmentKind? { current.status == .unsupported ? nil : env.gymCatalog.kind(listing.item.kindId) }
    private var status: ShareStatusModel { ShareStatusModel(listing: current, gym: gym) }
    private var title: String { kind?.name ?? GymEquipmentModel.unknownKindTitle }
    private var editing: ListingLoadsEditing? {
        kind.map { ListingLoadsEditing(kind: $0, unit: env.profile.unit, loads: loads) }
    }
    private var canSave: Bool { editing?.isValid ?? false }
    /// Someone else's listing on the server: it can be reported, and its author hidden.
    private var canReport: Bool { current.visibility == .shared && current.uploadState == .uploaded && !current.isOwn }
    private var canReportPhoto: Bool { photoFile == nil && borrowedShown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                photo
                headerText
                if confirmingBlock { BlockAuthorCard(onCancel: { confirmingBlock = false }, onConfirm: blockAuthor) }
                if kind == nil {
                    Text("This item came from a newer version of the app. Update the app to use it.")
                        .foregroundStyle(Theme.textSecondary).accessibilityIdentifier("listing.unknown")
                } else {
                    ShareStatusRow(status: status, duplicates: duplicates,
                                   onAction: { action in gated(Self.purpose(of: action)) { perform(action) } },
                                   onKeepExisting: { id in gated(.confirm) { keepExisting(id) } })
                    if status.canEdit { fields } else { readOnlyFields }
                }
                if let errorText { Text(errorText).foregroundStyle(Theme.destructive).accessibilityIdentifier("listing.error") }
                if kind != nil, status.canEdit {
                    PrimaryGlassButton(title: "Save", identifier: "listing.save", action: save).disabled(!canSave)
                }
                if status.canRemove { deleteSection }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { photoWidth = $0 - 2 * Theme.gutter }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .signInForSharing(gate: signIn)
        .toolbar { if canReport || canReportPhoto { ToolbarItem(placement: .primaryAction) { moderationMenu } } }
        .sheet(isPresented: $showReport, onDismiss: { if didReport && reportSubject == .listing { dismiss() } }) {
            ReportContentSheet(subject: reportSubject, send: sendReport)
        }
        .task(id: env.gymRevision) { reload() }
    }

    private var moderationMenu: some View {
        Menu {
            if canReport {
                Button("Report", systemImage: "flag") { startReport(.listing) }.accessibilityIdentifier("listing.report")
                Button("Hide everything from this user", systemImage: "hand.raised") { confirmingBlock = true }
                    .accessibilityIdentifier("listing.block")
            }
            if canReportPhoto {
                Button("Report this photo", systemImage: "photo.badge.exclamationmark") { startReport(.photo) }
                    .accessibilityIdentifier("listing.reportCatalogPhoto")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("listing.menu")
    }

    // MARK: Parts

    private var photo: some View {
        VStack(spacing: 10) {
            ListingPhotoView(photoFile: photoFile, kindId: listing.item.kindId,
                             catalogPhotoPath: current.item.catalogPhotoPath, width: photoWidth,
                             height: photoWidth * 0.7, full: true, cornerRadius: Theme.cardRadius, showsNote: true,
                             onCatalogShown: { borrowedShown = $0 })
            if photoFile == nil, kind != nil, status.canEdit { addPhotoButtons }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(onPicture: { image in
                showCamera = false
                Task { await attach(image) }
            }, onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var addPhotoButtons: some View {
        if isProcessingCamera {
            ProgressView("Checking the photo\u{2026}").frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
                .accessibilityIdentifier("listing.takePhoto.processing")
        } else {
            if CameraPicker.isAvailable {
                SecondaryGlassButton(title: "Take Photo", identifier: "listing.takePhoto") { showCamera = true }
            }
            GymPhotoPicker(title: "Add a photo", identifier: "listing.addPhoto", onPhoto: attach) { errorText = $0 }
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

    /// What a shared listing says, which this phone can't change.
    @ViewBuilder
    private var readOnlyFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let loads = ListingLoadsText.text(current.loads, unit: env.profile.unit) {
                Text(loads).foregroundStyle(Theme.textPrimary).accessibilityIdentifier("listing.loads")
            }
            if current.quantity > 1 { Text("Quantity: \(current.quantity)").foregroundStyle(Theme.textSecondary) }
            if let notes = current.notes { Text(notes).foregroundStyle(Theme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An inline card rather than a system dialog: those didn't confirm reliably under UI tests in the gym picker.
    @ViewBuilder
    private var deleteSection: some View {
        if confirmingDelete {
            VStack(alignment: .leading, spacing: 10) {
                Text("Delete \(title)?").font(.headline).foregroundStyle(Theme.textPrimary)
                Text(status.deleteMessage).font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("listing.delete.message")
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

    // MARK: Sharing

    /// Runs the work now when signed in; otherwise asks for a sign-in first and runs it only after one. Cancelling the
    /// sheet runs nothing, even if the sign-in finishes afterwards.
    private func gated(_ purpose: SignInPurpose, _ work: @escaping () -> Void) {
        guard env.sharingUserId != nil else {
            signIn.ask(purpose, then: work)
            return
        }
        work()
    }

    private static func purpose(of action: ShareStatusModel.Action) -> SignInPurpose {
        switch action {
        case .share, .retry, .shareAnyway: .share
        case .confirm: .confirm
        case .sync: .sync
        }
    }

    private func perform(_ action: ShareStatusModel.Action) {
        attempt {
            switch action {
            case .share: try env.shareListing(listing.id)
            case .retry: try env.retryShare(listing.id)
            case .confirm: try env.confirmListing(listing.id)
            case .shareAnyway: try env.shareListing(listing.id, forceNew: true)
            case .sync: try env.syncListing(listing.id)
            }
        }
    }

    /// "Yes, that's it" on a listing the gym already had: mine goes, theirs is confirmed.
    private func keepExisting(_ existingId: UUID) {
        attempt {
            try env.keepExistingListing(listing.id, existing: existingId)
            dismiss()
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            errorText = nil
        } catch GymCatalogError.signedOut {
            errorText = "Sign in to share."
        } catch GymDataError.invalidInput(let message) {
            errorText = message
        } catch {
            AppEnvironment.log.error("Sharing action failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't do that. Try again."
        }
    }

    private func reload() {
        do {
            guard let fresh = try env.gyms.listing(listing.id) else {
                // A reported listing is gone from the lists at once; its sheet says thanks before this screen closes.
                if !showReport { dismiss() }
                return
            }
            current = fresh
            photoFile = fresh.photoFile
            duplicates = fresh.uploadState == .waitingForChoice ? try env.gymSharing.outbox.duplicates(listingId: fresh.id) : []
        } catch {
            AppEnvironment.log.error("Reload listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Reporting

    private func startReport(_ subject: ReportContentModel.Subject) {
        reportSubject = subject
        didReport = false
        showReport = true
    }

    private func sendReport(_ reason: ReportReason, _ note: String?) throws {
        if reportSubject == .photo {
            try env.reportCataloguePhoto(onListing: listing.id, reason: reason, note: note)
        } else {
            try env.reportListing(listing.id, reason: reason, note: note)
        }
        didReport = true
    }

    private func blockAuthor() {
        gated(.block) {
            attempt {
                try env.blockAuthor(ofListing: listing.id)
                dismiss()
            }
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

    private func attach(_ image: UIImage) async {
        isProcessingCamera = true
        let outcome = await GymPhotoCleaning.clean(image)
        isProcessingCamera = false
        switch outcome {
        case .photo(let photo): attach(photo)
        case .failed(let message): errorText = message
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
