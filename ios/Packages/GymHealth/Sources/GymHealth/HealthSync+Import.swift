import Foundation
import GymCore
import GymData

/// Import: body mass / body fat from Apple Health into weigh-ins (source `appleHealth`). Each weigh-in remembers
/// the Health sample ids it came from (`healthSampleId` / `healthFatSampleId`, synced), which is how imports are
/// deduplicated and Health deletions applied on any device.
extension HealthSync {
    /// A Health sample this close in value to a manual weigh-in on the same day is the same weigh-in.
    static let duplicateToleranceKg = 0.1
    /// Body fat pairs with a weigh-in taken within this long of it (smart scales write both together).
    static let bodyFatPairing: TimeInterval = 600
    /// Unpaired body fat samples wait this long for their weight to arrive in a later batch.
    static let pendingBodyFatWindow: TimeInterval = 2 * 86_400
    static let maxUnmatchedDeletions = 1_000

    private struct Outcome {
        var added = 0
        var changed = false
    }

    func runImport() async {
        guard isEnabled, canImport() else { return }
        let run = generation
        isSyncing = true
        defer { isSyncing = false }
        let start = state.importStart ?? now().addingTimeInterval(-Self.importWindow)
        do {
            let changes = try await store.bodyChanges(since: start, anchor: state.anchor)
            guard run == generation, isEnabled else { return }
            let outcome = try apply(changes)
            lastError = nil
            let time = now()
            update {
                $0.anchor = changes.anchor
                $0.importStart = start
                $0.lastImportAt = time
                if outcome.added > 0 { $0.lastImportCount = outcome.added }
                $0.pendingBodyFat.removeAll { time.timeIntervalSince($0.date) > Self.pendingBodyFatWindow }
            }
            if outcome.added > 0 || outcome.changed { onBodyChanged() }
        } catch {
            Self.log.error("Health import failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't read from Apple Health. We'll try again next time."
        }
    }

    /// Applies one anchored batch: deletions first (so a replaced weight can't take this batch's body fat with it),
    /// then weights, then body fat.
    private func apply(_ changes: HealthBodyChanges) throws -> Outcome {
        var outcome = Outcome()
        var unmatched: [UUID] = []
        // Earlier deletions whose weigh-in has since come back (from the cloud), then this batch's.
        for uuid in state.unmatchedDeletions + changes.deleted {
            if try removeImported(uuid) { outcome.changed = true } else { unmatched.append(uuid) }
        }
        let kept = Array(unmatched.suffix(Self.maxUnmatchedDeletions))
        update { $0.unmatchedDeletions = kept }
        let foreign = changes.added.filter { !$0.fromThisApp }
        for sample in foreign.filter({ $0.kind == .bodyMass }).sorted(by: { $0.date < $1.date }) {
            if try importMass(sample) { outcome.added += 1 }
        }
        for sample in foreign where sample.kind == .bodyFat {
            if try attachBodyFat(sample) { outcome.changed = true }
        }
        // Body fat still waiting may now have its weigh-in (e.g. it arrived from the cloud).
        for pending in state.pendingBodyFat {
            let sample = HealthBodySample(uuid: pending.uuid, kind: .bodyFat, value: pending.value, date: pending.date)
            if try attachBodyFat(sample) { outcome.changed = true }
        }
        return outcome
    }

    /// Edit time for imported data: the sample's own date, so a newer cloud deletion of the same weigh-in still wins.
    private func editTime(_ sample: HealthBodySample) -> Date { min(sample.date, now()) }

    private func importMass(_ sample: HealthBodySample) throws -> Bool {
        // Already known here or on another device (live, or deleted in the app: a tombstone never comes back).
        guard try !body.hasRecord(healthSampleId: sample.uuid) else { return false }
        let existing = try body.entries(since: calendar.startOfDay(for: sample.date))
        let duplicate = existing.contains {
            $0.source != .appleHealth && calendar.isDate($0.date, inSameDayAs: sample.date)
                && abs($0.weightKg - sample.value) <= Self.duplicateToleranceKg + 1e-9 // 81.2 − 81.1 is 0.100000…09
        }
        guard !duplicate, DomainLimits.bodyweightViolation(weightKg: sample.value, bodyFatPct: nil) == nil else {
            return false
        }
        // A body fat sample from an earlier batch may have been waiting for this weight.
        let pending = state.pendingBodyFat
            .filter { abs($0.date.timeIntervalSince(sample.date)) <= Self.bodyFatPairing }
            .min { abs($0.date.timeIntervalSince(sample.date)) < abs($1.date.timeIntervalSince(sample.date)) }
        try body.add(BodyweightEntry(date: sample.date, weightKg: sample.value, bodyFatPct: pending?.value,
                                     source: .appleHealth, healthSampleId: sample.uuid,
                                     healthFatSampleId: pending?.uuid),
                     editedAt: editTime(sample))
        if let pending { update { $0.pendingBodyFat.removeAll { $0.uuid == pending.uuid } } }
        return true
    }

    /// Returns true when a weigh-in changed; an unpaired recent sample waits for its weight.
    private func attachBodyFat(_ sample: HealthBodySample) throws -> Bool {
        guard DomainLimits.bodyweightViolation(weightKg: 80, bodyFatPct: sample.value) == nil else { return false }
        let window = sample.date.addingTimeInterval(-Self.bodyFatPairing)
        let match = try body.entries(since: window)
            .filter { $0.source == .appleHealth && abs($0.date.timeIntervalSince(sample.date)) <= Self.bodyFatPairing }
            .min { abs($0.date.timeIntervalSince(sample.date)) < abs($1.date.timeIntervalSince(sample.date)) }
        guard let match else {
            if now().timeIntervalSince(sample.date) <= Self.pendingBodyFatWindow,
               !state.pendingBodyFat.contains(where: { $0.uuid == sample.uuid }) {
                update {
                    $0.pendingBodyFat.append(.init(uuid: sample.uuid, date: sample.date, value: sample.value))
                }
            }
            return false
        }
        update { $0.pendingBodyFat.removeAll { $0.uuid == sample.uuid } }
        guard match.healthFatSampleId != sample.uuid || match.bodyFatPct != sample.value else { return false }
        try body.upsert(entry(match, bodyFatPct: sample.value, fatSample: sample.uuid), editedAt: editTime(sample))
        return true
    }

    /// A sample deleted in Health: a weight removes its imported weigh-in, a body fat clears its value (only while
    /// that sample still supplies it).
    private func removeImported(_ uuid: UUID) throws -> Bool {
        update { $0.pendingBodyFat.removeAll { $0.uuid == uuid } }
        if let entry = try body.entry(healthFatSampleId: uuid) {
            try body.upsert(self.entry(entry, bodyFatPct: nil, fatSample: nil))
            return true
        }
        guard let entry = try body.entry(healthSampleId: uuid) else { return false }
        try body.delete(entry.id)
        // Its body fat sample may still be in Health (a scale replacing only the weight): let the new weight take it.
        if let fatId = entry.healthFatSampleId, let fat = entry.bodyFatPct {
            update { $0.pendingBodyFat.append(.init(uuid: fatId, date: entry.date, value: fat)) }
        }
        return true
    }

    private func entry(_ e: BodyweightEntry, bodyFatPct: Double?, fatSample: UUID?) -> BodyweightEntry {
        BodyweightEntry(id: e.id, date: e.date, weightKg: e.weightKg, bodyFatPct: bodyFatPct, timeOfDay: e.timeOfDay,
                        source: .appleHealth, healthSampleId: e.healthSampleId, healthFatSampleId: fatSample)
    }
}
