import Foundation

/// Where the MET values come from (the 2024 Adult Compendium of Physical Activities), shown in the info sheet.
public struct METSource: Codable, Sendable, Equatable {
    public let title: String
    public let citation: String
    public let url: String
    public let retrieved: String
    public let terms: [String]

    public init(title: String, citation: String, url: String, retrieved: String, terms: [String]) {
        self.title = title
        self.citation = citation
        self.url = url
        self.retrieved = retrieved
        self.terms = terms
    }
}

/// One Compendium activity: its code, published MET value (never changed) and description.
public struct METActivity: Codable, Sendable, Equatable {
    public let code: String
    public let met: Double
    public let description: String
    public let heading: String

    public init(code: String, met: Double, description: String, heading: String) {
        self.code = code
        self.met = met
        self.description = description
        self.heading = heading
    }
}

/// The subset of Compendium activities the calorie estimate can pick (`met-values.json` in the app bundle).
public struct METTable: Codable, Sendable, Equatable {
    public let source: METSource
    public let activities: [METActivity]

    public init(source: METSource, activities: [METActivity]) {
        self.source = source
        self.activities = activities
    }

    public static func decode(_ data: Data) throws -> METTable {
        try JSONDecoder().decode(METTable.self, from: data)
    }

    public func activity(for code: String) -> METActivity? { activities.first { $0.code == code } }

    public func met(for code: String) -> Double? { activity(for: code)?.met }
}
