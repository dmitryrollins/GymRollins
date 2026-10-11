import Foundation
import GymCore
import GymData

/// `public.proposals` — plan changes suggested by Claude, applied on the device.
public struct ProposalDTO: Codable, Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let source: String
    public let summary: String
    public let changes: [PlanChange]
    public let status: String
    public let appliedChangeIds: [String]
    public let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, source, summary, changes, status
        case createdAt = "created_at", appliedChangeIds = "applied_change_ids", resolvedAt = "resolved_at"
    }

    public init(id: UUID, createdAt: Date, source: String = "claude", summary: String, changes: [PlanChange],
                status: String = "pending", appliedChangeIds: [String] = [], resolvedAt: Date? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.summary = summary
        self.changes = changes
        self.status = status
        self.appliedChangeIds = appliedChangeIds
        self.resolvedAt = resolvedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  createdAt: try c.decode(Date.self, forKey: .createdAt),
                  source: try c.decodeIfPresent(String.self, forKey: .source) ?? "claude",
                  summary: try c.decode(String.self, forKey: .summary),
                  changes: try c.decode([PlanChange].self, forKey: .changes),
                  status: try c.decodeIfPresent(String.self, forKey: .status) ?? "pending",
                  appliedChangeIds: try c.decodeIfPresent([String].self, forKey: .appliedChangeIds) ?? [],
                  resolvedAt: try c.decodeIfPresent(Date.self, forKey: .resolvedAt))
    }

    public var proposal: PlanProposal { PlanProposal(summary: summary, changes: changes) }

    /// Unknown statuses read as pending (the server's CHECK allows only the four known ones).
    public func toDomain() -> Proposal {
        Proposal(id: id, createdAt: createdAt, source: source, summary: summary, changes: changes,
                 status: ProposalStatus(rawValue: status) ?? .pending, appliedChangeIds: appliedChangeIds,
                 resolvedAt: resolvedAt)
    }
}

/// A pending proposal the app's strict decoder refused (unknown change type, bad field): skipped and recorded as a
/// sync failure so the rest of the round goes on.
public struct MalformedProposal: Sendable, Equatable {
    public let id: String
    public let createdAt: Date?
    public let message: String

    public init(id: String, createdAt: Date?, message: String) {
        self.id = id
        self.createdAt = createdAt
        self.message = message
    }
}

/// One row of the pending-proposals pull, decoded per row so one bad proposal can't break the sync round.
public enum PulledProposal: Sendable, Equatable, Decodable {
    case valid(ProposalDTO)
    case malformed(MalformedProposal)

    public init(from decoder: Decoder) throws {
        do {
            self = .valid(try ProposalDTO(from: decoder))
        } catch {
            let c = try? decoder.container(keyedBy: ProposalDTO.CodingKeys.self)
            let id = (try? c?.decode(String.self, forKey: .id)) ?? "unknown"
            let createdAt = (try? c?.decode(Date.self, forKey: .createdAt)) ?? nil
            self = .malformed(MalformedProposal(id: id, createdAt: createdAt, message: Self.describe(error)))
        }
    }

    /// A short, log-safe reason: where decoding failed (e.g. `changes[0].type`) and why.
    static func describe(_ error: Error) -> String {
        let (path, reason): ([CodingKey], String)
        switch error as? DecodingError {
        case .dataCorrupted(let ctx)?: (path, reason) = (ctx.codingPath, ctx.debugDescription)
        case .keyNotFound(let key, let ctx)?: (path, reason) = (ctx.codingPath + [key], "missing")
        case .typeMismatch(_, let ctx)?: (path, reason) = (ctx.codingPath, ctx.debugDescription)
        case .valueNotFound(_, let ctx)?: (path, reason) = (ctx.codingPath, ctx.debugDescription)
        default: return "Unreadable proposal"
        }
        let field = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "Unreadable proposal (\(field)): \(reason)"
    }
}
