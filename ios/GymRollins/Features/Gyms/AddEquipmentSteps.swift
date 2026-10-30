import GymCore
import SwiftUI
import UIKit

/// The step's counter and title.
struct AddEquipmentStepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Step \(number) of 4")
            DisplayTitle(text: title, size: 28).accessibilityAddTraits(.isHeader)
        }
    }
}

/// Step 1: a photo from the camera or the library, or none. Nothing is saved here: the cleaned photo waits in the model.
struct AddEquipmentPhotoStep: View {
    @Environment(AppEnvironment.self) private var env
    let model: AddEquipmentModel
    @State private var showCamera = false
    @State private var isProcessing = false
    @State private var openedCamera = false

    private var hasCamera: Bool { CameraPicker.isAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AddEquipmentStepHeader(number: 1, title: "Photo")
            Text("Photograph the equipment, not people. Faces are blurred automatically.")
                .foregroundStyle(Theme.textSecondary).accessibilityIdentifier("addEquipment.photoReminder")
            if let error = model.photoError {
                Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("addEquipment.photoError")
            }
            if isProcessing {
                ProgressView("Checking the photo\u{2026}").frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
                    .accessibilityIdentifier("addEquipment.processing")
            } else {
                buttons
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(onPicture: { data in
                showCamera = false
                Task { await process(data) }
            }, onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
        .task { openCameraOnce() }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            if hasCamera {
                PrimaryGlassButton(title: "Take Photo", identifier: "addEquipment.camera") { showCamera = true }
            }
            GymPhotoPicker(title: "Library", identifier: "addEquipment.library",
                           onPhoto: { model.photoProcessed($0) }, onFailure: { model.photoFailed($0) })
            SecondaryGlassButton(title: "Skip", identifier: "addEquipment.skip") { model.skipPhoto() }
        }
    }

    /// The camera opens at once, except in UI tests that feed a fixture photo. Dismissing it leaves the buttons.
    private func openCameraOnce() {
        guard hasCamera, !env.options.gymPhotoFixture, !openedCamera else { return }
        openedCamera = true
        showCamera = true
    }

    private func process(_ data: Data) async {
        isProcessing = true
        let outcome = await GymPhotoCleaning.clean(data)
        isProcessing = false
        switch outcome {
        case .photo(let photo): model.photoProcessed(photo)
        case .failed(let message): model.photoFailed(message)
        }
    }
}

/// Step 2: big tiles for the common kinds, grouped, plus a search over all of them.
struct AddEquipmentKindStep: View {
    @Environment(AppEnvironment.self) private var env
    let model: AddEquipmentModel
    @State private var query = ""

    private var results: [EquipmentKind] { env.gymCatalog.search(query) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AddEquipmentStepHeader(number: 2, title: "What is it?")
            TextField("Search kinds\u{2026}", text: $query)
                .textFieldStyle(.roundedBorder).frame(minHeight: Theme.minTapSize)
                .autocorrectionDisabled().accessibilityIdentifier("addEquipment.kindSearch")
            if let error = model.errorText {
                Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("addEquipment.error")
            }
            if isSearching { searchResults } else { sections }
            Text("Each kind already knows its exercises and muscles. You never tag muscles.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            Text("No kind matches that.").foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("addEquipment.kindNone")
        } else {
            tiles(results)
        }
    }

    private var sections: some View {
        ForEach(AddEquipmentModel.kindSections(env.gymCatalog)) { section in
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: section.title)
                tiles(section.kinds)
            }
        }
    }

    private func tiles(_ kinds: [EquipmentKind]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .top)], spacing: 10) {
            ForEach(kinds) { kind in
                Button { model.chooseKind(kind.id) } label: {
                    Text(kind.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center).padding(8)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Theme.card, in: .rect(cornerRadius: 14)).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addEquipment.kind.\(kind.id)")
            }
        }
    }
}
