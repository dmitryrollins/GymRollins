import Foundation
import GymCore
import SwiftData

/// What applying a proposal did.
public struct ProposalApplyOutcome: Sendable, Equatable {
    public let applied: [String]
    /// Selected changes that failed validation against the current plan (not applied).
    public let skipped: [PlanViolation]
    /// The applied `today` changes: the routine to show on Today on each date (the app stores these, like Switch;
    /// the plan itself is unchanged by them).
    public let days: [PlanDayRoutine]

    public init(applied: [String], skipped: [PlanViolation], days: [PlanDayRoutine] = []) {
        self.applied = applied
        self.skipped = skipped
        self.days = days
    }
}

/// The proposal lifecycle on the device: validate against the current plan → apply the valid selected changes →
/// save routines/schedule (which go dirty and sync) → keep the plan before as the undo snapshot → resolve.
///
/// Apply and undo are atomic: the plan changes, the snapshot and the proposal's resolution are staged in the one
/// context and saved once; any failure rolls the context back, so the plan is unchanged and the proposal keeps its
/// previous status.
@MainActor
public final class ProposalService {
    /// Points inside an apply/undo transaction (for fault-injection tests).
    enum Step: Equatable { case stagePlan, resolve, commit }

    private let context: ModelContext
    private let proposals: ProposalRepository
    private let routines: RoutineRepository
    private let profiles: ProfileRepository
    /// Transaction-scoped repositories: they stage writes without saving.
    private let stagedProposals: ProposalRepository
    private let stagedRoutines: RoutineRepository
    /// Test hook: throws at a step to simulate a failure mid-transaction.
    var fault: ((Step) throws -> Void)?
    private let exerciseExists: @Sendable (String) -> Bool
    private let mode: (String) -> ExerciseMode
    private let now: () -> Date
    /// The owner's calendar: `today` changes are checked against the local date of `now()` in it.
    private let calendar: Calendar

    public init(context: ModelContext, exerciseExists: @escaping @Sendable (String) -> Bool,
                mode: @escaping (String) -> ExerciseMode = { _ in .reps }, now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current) {
        self.calendar = calendar
        self.context = context
        proposals = ProposalRepository(context: context, now: now)
        routines = RoutineRepository(context: context, now: now)
        profiles = ProfileRepository(context: context, now: now)
        stagedProposals = ProposalRepository(context: context, now: now, autosave: false)
        stagedRoutines = RoutineRepository(context: context, now: now, autosave: false)
        self.exerciseExists = exerciseExists
        self.mode = mode
        self.now = now
    }

    /// Change id → why it can't be applied to the current plan (only invalid changes are listed).
    public func violations(for proposal: Proposal) throws -> [String: String] {
        let (_, rejected) = partition(proposal.changes, summary: proposal.summary, plan: try routines.planState())
        return Dictionary(rejected.compactMap { v in v.changeId.map { ($0, v.message) } },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Applies the selected changes that are valid against the current plan.
    @discardableResult
    public func apply(_ id: UUID, changeIds: Set<String>, auto: Bool = false) throws -> ProposalApplyOutcome {
        guard let proposal = try proposals.proposal(id) else { throw ProposalError.notFound }
        guard proposal.status == .pending else { throw ProposalError.alreadyResolved }
        let before = try routines.planState()
        let selected = proposal.changes.filter { changeIds.contains($0.id) }
        let (valid, rejected) = partition(selected, summary: proposal.summary, plan: before)
        guard !valid.isEmpty else { throw ProposalError.nothingToApply }
        let after = try PlanChangeApplier.applyDetailed(valid, to: before, now: now(), mode: mode,
                                                        newID: StableUUID.generator(namespace: id))
        let applied = valid.map(\.id)
        try transaction {
            try fault?(.stagePlan)
            try stagedRoutines.save(plan: after.plan)
            try fault?(.resolve)
            try stagedProposals.markApplied(id, changeIds: applied, total: proposal.changes.count, snapshot: before,
                                            skipped: rejected, auto: auto)
        }
        return ProposalApplyOutcome(applied: applied, skipped: rejected, days: after.days)
    }

    public func dismiss(_ id: UUID) throws {
        try proposals.dismiss(id)
    }

    /// Restores the plan saved when the proposal was applied (within 7 days). False when there's nothing to undo.
    @discardableResult
    public func undo(_ id: UUID) throws -> Bool {
        var undone = false
        try transaction {
            guard let snapshot = try stagedProposals.undo(id) else { return }
            try fault?(.stagePlan)
            try stagedRoutines.save(plan: snapshot)
            undone = true
        }
        return undone
    }

    /// Runs `stage` against the transaction-scoped repositories and saves once; on any error the context is rolled
    /// back to the last save. Unrelated pending edits are saved first so the rollback can't discard them.
    private func transaction(_ stage: () throws -> Void) throws {
        if context.hasChanges { try context.save() }
        do {
            try stage()
            try fault?(.commit)
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
    }

    /// When the owner turned on "Apply changes without asking": applies every valid change of each pending
    /// proposal; invalid changes are skipped and recorded. `applied` gets each applied proposal's outcome (its
    /// `today` changes are the caller's to store). Returns how many proposals were applied.
    public func autoApplyPending(applied: (UUID, ProposalApplyOutcome) -> Void = { _, _ in }) throws -> Int {
        guard try profiles.load().mcpAutoApply else { return 0 }
        var count = 0
        for proposal in try proposals.pending().reversed() { // oldest first
            do {
                let outcome = try apply(proposal.id, changeIds: Set(proposal.changes.map(\.id)), auto: true)
                applied(proposal.id, outcome)
                count += 1
            } catch ProposalError.nothingToApply {
                let (_, rejected) = partition(proposal.changes, summary: proposal.summary,
                                              plan: try routines.planState())
                try proposals.recordSkipped(proposal.id, skipped: rejected)
            } catch let error as PlanApplyError {
                if case .invalid(let changeId) = error {
                    let violation = PlanViolation(changeId: changeId, field: "change", message: "Couldn't apply")
                    try proposals.recordSkipped(proposal.id, skipped: [violation])
                }
            }
        }
        return count
    }

    /// Splits `changes` into those valid together against `plan` and the violations of the rest. Dropping an
    /// invalid change can invalidate a later one that depended on it, so this repeats until stable.
    private func partition(_ changes: [PlanChange], summary: String,
                           plan: PlanState) -> (valid: [PlanChange], rejected: [PlanViolation]) {
        let validator = PlanChangeValidator(plan: plan.snapshot, exerciseExists: exerciseExists,
                                            today: PlanDay.key(now(), calendar: calendar))
        var valid = changes
        var rejected: [PlanViolation] = []
        while !valid.isEmpty {
            let found = validator.validate(PlanProposal(summary: summary, changes: valid)).filter { $0.changeId != nil }
            guard !found.isEmpty else { break }
            let bad = Set(found.compactMap(\.changeId))
            for v in found where !rejected.contains(where: { $0.changeId == v.changeId }) { rejected.append(v) }
            valid.removeAll { bad.contains($0.id) }
        }
        return (valid, rejected)
    }
}
