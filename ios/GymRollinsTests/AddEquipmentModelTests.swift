import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// The add-equipment flow's steps and Save, over a real in-memory store and photo folder.
@MainActor
@Suite struct AddEquipmentModelTests {
    private let jpeg = ProcessedGymPhoto(jpeg: Data("p".utf8), thumbnail: Data("t".utf8))

    private func model(_ rig: GymTestRig, gym: Gym, unit: WeightUnit = .lb) -> AddEquipmentModel {
        let repo = rig.env.gyms, photos = rig.photos
        return AddEquipmentModel(
            gym: gym, catalog: rig.env.gymCatalog, unit: unit,
            ports: .init(
                listings: { kindId in try repo.listings(gymId: gym.id).filter { $0.item.kindId == kindId } },
                catalogueItems: { try repo.catalogueItems(kindId: $0) },
                savePhoto: { try photos.save($0) },
                deletePhoto: { try? photos.delete($0) },
                addListing: { try repo.addListing($0) },
                attachPhoto: { processed, id in
                    let file = try photos.save(processed)
                    _ = try repo.setPhoto(id, file: file)
                    return try #require(try repo.listing(id))
                }))
    }

    @Test func skippingPhotoGoesToKind() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym())
        #expect(flow.step == .photo)
        flow.skipPhoto()
        #expect(flow.step == .kind)
        #expect(!flow.hasPhoto)
    }

    /// A library photo can still be processing when the user taps Skip; its late result must not drag them back.
    @Test func aPhotoThatFinishesAfterSkipIsDiscarded() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym())
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        flow.photoProcessed(jpeg)
        #expect(flow.step == .details, "the late photo doesn't move the flow")
        #expect(flow.kind?.id == "lat-pulldown")
        #expect(!flow.hasPhoto)
        flow.photoFailed("late failure")
        #expect(flow.photoError == nil, "a late failure isn't shown either")
        flow.save()
        #expect(rig.photoCount() == 0, "nothing is saved for a photo the user skipped")
    }

    @Test func aProcessedPhotoGoesToKindAndWritesNothingYet() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym())
        flow.photoProcessed(jpeg)
        #expect(flow.step == .kind)
        #expect(flow.hasPhoto)
        #expect(rig.photoCount() == 0, "cancelling now leaves no file")
    }

    @Test func kindWithNoListingSkipsTheDuplicateStep() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym("Empty"))
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        #expect(flow.step == .details)
        #expect(flow.kind?.id == "lat-pulldown")
        flow.back()
        #expect(flow.step == .kind)
    }

    @Test func kindAlreadyListedShowsTheDuplicateStep() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym("Home", ["lat-pulldown": .stack(maxKg: 90, stepKg: nil)]))
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        #expect(flow.step == .duplicate)
        #expect(flow.existing.count == 1)
        flow.different()
        flow.back()
        #expect(flow.step == .duplicate, "Back from details returns to the duplicate step when it was shown")
    }

    /// "Yes, that's it" creates no listing. A listing with no photo gets the one just taken: the user took it for this.
    @Test func yesThatsItCreatesNothing() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home", ["lat-pulldown": .stack(maxKg: 90, stepKg: nil)])
        let flow = model(rig, gym: gym)
        flow.photoProcessed(jpeg)
        flow.chooseKind("lat-pulldown")
        let existing = try #require(flow.existing.first)
        #expect(existing.photoFile == nil)
        #expect(!flow.keepsItsPhoto(existing))
        flow.sameAsExisting(existing)
        guard case let .confirmed(confirmed)? = flow.outcome else { Issue.record("not confirmed"); return }
        #expect(confirmed.id == existing.id)
        #expect(confirmed.photoFile != nil)
        #expect(try rig.env.gyms.listings(gymId: gym.id).count == 1)
        #expect(try rig.env.gyms.listing(existing.id)?.photoFile == confirmed.photoFile)
        #expect(rig.photoCount() == 2, "the photo and its thumbnail")
    }

    @Test func yesThatsItKeepsTheListingsOwnPhoto() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home")
        let file = try rig.photos.save(jpeg)
        try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: "lat-pulldown",
                                               loads: .stack(maxKg: 90, stepKg: nil), photoFile: file))
        let flow = model(rig, gym: gym)
        flow.photoProcessed(jpeg)
        flow.chooseKind("lat-pulldown")
        let existing = try #require(flow.existing.first)
        #expect(flow.keepsItsPhoto(existing), "step 3 says: Keeps its photo. Your new one isn't saved.")
        flow.sameAsExisting(existing)
        #expect(flow.outcome == .confirmed(existing))
        #expect(try rig.env.gyms.listing(existing.id)?.photoFile == file)
        #expect(rig.photoCount() == 2, "no second photo was written")
    }

    @Test func yesThatsItWithoutAPhotoChangesNothing() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home", ["lat-pulldown": .stack(maxKg: 90, stepKg: nil)])
        let flow = model(rig, gym: gym)
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        let existing = try #require(flow.existing.first)
        #expect(!flow.keepsItsPhoto(existing))
        flow.sameAsExisting(existing)
        #expect(flow.outcome == .confirmed(existing))
        #expect(rig.photoCount() == 0)
    }

    @Test func pickingACatalogueItemCarriesBrandAndModel() throws {
        let rig = try GymTestRig.make()
        let other = try rig.gym("Other")
        try rig.env.gyms.addListing(NewListing(gymId: other.id, kindId: "lat-pulldown", brand: "Life Fitness",
                                               model: "Pulldown", loads: .stack(maxKg: 100, stepKg: nil)))
        let gym = try rig.gym("Home", ["lat-pulldown": .stack(maxKg: 90, stepKg: nil)])
        let flow = model(rig, gym: gym)
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        let known = try #require(flow.known.first)
        #expect(known.gymCount == 1)
        flow.chooseCatalogueItem(known)
        #expect(flow.step == .details)
        #expect(flow.brand == "Life Fitness" && flow.modelName == "Pulldown")
        #expect(!flow.showsBrandFields)
        flow.save()
        guard case let .created(listing)? = flow.outcome else { Issue.record("no listing created"); return }
        #expect(listing.item.brand == "Life Fitness" && listing.item.model == "Pulldown")
        #expect(listing.item.id == known.item.id, "the same catalogue item")
    }

    @Test func differentOneGoesToDetailsWithBrandFields() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym("Home", ["lat-pulldown": .stack(maxKg: 90, stepKg: nil)]))
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        flow.different()
        #expect(flow.step == .details)
        #expect(flow.showsBrandFields)
        #expect(flow.brand.isEmpty && flow.modelName.isEmpty)
    }

    @Test func genericGoesToDetailsWithoutBrandFields() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym("Home", ["lat-pulldown": .stack(maxKg: 90, stepKg: nil)]))
        flow.skipPhoto()
        flow.chooseKind("lat-pulldown")
        flow.chooseGeneric()
        #expect(flow.step == .details)
        #expect(!flow.showsBrandFields)
    }

    @Test func stackDefaultsAndStepsInTheUserUnitAndSavesInKg() throws {
        let rig = try GymTestRig.make()
        let lb = model(rig, gym: try rig.gym("A"), unit: .lb)
        lb.skipPhoto()
        lb.chooseKind("lat-pulldown")
        #expect(lb.editing?.stackText == "250 lb (113.4 kg)")
        lb.stepStack(1)
        #expect(lb.editing?.stackText == "255 lb (115.7 kg)")
        lb.save()
        guard case let .created(listing)? = lb.outcome, case let .stack(kg, _) = listing.loads else {
            Issue.record("no stack listing"); return
        }
        #expect(abs(kg - UnitConverter.toKg(255, from: .lb)) < 0.001)

        let kgModel = model(rig, gym: try rig.gym("B"), unit: .kg)
        kgModel.skipPhoto()
        kgModel.chooseKind("lat-pulldown")
        #expect(kgModel.loads == .stack(maxKg: 110, stepKg: nil))
        kgModel.stepStack(-1)
        #expect(kgModel.loads == .stack(maxKg: 107.5, stepKg: nil))
    }

    @Test func plateLoadedAndBodyweightHaveNoLoadInput() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym("Home"))
        flow.skipPhoto()
        flow.chooseKind("barbell")
        #expect(flow.loads == .plates)
        #expect(flow.editing?.hasInput == false)
        #expect(flow.canSave)
        let bench = model(rig, gym: try rig.gym("Other"))
        bench.skipPhoto()
        bench.chooseKind("flat-bench")
        #expect(bench.loads == ListingLoads.none)
        #expect(bench.canSave)
    }

    @Test func fixedSetRequiresAWeight() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym("Home"))
        flow.skipPhoto()
        flow.chooseKind("kettlebells")
        #expect(!flow.canSave)
        flow.toggleWeight(20)
        #expect(flow.canSave)
        flow.toggleWeight(20)
        #expect(!flow.canSave)
    }

    @Test func fixedChipsMatchTheKind() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym("Home"), unit: .lb)
        flow.skipPhoto()
        flow.chooseKind("kettlebells")
        let options = try #require(flow.editing?.options)
        #expect(options.contains { $0.label == "44 lb (20 kg)" })
        #expect(options.contains { $0.label == "53 lb (24 kg)" })
        flow.toggleWeight(try #require(options.first { $0.label == "44 lb (20 kg)" }).kg)
        flow.toggleWeight(try #require(options.first { $0.label == "53 lb (24 kg)" }).kg)
        #expect(flow.loads == .fixed(kg: [UnitConverter.toKg(44, from: .lb), UnitConverter.toKg(53, from: .lb)]),
                "an lb user's chips store the pounds they read")
        flow.toggleAllWeights()
        #expect(flow.loads == .fixed(kg: options.map(\.kg)))

        let dumbbells = model(rig, gym: try rig.gym("Other"), unit: .kg)
        dumbbells.skipPhoto()
        dumbbells.chooseKind("dumbbells")
        #expect(dumbbells.editing?.options.first?.label == "2 kg")
        #expect(dumbbells.editing?.options.last?.label == "50 kg")
    }

    @Test func saveStoresPhoneOnly() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym("Home")
        let withPhoto = model(rig, gym: gym)
        withPhoto.photoProcessed(jpeg)
        withPhoto.chooseKind("flat-bench")
        withPhoto.note = "  by the window  "
        withPhoto.save()
        guard case let .created(listing)? = withPhoto.outcome else { Issue.record("no listing"); return }
        #expect(listing.visibility == .device)
        #expect(listing.notes == "by the window")
        let file = try #require(listing.photoFile)
        #expect(FileManager.default.fileExists(atPath: rig.photos.url(file).path()))

        let without = model(rig, gym: gym)
        without.skipPhoto()
        without.chooseKind("pull-up-bar")
        without.save()
        guard case let .created(plain)? = without.outcome else { Issue.record("no listing"); return }
        #expect(plain.visibility == .device)
        #expect(plain.photoFile == nil)
        #expect(rig.photoCount() == 2, "one photo and its thumbnail")
    }

    @Test func processorFailureOffersRetryOrSkip() throws {
        let rig = try GymTestRig.make()
        let flow = model(rig, gym: try rig.gym())
        flow.photoFailed(GymPhotoError.faceDetectionFailed.userMessage)
        #expect(flow.step == .photo)
        #expect(flow.photoError == "We couldn't check this photo for faces, so it wasn't saved. Try again or skip the photo.")
        flow.photoFailed(GymPhotoError.tooBig.userMessage)
        #expect(flow.photoError == "This photo couldn't be made small enough. Try another one.")
        flow.photoProcessed(jpeg)
        #expect(flow.photoError == nil, "a retry that works clears the message")
        #expect(flow.step == .kind)

        let skipping = model(rig, gym: try rig.gym("Other"))
        skipping.photoFailed(GymPhotoError.faceDetectionFailed.userMessage)
        skipping.skipPhoto()
        #expect(skipping.step == .kind)
        #expect(skipping.photoError == nil)
    }

    @Test func failedSaveDeletesTheJustSavedPhoto() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym()
        let flow = model(rig, gym: gym)
        flow.photoProcessed(jpeg)
        flow.chooseKind("flat-bench")
        flow.different()
        flow.brand = String(repeating: "x", count: 61)
        flow.save()
        #expect(flow.outcome == nil)
        #expect(flow.step == .details)
        #expect(flow.errorText == "The brand can be up to 60 characters.")
        #expect(rig.photoCount() == 0, "no orphan file")
        #expect(try rig.env.gyms.listings(gymId: gym.id).isEmpty)
        flow.brand = "Rogue"
        flow.save()
        #expect(flow.errorText == nil)
        #expect(rig.photoCount() == 2)
    }

    @Test func aFailingPhotoSaveKeepsTheUserOnDetails() throws {
        let rig = try GymTestRig.make()
        let gym = try rig.gym()
        let flow = AddEquipmentModel(
            gym: gym, catalog: rig.env.gymCatalog, unit: .lb,
            ports: .init(listings: { _ in [] }, catalogueItems: { _ in [] },
                         savePhoto: { _ in throw CocoaError(.fileWriteOutOfSpace) },
                         deletePhoto: { _ in }, addListing: { try rig.env.gyms.addListing($0) },
                         attachPhoto: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        flow.photoProcessed(jpeg)
        flow.chooseKind("flat-bench")
        flow.save()
        #expect(flow.outcome == nil)
        #expect(flow.errorText == "Couldn't save the photo. Try again or save without it.")
        #expect(flow.photoSaveFailed, "the details step offers Save without the photo")
        #expect(try rig.env.gyms.listings(gymId: gym.id).isEmpty)

        flow.saveWithoutPhoto()
        #expect(!flow.hasPhoto)
        #expect(!flow.photoSaveFailed)
        guard case let .created(listing)? = flow.outcome else { Issue.record("not saved without the photo"); return }
        #expect(listing.photoFile == nil)
        #expect(try rig.env.gyms.listings(gymId: gym.id).count == 1)
    }

    @Test func kindSectionsLeadWithTheCommonKindsInOrder() throws {
        let rig = try GymTestRig.make()
        let sections = AddEquipmentModel.kindSections(rig.env.gymCatalog)
        #expect(sections[0].title == "Machines")
        #expect(sections[0].kinds.prefix(6).map(\.id) ==
                ["lat-pulldown", "leg-press", "chest-press-machine", "pec-deck", "seated-row-machine", "leg-curl"])
        #expect(sections[1].kinds.prefix(6).map(\.id) ==
                ["dumbbells", "kettlebells", "barbell", "adjustable-bench", "power-rack", "cable-station"])
        let all = sections.flatMap(\.kinds).map(\.id)
        #expect(all.count == rig.env.gymCatalog.kinds.count, "all 46 kinds are reachable")
        #expect(Set(all).count == all.count, "none twice")
    }
}
