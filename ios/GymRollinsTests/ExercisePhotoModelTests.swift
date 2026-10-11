import Foundation
import GymCore
import Testing
import UIKit
@testable import GymRollins

/// Loader double: returns an image for URLs in `good`, throws for everything else.
private struct FakeLoader: ExercisePhotoLoading {
    let good: Set<URL>
    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> UIImage {
        guard good.contains(url) else { throw URLError(.notConnectedToInternet) }
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    }
}

/// Start photo immediately (cached), end photo never arrives until cancelled (slow network).
private struct SlowEndLoader: ExercisePhotoLoading {
    let end: URL
    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> UIImage {
        if url == end { try await Task.sleep(for: .seconds(60)) }
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    }
}

private struct FixedProvider: ExerciseMediaProvider {
    let media: ExerciseMedia?
    func media(for exercise: Exercise) -> ExerciseMedia? { media }
}

@MainActor
@Suite struct ExercisePhotoModelTests {
    private let start = URL(string: "https://cdn.example.com/a/0.jpg")!
    private let end = URL(string: "https://cdn.example.com/a/1.jpg")!
    private let bench = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                                 target: "pectorals")

    private func service(media: ExerciseMedia?, good: Set<URL>) -> ExerciseMediaService {
        ExerciseMediaService(provider: FixedProvider(media: media), loader: FakeLoader(good: good))
    }

    private var photos: ExerciseMedia { ExerciseMedia(photos: [start, end], animation: nil, source: .freeExerciseDB) }

    @Test func loadsBothFramesInOrder() async {
        let model = ExercisePhotoModel()
        await model.load(bench, service: service(media: photos, good: [start, end]), maxPixelSize: nil)
        #expect(model.frames.count == 2)
        #expect(model.frames.map(\.position) == [.start, .end])
    }

    @Test func noMediaKeepsThePlaceholder() async {
        let model = ExercisePhotoModel()
        await model.load(bench, service: service(media: nil, good: []), maxPixelSize: nil)
        #expect(model.frames.isEmpty)
        await model.load(nil, service: service(media: photos, good: [start, end]), maxPixelSize: nil)
        #expect(model.frames.isEmpty, "no exercise (custom or missing) -> illustration")
    }

    @Test func failedDownloadKeepsThePlaceholder() async {
        let model = ExercisePhotoModel()
        await model.load(bench, service: service(media: photos, good: []), maxPixelSize: nil)
        #expect(model.frames.isEmpty)
    }

    @Test func aFailedEndFrameStillShowsTheStart() async {
        let model = ExercisePhotoModel()
        await model.load(bench, service: service(media: photos, good: [start]), maxPixelSize: nil)
        #expect(model.frames.map(\.position) == [.start])
    }

    @Test func switchingToAnExerciseWithoutPhotosClearsOldFrames() async {
        let model = ExercisePhotoModel()
        await model.load(bench, service: service(media: photos, good: [start, end]), maxPixelSize: nil)
        await model.load(bench, service: service(media: nil, good: []), maxPixelSize: nil)
        #expect(model.frames.isEmpty)
    }

    @Test func aCachedStartShowsWhileTheEndIsStillDownloading() async throws {
        let model = ExercisePhotoModel()
        let service = ExerciseMediaService(provider: FixedProvider(media: photos), loader: SlowEndLoader(end: end))
        let loading = Task { await model.load(bench, service: service, maxPixelSize: nil) }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.frames.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.frames.map(\.position) == [.start], "start shows without waiting for the end photo")
        loading.cancel()
        await loading.value
    }

    @Test func reloadingTheSameExerciseNeverShrinksFramesMidway() async throws {
        let model = ExercisePhotoModel()
        await model.load(bench, service: service(media: photos, good: [start, end]), maxPixelSize: nil)
        #expect(model.frames.count == 2)
        let slow = ExerciseMediaService(provider: FixedProvider(media: photos), loader: SlowEndLoader(end: end))
        let reloading = Task { await model.load(bench, service: slow, maxPixelSize: nil) }
        try await Task.sleep(for: .milliseconds(300)) // the start frame has arrived, the end one hasn't
        #expect(model.frames.count == 2, "the shown pair stays until the reload finishes")
        reloading.cancel()
        await reloading.value
        #expect(model.frames.count == 2)
    }

    @Test func visibleIndexIsClampedToTheFrames() {
        #expect(ExercisePhotoModel.visibleIndex(shown: 1, count: 1) == 0)
        #expect(ExercisePhotoModel.visibleIndex(shown: 1, count: 2) == 1)
        #expect(ExercisePhotoModel.visibleIndex(shown: 5, count: 0) == 0)
    }

    @Test func positionsHaveSpokenLabels() {
        #expect(ExercisePhotoModel.Position.start.label == "Start position")
        #expect(ExercisePhotoModel.Position.end.label == "End position")
    }

    @Test func uiTestingServiceIsHermetic() async throws {
        let none = ExerciseMediaService.make(options: LaunchOptions(arguments: ["-uiTesting"]))
        #expect(none.provider.media(for: bench) == nil, "UI tests show the illustration unless asked for photos")
        #expect(!none.autoCrossfade, "UI tests flip photos only on tap, so assertions are deterministic")
        #expect(ExerciseMediaService.make(options: LaunchOptions(arguments: [])).autoCrossfade)

        let stub = ExerciseMediaService.make(options: LaunchOptions(arguments: ["-uiTesting", "-uiTestingPhotos"]))
        let media = try #require(stub.provider.media(for: bench))
        #expect(media.photos.count == 2)
        let image = try await stub.loader.image(for: media.photos[0], maxPixelSize: nil)
        #expect(image.size.width > 0, "rendered locally, no network")
    }

    @Test func realServicePrefersOwnMediaThenFreeExerciseDB() throws {
        let service = ExerciseMediaService.make(options: LaunchOptions(arguments: []))
        #expect(service.provider.media(for: bench)?.source == .freeExerciseDB)
        let own = Exercise(id: "0025", name: "x", bodyPart: "chest", equipment: "barbell", target: "pectorals",
                           image: "https://media.example.com/0025.jpg")
        #expect(service.provider.media(for: own)?.source == .own)
    }
}
