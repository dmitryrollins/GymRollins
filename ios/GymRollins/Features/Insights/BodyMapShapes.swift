import GymCore
import os
import SwiftUI

enum BodySide: String, CaseIterable, Identifiable {
    case front, back
    var id: String { rawValue }
    var title: String { self == .front ? "Front" : "Back" }
}

/// The body figure: `Resources/body-map.json`, extracted by `scripts/build-body-map.mjs` from
/// HichamELBSI/react-native-body-highlighter (MIT License, pinned commit; docs/licenses/body-highlighter.md). Paths
/// are parsed once, in the source's view-box coordinates.
struct BodyMapData: Sendable {
    struct Region: Sendable {
        let id: String
        let side: BodySide
        let path: Path
        /// nil = part of the neutral silhouette (head, hands, knees…).
        let group: MuscleGroup?
    }

    let regions: [Region]
    let viewBoxes: [BodySide: CGRect]
    /// The body's edge per side (without head, hands and feet, which are neutral regions).
    let outlines: [BodySide: Path]

    /// Width of the silhouette's rim around the muscles, in source units.
    static let rimWidth: CGFloat = 14

    private struct File: Decodable {
        struct Row: Decodable { let id, view, path: String }
        let viewBoxes: [String: [Double]]
        let outlines: [String: String]
        let regions: [Row]
    }

    static let shared: BodyMapData = {
        do {
            guard let url = Bundle.main.url(forResource: "body-map", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try load(Data(contentsOf: url))
        } catch {
            Logger(subsystem: "com.rollins.gymrollins", category: "insights")
                .error("Body map failed to load: \(error.localizedDescription, privacy: .public)")
            return BodyMapData(regions: [], viewBoxes: [:], outlines: [:])
        }
    }()

    static func load(_ data: Data) throws -> BodyMapData {
        let file = try JSONDecoder().decode(File.self, from: data)
        var boxes: [BodySide: CGRect] = [:]
        var outlines: [BodySide: Path] = [:]
        for side in BodySide.allCases {
            guard let b = file.viewBoxes[side.rawValue], b.count == 4,
                  let outline = file.outlines[side.rawValue].flatMap(SVGPath.parse) else {
                throw CocoaError(.coderInvalidValue)
            }
            boxes[side] = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
            outlines[side] = outline
        }
        let regions = try file.regions.map { row -> Region in
            guard let side = BodySide(rawValue: row.view), let path = SVGPath.parse(row.path) else {
                throw CocoaError(.coderInvalidValue)
            }
            return Region(id: row.id, side: side, path: path, group: BodyMapRegions.group(forRegion: row.id))
        }
        return BodyMapData(regions: regions, viewBoxes: boxes, outlines: outlines)
    }

    func viewBox(_ side: BodySide) -> CGRect { viewBoxes[side] ?? CGRect(x: 0, y: 0, width: 1, height: 2) }

    /// Width / height of a side's figure.
    func aspectRatio(_ side: BodySide) -> CGFloat {
        let box = viewBox(side)
        return box.height > 0 ? box.width / box.height : 0.5
    }

    /// Groups with at least one region on `side`, in body order.
    func groups(on side: BodySide) -> [MuscleGroup] {
        let present = Set(regions.filter { $0.side == side }.compactMap(\.group))
        return MuscleGroup.allCases.filter(present.contains)
    }

    /// Source units → points: `box` (default: the side's view box) scaled into `rect` (centred, aspect kept).
    private func transform(side: BodySide, box: CGRect?, in rect: CGRect) -> (CGAffineTransform, scale: CGFloat) {
        let box = box ?? viewBox(side)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(translationX: rect.minX + (rect.width - box.width * scale) / 2,
                                          y: rect.minY + (rect.height - box.height * scale) / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.minX, y: -box.minY)
        return (transform, scale)
    }

    /// The union of the matching regions, scaled into `rect` (`box`: a part of the figure to zoom into).
    func path(side: BodySide, box: CGRect? = nil, in rect: CGRect, where include: (Region) -> Bool) -> Path {
        let (transform, _) = transform(side: side, box: box, in: rect)
        var out = Path()
        for region in regions where region.side == side && include(region) {
            out.addPath(region.path, transform: transform)
        }
        return out
    }

    /// The whole body as one shape: the outline with a rim around it, plus the neutral regions, scaled into `rect`.
    func silhouette(side: BodySide, box: CGRect? = nil, in rect: CGRect) -> Path {
        let (transform, scale) = transform(side: side, box: box, in: rect)
        guard let outline = outlines[side]?.applying(transform) else { return Path() }
        let rim = outline.strokedPath(StrokeStyle(lineWidth: Self.rimWidth * scale, lineJoin: .round))
        let neutral = path(side: side, box: box, in: rect) { $0.group == nil }
        return Path(outline.cgPath.union(rim.cgPath).union(neutral.cgPath))
    }
}

/// Upstream region id → display muscle group ("biceps-left" and "biceps-right" share `.biceps`). Every region in
/// the bundled file must be in `groups` or `neutral` (BodyMapRegionsTests checks it).
enum BodyMapRegions {
    static let groups: [String: MuscleGroup] = [
        "chest": .chest, "deltoids": .shoulders, "trapezius": .traps,
        "upper-back": .upperBack, "lats": .lats, "lower-back": .lowerBack,
        "biceps": .biceps, "triceps": .triceps, "forearm": .forearms,
        "abs": .abs, "obliques": .abs,
        "gluteal": .glutes, "gluteus-medius": .abductors, "adductors": .adductors,
        "quadriceps": .quads, "hamstring": .hamstrings, "calves": .calves, "tibialis": .calves,
    ]

    /// Part of the silhouette, never coloured or tappable.
    static let neutral: Set<String> = ["head", "hair", "hands", "feet", "ankles", "knees", "neck"]

    /// "biceps-left" → "biceps".
    static func base(_ id: String) -> String {
        for suffix in ["-left", "-right"] where id.hasSuffix(suffix) { return String(id.dropLast(suffix.count)) }
        return id
    }

    static func group(forRegion id: String) -> MuscleGroup? { groups[base(id)] }

    static func isKnown(_ id: String) -> Bool { groups[base(id)] != nil || neutral.contains(base(id)) }
}

/// One muscle group's regions on one side of the figure.
struct MuscleRegionShape: Shape {
    let group: MuscleGroup
    let side: BodySide
    var box: CGRect?
    var data: BodyMapData = .shared
    func path(in rect: CGRect) -> Path { data.path(side: side, box: box, in: rect) { $0.group == group } }
}

/// The neutral body under the coloured muscles: outline, rim, head, hands and feet.
struct BodySilhouetteShape: Shape {
    let side: BodySide
    var box: CGRect?
    var data: BodyMapData = .shared
    func path(in rect: CGRect) -> Path { data.silhouette(side: side, box: box, in: rect) }
}
