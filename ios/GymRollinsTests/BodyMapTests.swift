import Foundation
import GymCore
import SwiftUI
import Testing
@testable import GymRollins

@Suite struct SVGPathTests {
    @Test func absoluteAndRelativeLinesWithImplicitRepeats() throws {
        let path = try #require(SVGPath.parse("M 1,1 L 3,1 3,3 Z m 10,0 2,0 0,2 z"))
        #expect(path.boundingRect == CGRect(x: 1, y: 1, width: 12, height: 2))
        #expect(path.contains(CGPoint(x: 2.8, y: 1.5)))
        #expect(path.contains(CGPoint(x: 12.8, y: 1.5)))
        #expect(!path.contains(CGPoint(x: 7, y: 1.5)))
    }

    @Test func horizontalVerticalAndExponents() throws {
        let path = try #require(SVGPath.parse("M0 0h10v1e1H0V0z"))
        #expect(path.boundingRect == CGRect(x: 0, y: 0, width: 10, height: 10))
        let rel = try #require(SVGPath.parse("m 5,5 h 2 v 2 h -2 z"))
        #expect(rel.boundingRect == CGRect(x: 5, y: 5, width: 2, height: 2))
    }

    @Test func numbersWithoutSeparators() throws {
        // "-6.8, -2.1" and "0.5.5" (= 0.5 then .5) as upstream data writes them.
        let path = try #require(SVGPath.parse("M10,10l-6.8, -2.1 0.5.5z"))
        #expect(abs(path.boundingRect.minX - 3.2) < 1e-4) // Path stores Float-precision points
        #expect(abs(path.boundingRect.minY - 7.9) < 1e-4)
    }

    @Test func curves() throws {
        let cubic = try #require(SVGPath.parse("M0,0 C 0,10 10,10 10,0 S 20,-10 20,0 Z"))
        #expect(cubic.boundingRect.maxX == 20)
        let quad = try #require(SVGPath.parse("M0,0 q 5,10 10,0 t 10,0 z"))
        #expect(quad.boundingRect.maxX == 20)
        #expect(quad.boundingRect.minY < 0) // the smooth segment reflects the control point below the axis
    }

    @Test func malformedDataIsRejected() {
        #expect(SVGPath.parse("L 1,1") == nil)
        #expect(SVGPath.parse("M 1") == nil)
        #expect(SVGPath.parse("M 1,1 A 1 1 0 0 1 2,2") == nil)
        #expect(SVGPath.parse("M 1,1 z 2,2") == nil)
    }
}

@Suite struct BodyMapTests {
    private let data = BodyMapData.shared

    @Test func bundledFileLoadsEveryRegionAndOutlineOnBothSides() {
        #expect(data.regions.count == 71)
        #expect(data.regions.filter { $0.side == .front }.count == 37)
        #expect(data.viewBox(.front) == CGRect(x: 34, y: 84, width: 661, height: 1280))
        #expect(data.viewBox(.back) == CGRect(x: 752, y: 84, width: 661, height: 1280))
        #expect(data.regions.allSatisfy { !$0.path.isEmpty })
        #expect(BodySide.allCases.allSatisfy { data.outlines[$0]?.isEmpty == false })
    }

    @Test func everyRegionIsMappedOrNeutral() {
        let unknown = data.regions.map(\.id).filter { !BodyMapRegions.isKnown($0) }
        #expect(unknown.isEmpty, "unmapped regions: \(unknown)")
        #expect(BodyMapRegions.group(forRegion: "biceps-left") == .biceps)
        #expect(BodyMapRegions.group(forRegion: "biceps-right") == .biceps)
        #expect(BodyMapRegions.group(forRegion: "upper-back-left") == .upperBack)
        #expect(BodyMapRegions.group(forRegion: "lats-right") == .lats)
        #expect(BodyMapRegions.group(forRegion: "gluteus-medius-left") == .abductors)
        #expect(BodyMapRegions.group(forRegion: "knees-left") == nil)
        #expect(BodyMapRegions.group(forRegion: "head") == nil)
    }

    @Test func everyGroupHasARegionAndTheMappingIsNotStale() {
        let drawn = Set(data.regions.compactMap(\.group))
        #expect(drawn == Set(MuscleGroup.allCases))
        let bases = Set(data.regions.map { BodyMapRegions.base($0.id) })
        #expect(Set(BodyMapRegions.groups.keys).subtracting(bases).isEmpty)
        #expect(BodyMapRegions.neutral.subtracting(bases).isEmpty)
        #expect(data.groups(on: .front).contains(.chest))
        #expect(data.groups(on: .back).contains(.lats))
    }

    @Test func pathsScaleIntoTheRectKeepingTheAspectRatio() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 186) // wider than 661:1280 → height-bound
        let figure = data.silhouette(side: .back, in: rect).boundingRect
        #expect(figure.minY >= -0.5 && figure.maxY <= 186.5)
        #expect(figure.minX >= 49 && figure.maxX <= 151) // centred: 661/1280 × 186 ≈ 96 pt wide
        #expect(abs(data.aspectRatio(.front) - 661.0 / 1280.0) < 1e-9)
    }

    @Test func silhouetteCoversTheHeadAndEveryMuscleSitsOnIt() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 366)
        for side in BodySide.allCases {
            let body = data.silhouette(side: side, in: rect)
            #expect(body.contains(CGPoint(x: 100, y: 20)), "\(side): head") // top centre of the figure
            for region in data.regions where region.side == side && region.group != nil {
                let muscle = data.path(side: side, in: rect) { $0.id == region.id && $0.side == side }.boundingRect
                #expect(body.contains(CGPoint(x: muscle.midX, y: muscle.midY)), "\(side) \(region.id) is off the body")
            }
        }
    }
}

@Suite struct MuscleBadgeLayoutTests {
    private func layout(_ primary: [MuscleGroup], _ secondary: [MuscleGroup] = []) -> MuscleBadgeLayout? {
        MuscleBadgeLayout(contributions: primary.map { MuscleContribution(group: $0, weight: 1, isPrimary: true) }
            + secondary.map { MuscleContribution(group: $0, weight: 0.5, isPrimary: false) })
    }

    @Test func noPrimaryMusclesMeansNoBadge() {
        #expect(layout([]) == nil)
        #expect(layout([], [.biceps]) == nil)
    }

    @Test func picksTheSideThatShowsTheTargetMuscles() throws {
        #expect(try #require(layout([.lats], [.biceps])).side == .back) // lat pulldown
        #expect(try #require(layout([.triceps])).side == .back)
        #expect(try #require(layout([.chest], [.triceps, .shoulders])).side == .front)
        #expect(try #require(layout([.shoulders])).side == .front)
        #expect(try #require(layout([.quads, .hamstrings, .glutes])).side == .back) // 2 of 3 from behind
        #expect(try #require(layout([.biceps, .triceps])).side == .front) // a tie stays on the front
    }

    @Test func zoomsToTheUpperOrLowerBodyWhenAllTargetsSitThere() throws {
        #expect(try #require(layout([.chest], [.calves])).zoom == .upper) // secondary groups don't widen the zoom
        #expect(try #require(layout([.quads, .glutes])).zoom == .lower)
        #expect(try #require(layout([.forearms])).zoom == .whole)
        #expect(try #require(layout([.lowerBack, .hamstrings])).zoom == .whole)
        #expect(try #require(layout([.quads])).box(in: .shared)?.width == 660)
        #expect(try #require(layout([.forearms])).box(in: .shared) == nil)
    }

    @Test func primaryGroupsAreNotAlsoSecondary() throws {
        let l = try #require(layout([.chest], [.chest, .triceps]))
        #expect(l.primary == [.chest])
        #expect(l.secondary == [.triceps])
    }

    @Test func upperZoomKeepsEveryUpperTargetInFrame() throws {
        let data = BodyMapData.shared
        for group in MuscleBadgeLayout.upperGroups {
            let l = try #require(layout([group]))
            let box = try #require(l.box(in: data))
            let muscle = data.path(side: l.side, in: data.viewBox(l.side)) { $0.group == group }.boundingRect
            #expect(box.intersects(muscle), "\(group) is outside the \(l.side) upper crop")
        }
    }
}

/// The paths are built once in source units and only scaled afterwards; this checks them against the computation
/// they replace (transform first, then stroke the rim at the scaled width and union), at badge, card and map sizes.
@Suite struct BodyMapCachedPathTests {
    private let data = BodyMapData.shared

    /// The previous per-call transform: `box` scaled into `rect`, centred, aspect kept.
    private func transform(side: BodySide, box: CGRect?, in rect: CGRect) -> (CGAffineTransform, scale: CGFloat) {
        let box = box ?? data.viewBox(side)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(translationX: rect.minX + (rect.width - box.width * scale) / 2,
                                          y: rect.minY + (rect.height - box.height * scale) / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.minX, y: -box.minY)
        return (transform, scale)
    }

    private func uncachedSilhouette(side: BodySide, box: CGRect?, in rect: CGRect) throws -> Path {
        let (transform, scale) = transform(side: side, box: box, in: rect)
        let outline = try #require(data.outlines[side]).applying(transform)
        let rim = outline.strokedPath(StrokeStyle(lineWidth: BodyMapData.rimWidth * scale, lineJoin: .round))
        var neutral = Path()
        for region in data.regions where region.side == side && region.group == nil {
            neutral.addPath(region.path, transform: transform)
        }
        return Path(outline.cgPath.union(rim.cgPath).union(neutral.cgPath))
    }

    private func uncachedGroup(_ group: MuscleGroup, side: BodySide, box: CGRect?, in rect: CGRect) -> Path {
        let (transform, _) = transform(side: side, box: box, in: rect)
        var out = Path()
        for region in data.regions where region.side == side && region.group == group {
            out.addPath(region.path, transform: transform)
        }
        return out
    }

    /// Badge (whole figure and zoomed), the recovery card's figure, and a large offset map.
    private var cases: [(side: BodySide, box: CGRect?, rect: CGRect)] {
        BodySide.allCases.flatMap { side -> [(side: BodySide, box: CGRect?, rect: CGRect)] in
            let midX = data.viewBox(side).midX
            let upper = CGRect(x: midX - 240, y: 215, width: 480, height: 480)
            let lower = CGRect(x: midX - 330, y: 690, width: 660, height: 660)
            return [(side, nil, CGRect(x: 0, y: 0, width: 27.5, height: 27.5)),
                    (side, upper, CGRect(x: 0, y: 0, width: 31.2, height: 31.2)),
                    (side, lower, CGRect(x: 0, y: 0, width: 31.2, height: 31.2)),
                    (side, nil, CGRect(x: 0, y: 0, width: 104 * data.aspectRatio(side), height: 104)),
                    (side, nil, CGRect(x: 12, y: 30, width: 320, height: 560))]
        }
    }

    /// Same bounds (within a hundredth of the rect), and drawn the same on a 3x screen: every pixel's coverage within
    /// half of full, i.e. no edge moves by half a pixel. (The rim is now stroked at full size and then scaled, so an
    /// anti-aliased edge pixel can change by a few levels; at badge size the uncached stroke was slightly coarser.)
    private func expectSame(_ cached: Path, _ reference: Path, in rect: CGRect, _ label: String) {
        let tolerance = max(rect.width, rect.height) / 100
        let a = cached.boundingRect, b = reference.boundingRect
        #expect(abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
                && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance, "\(label): \(a) vs \(b)")
        let drawn = coverage(cached, in: rect), expected = coverage(reference, in: rect)
        #expect(drawn.contains { $0 > 0 } == expected.contains { $0 > 0 }, "\(label): drawn in one only")
        let worst = zip(drawn, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst < 128, "\(label): a pixel differs by \(worst)/255")
    }

    /// The path filled in white on black at 3x, one byte per pixel.
    private func coverage(_ path: Path, in rect: CGRect) -> [UInt8] {
        let scale: CGFloat = 3
        let width = Int((rect.maxX * scale).rounded(.up)), height = Int((rect.maxY * scale).rounded(.up))
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            context.addPath(path.cgPath)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
        }
        return pixels
    }

    @Test func silhouetteMatchesTheUncachedComputation() throws {
        for c in cases {
            let reference = try uncachedSilhouette(side: c.side, box: c.box, in: c.rect)
            expectSame(data.silhouette(side: c.side, box: c.box, in: c.rect), reference, in: c.rect,
                       "\(c.side) silhouette in \(c.rect)")
        }
    }

    @Test func everyGroupMatchesTheUncachedComputation() {
        for c in cases {
            for group in data.groups(on: c.side) {
                let reference = uncachedGroup(group, side: c.side, box: c.box, in: c.rect)
                let cached = data.path(group: group, side: c.side, box: c.box, in: c.rect)
                expectSame(cached, reference, in: c.rect, "\(c.side) \(group) in \(c.rect)")
                #expect(cached.boundingRect == reference.boundingRect || abs(cached.boundingRect.width
                    - reference.boundingRect.width) < 1e-3, "\(c.side) \(group): regions are only scaled")
            }
        }
    }

    @Test func shapesDrawTheCachedPaths() {
        let rect = CGRect(x: 0, y: 0, width: 31.2, height: 31.2)
        let box = CGRect(x: data.viewBox(.back).midX - 240, y: 215, width: 480, height: 480)
        #expect(MuscleRegionShape(group: .lats, side: .back, box: box).path(in: rect)
                == data.path(group: .lats, side: .back, box: box, in: rect))
        #expect(BodySilhouetteShape(side: .back, box: box).path(in: rect)
                == data.silhouette(side: .back, box: box, in: rect))
    }
}
