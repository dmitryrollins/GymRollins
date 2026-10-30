import PhotosUI
import SwiftUI
import UIKit

extension GymPhotoError {
    /// What to tell the user when a photo wasn't saved (spec §7).
    var userMessage: String {
        switch self {
        case .notAnImage: "That file isn't a photo we can use. Try another one."
        case .tooBig: "This photo couldn't be made small enough. Try another one."
        case .faceDetectionFailed:
            "We couldn't check this photo for faces, so it wasn't saved. Try again or skip the photo."
        }
    }
}

/// A generated picture for UI tests, which can't drive the system photo picker (`-gymPhotoFixture`).
enum GymPhotoFixture {
    static func jpegData() -> Data {
        let size = CGSize(width: 900, height: 600)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 120, y: 160, width: 660, height: 280))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

/// Picks a photo from the library, cleans it (`GymPhotoProcessor`: faces blurred, metadata gone) and hands the result
/// back. It saves nothing: the caller decides where the photo goes. A camera button joins it with `CameraPicker`.
struct GymPhotoPicker: View {
    @Environment(AppEnvironment.self) private var env
    let title: String
    let identifier: String
    let onPhoto: (ProcessedGymPhoto) -> Void
    let onFailure: (String) -> Void
    @State private var item: PhotosPickerItem?
    @State private var isProcessing = false

    var body: some View {
        Group {
            if isProcessing {
                ProgressView("Checking the photo\u{2026}")
                    .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
                    .accessibilityIdentifier("\(identifier).processing")
            } else if env.options.gymPhotoFixture {
                SecondaryGlassButton(title: title, identifier: identifier) {
                    Task { await process(GymPhotoFixture.jpegData()) }
                }
            } else {
                PhotosPicker(selection: $item, matching: .images) {
                    Text(title).font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier(identifier)
            }
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            item = nil
            Task { await load(picked) }
        }
    }

    private func load(_ picked: PhotosPickerItem) async {
        isProcessing = true
        let data: Data?
        do { data = try await picked.loadTransferable(type: Data.self) }
        catch {
            AppEnvironment.log.error("Load picked photo failed: \(error.localizedDescription, privacy: .public)")
            data = nil
        }
        guard let data else {
            isProcessing = false
            onFailure("We couldn't read that photo. Try another one.")
            return
        }
        await process(data)
    }

    private func process(_ data: Data) async {
        isProcessing = true
        let result = await Task.detached(priority: .userInitiated) {
            Result { try GymPhotoProcessor().process(data) }
        }.value
        isProcessing = false
        switch result {
        case .success(let photo): onPhoto(photo)
        case .failure(let error as GymPhotoError): onFailure(error.userMessage)
        case .failure(let error):
            AppEnvironment.log.error("Process gym photo failed: \(error.localizedDescription, privacy: .public)")
            onFailure("This photo couldn't be used. Try another one.")
        }
    }
}
