import GymCore
import SwiftUI

/// An exercise's start/end photos, filling whatever frame the caller gives it, with the body-part illustration as
/// the placeholder while loading, offline without a cached copy, on failure, or when the exercise has no photos.
///
/// Two photos crossfade gently (start <-> end) like a slow two-frame animation; with Reduce Motion they don't move
/// on their own. Tapping (or the VoiceOver action) flips to the other position.
struct ExercisePhotoView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let exercise: Exercise?
    var iconSize: CGFloat = 120
    /// Where the "AI" badge sits on AI-generated photos (callers move it clear of their own overlays).
    var aiBadgeAlignment: Alignment = .bottomTrailing
    var aiBadgePadding = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    /// Shows the "Photo: <author> · <license>" credit a licensed (wger) photo requires. On for the exercise detail
    /// (also the workout's How-To screen); list thumbnails and the logging hero link there instead.
    var showsCredit = false

    @State private var model = ExercisePhotoModel()
    @State private var shown = 0

    static let holdDuration: Duration = .seconds(2.4)
    static let fadeDuration = 0.9

    var body: some View {
        Color.clear
            .overlay {
                if model.frames.isEmpty {
                    BodyPartIcon(bodyPart: exercise?.bodyPart ?? "", size: iconSize)
                } else {
                    photos
                }
            }
            .overlay(alignment: aiBadgeAlignment) {
                if model.isAIGenerated && !model.frames.isEmpty {
                    AIPhotoBadge().padding(aiBadgePadding)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showsCredit, let credit = model.credit, !model.frames.isEmpty {
                    PhotoCreditBadge(credit: credit).padding(10)
                }
            }
            .clipped()
            .task(id: PhotoLoadKey(exerciseId: exercise?.id, revision: env.media.revision.value)) {
                shown = 0
                await model.load(exercise, service: env.media, maxPixelSize: nil)
            }
            .task(id: CrossfadeKey(count: model.frames.count, reduceMotion: reduceMotion)) {
                await crossfade()
            }
    }

    private var photos: some View {
        let visible = ExercisePhotoModel.visibleIndex(shown: shown, count: model.frames.count)
        let current = model.frames[visible]
        // wger images are mostly line drawings on transparency in varied shapes: shown whole on white.
        let isDrawing = model.source == .wger
        return ZStack {
            if isDrawing { Color.white }
            ForEach(Array(model.frames.enumerated()), id: \.element.id) { index, frame in
                Image(uiImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: isDrawing ? .fit : .fill)
                    .padding(isDrawing ? 8 : 0)
                    .opacity(index == visible ? 1 : 0)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: flip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.label(for: current))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("exercise.photo")
        .accessibilityActions {
            if model.frames.count > 1 { Button("Show other position", action: flip) }
        }
    }

    private func flip() {
        guard model.frames.count > 1 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Self.fadeDuration)) {
            shown = (ExercisePhotoModel.visibleIndex(shown: shown, count: model.frames.count) + 1) % model.frames.count
        }
    }

    private func crossfade() async {
        guard model.frames.count > 1, !reduceMotion, env.media.autoCrossfade else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled else { return }
            flip()
        }
    }

    private struct CrossfadeKey: Equatable {
        let count: Int
        let reduceMotion: Bool
    }
}

/// A list-row thumbnail: the exercise's start photo, or the body-part icon. Decorative (the row reads the name).
struct ExerciseThumbnail: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.displayScale) private var displayScale
    let exercise: Exercise?
    var size: CGFloat = 52
    /// The target-muscle badge on the corner (only at `minSizeForMuscles` and up).
    var showsMuscles = true

    @State private var model = ExercisePhotoModel()

    var body: some View {
        Group {
            if let frame = model.frames.first {
                let isDrawing = model.source == .wger // line drawings on transparency: whole, on white
                Image(uiImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: isDrawing ? .fit : .fill)
                    .padding(isDrawing ? 3 : 0)
                    .frame(width: size, height: size)
                    .background(isDrawing ? Color.white : Color.clear)
                    .clipShape(.rect(cornerRadius: size * 0.23))
            } else {
                BodyPartIcon(bodyPart: exercise?.bodyPart ?? "", size: size)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if showsMuscles, size >= Self.minSizeForMuscles, let layout = muscleLayout {
                MuscleBadge(layout: layout, size: size * 0.6)
                    .offset(x: size * 0.12, y: size * 0.12)
            }
        }
        .accessibilityHidden(true)
        .task(id: PhotoLoadKey(exerciseId: exercise?.id, revision: env.media.revision.value)) {
            await model.load(exercise, service: env.media, maxPixelSize: size * displayScale, maxFrames: 1)
        }
    }

    /// Below this the badge's figure is too small to read.
    static let minSizeForMuscles: CGFloat = 44

    private var muscleLayout: MuscleBadgeLayout? {
        exercise.flatMap { MuscleBadgeLayout(contributions: MuscleTaxonomy.contributions(for: $0)) }
    }
}

/// Photo views reload for a different exercise or when the media answers changed (`MediaRevision`).
struct PhotoLoadKey: Hashable {
    let exerciseId: String?
    let revision: Int
}
