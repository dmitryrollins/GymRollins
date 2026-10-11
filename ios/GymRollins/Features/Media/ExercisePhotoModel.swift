import Foundation
import GymCore
import Observation
import UIKit

/// Loads an exercise's photos for `ExercisePhotoView`. Empty `frames` = show the body-part illustration (no media,
/// still loading, offline without a cached copy, or a failed download): the view never shows a broken image.
@MainActor
@Observable
final class ExercisePhotoModel {
    enum Position: Int, Sendable {
        case start, end

        var label: String { self == .start ? "Start position" : "End position" }
    }

    struct Frame: Identifiable {
        let position: Position
        let image: UIImage
        var id: Int { position.rawValue }
    }

    private(set) var frames: [Frame] = []
    /// Where the shown frames come from (nil while nothing is shown).
    private(set) var source: ExerciseMedia.Source?
    /// Whether the shown photos are AI-generated (the view shows the "AI" badge).
    var isAIGenerated: Bool { source == .own }
    /// Credits the shown photos' licenses require (wger), in frame order; empty otherwise.
    private(set) var credits: [PhotoCredit] = []
    /// The credit for the caption (one author and license per exercise, see scripts/map-wger.mjs).
    var credit: PhotoCredit? { credits.first }

    /// VoiceOver label: start/end position for paired photos; wger images aren't guaranteed to be positions.
    func label(for frame: Frame) -> String {
        guard source == .wger else { return frame.position.label }
        let index = frames.firstIndex { $0.id == frame.id } ?? 0
        return "Photo \(index + 1) of \(frames.count)"
    }

    /// The frame to render for a selection that may be stale after `frames` changed.
    nonisolated static func visibleIndex(shown: Int, count: Int) -> Int {
        count == 0 ? 0 : min(max(shown, 0), count - 1)
    }
    /// The exercise `frames` belong to: a different exercise (e.g. after a swap) clears them before loading, so an
    /// old photo never shows under a new name.
    private var exerciseId: String?

    /// Resolves and downloads `exercise`'s photos. Frames that fail are skipped (a lone start photo still shows).
    /// When none of a source's photos load (e.g. hosted photos offline), the next source is tried (the bundled copy,
    /// then free-exercise-db). `maxFrames: 1` loads only the start photo (list thumbnails).
    func load(_ exercise: Exercise?, service: ExerciseMediaService, maxPixelSize: CGFloat?, maxFrames: Int = 2) async {
        if exercise?.id != exerciseId {
            show([], from: nil)
            exerciseId = exercise?.id
        }
        let candidates = exercise.map { service.provider.candidates(for: $0).filter { !$0.photos.isEmpty } } ?? []
        for media in candidates {
            let loaded = await load(media, loader: service.loader, maxPixelSize: maxPixelSize, maxFrames: maxFrames)
            guard !Task.isCancelled else { return }
            if !loaded.isEmpty {
                show(loaded, from: media)
                return
            }
        }
        show([], from: nil)
    }

    private func show(_ newFrames: [Frame], from media: ExerciseMedia?) {
        frames = newFrames
        source = media?.source
        credits = media?.credits ?? []
    }

    /// One source's frames, published as they arrive when that grows what's on screen; empty if none loaded.
    private func load(_ media: ExerciseMedia, loader: any ExercisePhotoLoading, maxPixelSize: CGFloat?,
                      maxFrames: Int) async -> [Frame] {
        let urls = Array(media.photos.prefix(min(maxFrames, 2)))
        var loaded: [Frame] = []
        // Frames are published as they arrive (a cached start photo shows while the end one downloads), but a
        // reload never shrinks what is already on screen before it finishes.
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, try? await loader.image(for: url, maxPixelSize: maxPixelSize)) }
            }
            for await (index, image) in group {
                guard !Task.isCancelled else { return }
                if let image, let position = Position(rawValue: index) {
                    loaded.append(Frame(position: position, image: image))
                    if loaded.count > frames.count {
                        show(loaded.sorted { $0.position.rawValue < $1.position.rawValue }, from: media)
                    }
                }
            }
        }
        return loaded.sorted { $0.position.rawValue < $1.position.rawValue }
    }
}
