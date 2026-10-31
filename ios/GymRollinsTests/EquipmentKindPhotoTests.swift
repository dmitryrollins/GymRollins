import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Stock photos of equipment kinds: the manifest's `kinds`, the Storage URL, the hosted-then-bundled lookup, and
/// the bundled files themselves.
@Suite struct EquipmentKindPhotoTests {
    private let supabase = URL(string: "https://abc.supabase.co")!
    private let bundledDumbbells = URL(fileURLWithPath: "/App.app/OwnPhotos/kind-dumbbells.jpg")

    private func manifest(_ json: String) throws -> StoragePhotoManifest {
        try StoragePhotoManifest(data: Data(json.utf8))
    }

    private func photos(kinds: [String: String]? = nil, bundled: Bool = true) -> EquipmentKindPhotos {
        let storage = kinds.map {
            SupabaseStoragePhotoProvider(supabaseURL: supabase, manifest: StoragePhotoManifest(photos: [:], kinds: $0))
        }
        let url = bundledDumbbells
        return EquipmentKindPhotos(storage: storage) { id in bundled && id == "dumbbells" ? url : nil }
    }

    // MARK: Manifest

    @Test func manifestParsesKinds() throws {
        let parsed = try manifest(#"{"version":1,"photos":{},"kinds":{"dumbbells":"0a1b2c","ab-wheel":"ff"}}"#)
        #expect(parsed.kinds == ["dumbbells": "0a1b2c", "ab-wheel": "ff"])
        #expect(StoragePhotoManifest.supportedVersion == 1)
    }

    @Test func manifestWithoutKindsHasNone() throws {
        #expect(try manifest(#"{"version":1,"photos":{"0453":2}}"#).kinds.isEmpty)
    }

    @Test func manifestDropsMalformedKindIdsNotTheManifest() throws {
        let long = String(repeating: "a", count: 41)
        let parsed = try manifest(#"{"version":1,"photos":{"0453":2},"kinds":{"dumbbells":"ab","Bad":"ab","":"ab","a_b":"ab","\#(long)":"ab","../x":"ab"}}"#)
        #expect(parsed.kinds == ["dumbbells": "ab"])
        #expect(parsed.photos == ["0453": 2])
    }

    @Test func manifestDropsMalformedKindRevs() throws {
        let long = String(repeating: "a", count: 65)
        let parsed = try manifest(#"{"version":1,"photos":{},"kinds":{"good":"ab12","nothex":"zz","empty":"","long":"\#(long)","bad":"a b"}}"#)
        #expect(parsed.kinds == ["good": "ab12"])
    }

    // MARK: Storage URL

    @Test func storageAnswersTheHostedKindPhotoWithItsRev() throws {
        let storage = SupabaseStoragePhotoProvider(
            supabaseURL: supabase, manifest: StoragePhotoManifest(photos: [:], kinds: ["dumbbells": "ab12"]))
        let url = try #require(storage.kindPhotoURL(kindId: "dumbbells"))
        #expect(url.absoluteString == "https://abc.supabase.co/storage/v1/object/public/exercise-photos/kind-dumbbells.jpg?v=ab12")
        #expect(storage.kindPhotoURL(kindId: "kettlebells") == nil, "the manifest doesn't list it")
        #expect(storage.kindPhotoURL(kindId: "../dumbbells") == nil)
        #expect(SupabaseStoragePhotoProvider(supabaseURL: supabase).kindPhotoURL(kindId: "dumbbells") == nil,
                "no manifest yet")
    }

    // MARK: Lookup order

    @Test func hostedComesBeforeBundled() throws {
        let candidates = photos(kinds: ["dumbbells": "ab12"]).candidates(kindId: "dumbbells")
        #expect(candidates.count == 2)
        #expect(candidates.first?.host() == "abc.supabase.co")
        #expect(candidates.first?.query() == "v=ab12")
        #expect(candidates.last == bundledDumbbells)
    }

    @Test func bundledOnlyWhenNothingIsHosted() {
        #expect(photos(kinds: nil).candidates(kindId: "dumbbells") == [bundledDumbbells])
        #expect(photos(kinds: [:]).candidates(kindId: "dumbbells") == [bundledDumbbells])
        #expect(photos(kinds: ["kettlebells": "ab"]).candidates(kindId: "dumbbells") == [bundledDumbbells])
    }

    @Test func hostedOnlyWhenNotBundled() {
        let candidates = photos(kinds: ["dumbbells": "ab12"], bundled: false).candidates(kindId: "dumbbells")
        #expect(candidates.count == 1)
        #expect(candidates.first?.host() == "abc.supabase.co")
    }

    @Test func noPhotoAtAll() {
        #expect(photos(kinds: ["dumbbells": "ab12"]).candidates(kindId: "skierg").isEmpty)
        #expect(EquipmentKindPhotos.none.candidates(kindId: "dumbbells").isEmpty)
        #expect(photos().candidates(kindId: "../dumbbells").isEmpty, "a malformed id never reaches the bundle lookup")
    }

    // MARK: The bundled files

    @Test func everyBundledKindPhotoNamesARealKindAndOnlyThreeKindsHaveNone() throws {
        let files = Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: BundledOwnPhotoProvider.folder) ?? []
        let bundledIds = Set(files.map(\.lastPathComponent).filter { $0.hasPrefix("kind-") }
            .map { String($0.dropFirst("kind-".count).dropLast(".jpg".count)) })
        let kindIds = Set(try GymEquipmentCatalog.load().kinds.map(\.id))
        #expect(bundledIds.subtracting(kindIds).isEmpty, "a renamed kind lost its photo: \(bundledIds.subtracting(kindIds))")
        #expect(kindIds.subtracting(bundledIds) == ["lateral-raise-machine", "skierg", "upper-body-ergometer"])
        let lookup = EquipmentKindPhotos.bundled(.main)
        #expect(bundledIds.allSatisfy { lookup($0) != nil })
    }

    @Test func ownPhotoProviderIgnoresKindPhotos() {
        let root = URL(fileURLWithPath: "/App.app", isDirectory: true)
        let provider = BundledOwnPhotoProvider(files: [
            root.appendingPathComponent("kind-dumbbells.jpg"), root.appendingPathComponent("kind-0453-0.jpg"),
        ])
        let exercise = Exercise(id: "0453", name: "x", bodyPart: "upper arms", equipment: "ez barbell", target: "triceps")
        #expect(provider.media(for: exercise) == nil)
    }
}

/// A stock photo is display only: it never becomes the listing's photo.
@MainActor
@Suite struct StockPhotoIsDisplayOnlyTests {
    @Test func aStockPhotoLeavesTheListingWithoutAPhoto() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home", ["lat-pulldown": .stack(maxKg: 90, stepKg: nil)])
        let media = ExerciseMediaService.make(options: LaunchOptions(arguments: ["-uiTesting", "-uiTestingPhotos"]))
        #expect(!media.kindPhotos.candidates(kindId: "lat-pulldown").isEmpty, "the listing does have a stock photo")
        #expect(media.kindPhotos.candidates(kindId: "skierg").isEmpty, "-uiTestingPhotos leaves skierg without one")
        let listing = try #require(try rig.env.gyms.listings(gymId: gym.id).first)
        #expect(listing.photoFile == nil)
        let flow = AddEquipmentModel(
            gym: gym, catalog: rig.env.gymCatalog, unit: .lb,
            ports: .init(listings: { _ in [listing] }, catalogueItems: { _ in [] }, savePhoto: { _ in "x" },
                         deletePhoto: { _ in }, addListing: { _ in listing }, attachPhoto: { _, _ in listing }))
        flow.photoProcessed(ProcessedGymPhoto(jpeg: Data("p".utf8), thumbnail: Data("t".utf8)))
        #expect(!flow.keepsItsPhoto(listing), "a stock photo isn't the listing's own, so a new one can still be saved")
        #expect(try rig.env.gyms.listings(gymId: gym.id).allSatisfy { $0.photoFile == nil })
    }

    @Test func plainUITestingShowsNoStockPhotos() {
        let media = ExerciseMediaService.make(options: LaunchOptions(arguments: ["-uiTesting"]))
        #expect(media.kindPhotos.candidates(kindId: "lat-pulldown").isEmpty)
    }
}
