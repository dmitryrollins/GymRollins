import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Round-trips a value through the wire format.
func wire<T: Codable>(_ value: T) throws -> T {
    try SyncJSON.decoder.decode(T.self, from: SyncJSON.encoder.encode(value))
}

/// A µs-aligned instant (what the server can store).
let t0 = SyncDate.parse("2026-09-26T18:00:00.123456+00:00")!

@Suite struct SyncDateTests {
    @Test(arguments: [
        ("2026-09-26T18:00:00+00:00", 1_790_445_600.0),
        ("2026-09-26T18:00:00Z", 1_790_445_600.0),
        ("2026-09-26T18:00:00.5+00:00", 1_790_445_600.5),
        ("2026-09-26T18:00:00.123456+00:00", 1_790_445_600.123456),
        ("2026-09-26 18:00:00.12+00", 1_790_445_600.12),
        ("2026-09-26T20:30:00.000001+02:30", 1_790_445_600.000001),
        ("2026-09-26T13:00:00-05:00", 1_790_445_600.0),
        ("1969-12-31T23:59:59.5Z", -0.5),
    ])
    func parsesPostgresTimestamps(raw: String, epoch: Double) throws {
        let date = try #require(SyncDate.parse(raw))
        #expect(abs(date.timeIntervalSince1970 - epoch) < 0.000_000_5)
    }

    @Test func rejectsGarbage() {
        #expect(SyncDate.parse("yesterday") == nil)
        #expect(SyncDate.parse("2026-13-01T00:00:00Z") == nil)
        #expect(SyncDate.parse("2026-09-26") == nil)
    }

    @Test func formatsUTCWithSixDigitsAndRoundTripsExactly() throws {
        #expect(SyncDate.format(t0) == "2026-09-26T18:00:00.123456Z")
        #expect(SyncDate.parse(SyncDate.format(t0)) == t0)
        #expect(SyncDate.format(Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.500000Z")
        // Any server timestamp formats back to the identical string (cursor filters rely on it).
        for raw in ["2026-09-26T18:00:00.000001Z", "2026-09-26T18:00:00.999999Z", "2031-01-01T00:00:00.654321Z"] {
            #expect(SyncDate.parse(raw).map(SyncDate.format) == raw)
        }
    }

    @Test func goalDateUsesLocalCalendarDay() throws {
        let day = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31)))
        #expect(SyncDay.format(day) == "2026-12-31")
        #expect(SyncDay.parse("2026-12-31") == day)
    }
}

@Suite struct DTOTests {
    @Test func profileRoundTrip() throws {
        var p = ProfileSnapshot()
        p.unit = .kg
        p.heightCm = 180
        p.goalWeightKg = 85
        p.goalDate = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31))
        p.platesKg = [20.411656, 11.339809]
        p.mcpAutoApply = true
        p.mcpReadPlan = false
        p.sex = .female
        p.birthYear = 1988
        let row = SyncRow(value: p, clientUpdatedAt: t0)
        let dto = try wire(ProfileDTO(row))
        #expect(dto.toDomain() == row)
    }

    @Test func profileEncodesSnakeCaseAndExplicitNulls() throws {
        let json = try JSONSerialization.jsonObject(
            with: SyncJSON.encoder.encode(ProfileDTO(SyncRow(value: ProfileSnapshot(), clientUpdatedAt: t0)))
        ) as? [String: Any]
        let keys = Set(json?.keys.map { $0 } ?? [])
        #expect(keys.contains("warmup_rest_sec"))
        #expect(keys.contains("plates_kg"))
        #expect(keys.contains("goal_date"))
        #expect(json?["mcp_read_plan"] as? Bool == true)
        #expect(json?["goal_date"] is NSNull)
        #expect(json?["sex"] is NSNull) // cleared on the device -> cleared on the server
        #expect(json?["birth_year"] is NSNull)
        #expect(json?["client_updated_at"] as? String == "2026-09-26T18:00:00.123456Z")
        #expect(!keys.contains("updated_at"))
        #expect(!keys.contains("user_id"))
    }

    @Test func customExerciseRoundTrip() throws {
        let ex = Exercise(id: "custom-abc", name: "Sled", bodyPart: "legs", equipment: "sled", target: "quads",
                          isCustom: true, mode: .time, bilateral: true)
        let row = SyncRow(value: ex, clientUpdatedAt: t0, deletedAt: t0)
        #expect(try wire(CustomExerciseDTO(row)).toDomain() == row)
    }

    @Test func routineRoundTripWithJsonbExercises() throws {
        let routine = Routine(name: "Push", emoji: "💪", policy: .linear, paused: true, exercises: [
            RoutineExercise(exerciseId: "bench", sets: 3, reps: 8, repsMin: 6, weightKg: 60, policy: .double,
                            incKg: 2.5, supersetGroup: "A", weightSetAt: t0),
            RoutineExercise(exerciseId: "plank", sets: 3, reps: 0, sec: 45, mode: .time),
        ])
        let row = SyncRow(value: RoutineSnapshot(routine: routine, position: 2), clientUpdatedAt: t0)
        #expect(try wire(RoutineDTO(row)).toDomain() == row)
        let json = try JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(RoutineDTO(row))) as? [String: Any]
        let first = (json?["exercises"] as? [[String: Any]])?.first
        #expect(first?["exercise_id"] as? String == "bench")
        #expect(first?["reps_min"] as? Int == 6)
        #expect(first?["prog"] as? String == "double")
        #expect(first?["sg"] as? String == "A")
    }

    @Test func weekdayAndBodyweightRoundTrip() throws {
        let day = SyncRow(value: WeekdayAssignment(weekday: 3, routineId: UUID()), clientUpdatedAt: t0)
        #expect(try wire(WeekdayDTO(day)).toDomain() == day)
        let rest = SyncRow(value: WeekdayAssignment(weekday: 7, routineId: nil), clientUpdatedAt: t0)
        #expect(try wire(WeekdayDTO(rest)).toDomain() == rest)
        let bw = SyncRow(value: BodyweightEntry(date: t0, weightKg: 81.2, bodyFatPct: 14.5, timeOfDay: "morning"),
                         clientUpdatedAt: t0)
        #expect(try wire(BodyweightDTO(bw)).toDomain() == bw)
    }

    /// Plan 15: weigh-ins read from Apple Health keep their source across devices; rows without one are app rows.
    @Test func bodyweightSourceRoundTripsAndDefaultsToApp() throws {
        let health = SyncRow(value: BodyweightEntry(date: t0, weightKg: 81.2, bodyFatPct: 15, source: .appleHealth,
                                                    healthSampleId: UUID(), healthFatSampleId: UUID()),
                             clientUpdatedAt: t0)
        let dto = BodyweightDTO(health)
        #expect(try wire(dto).toDomain() == health)
        let json = try #require(String(data: try SyncJSON.encoder.encode(dto), encoding: .utf8))
        #expect(json.contains(#""source":"apple_health""#))
        #expect(json.contains(#""health_sample_id":""#) && json.contains(#""health_fat_sample_id":""#))
        let legacy = #"{"id":"6F1D1F0E-2C47-4E36-9D0A-000000000001","measured_at":"2026-09-26T09:00:00Z","w_kg":80,"#
            + #""client_updated_at":"2026-09-26T09:00:00Z"}"#
        let decoded = try SyncJSON.decoder.decode(BodyweightDTO.self, from: Data(legacy.utf8))
        #expect(decoded.toDomain().value.source == .app)
    }

    @Test func workoutRoundTripWithRecords() throws {
        let workout = Workout(startedAt: t0, endedAt: t0.addingTimeInterval(3_600), pausedSeconds: 90,
                              routineId: UUID(), name: "Push", entries: [
                                  WorkoutEntry(exerciseId: "bench", sets: [
                                      WorkoutSet(weightKg: 60, reps: 8, done: true, warmup: true, completedAt: t0),
                                      WorkoutSet(weightKg: 80, reps: 5, done: true, rir: 2, multiplier: 1),
                                  ], note: "felt good", supersetGroup: "A"),
                                  WorkoutEntry(exerciseId: "row", sets: [WorkoutSet(weightKg: 0, reps: 0, sec: 60, minutes: 1,
                                                                                    distanceM: 250)]),
                              ], source: .import, note: "n")
        let pr = PersonalRecord(exerciseId: "bench", kind: .e1RM, valueKg: 93.3, reps: nil, weightKg: nil, previousKg: 90)
        let row = SyncRow(value: WorkoutSnapshot(workout: workout, records: [pr], volumeKg: 880), clientUpdatedAt: t0)
        #expect(try wire(WorkoutDTO(row)).toDomain() == row)
    }

    /// A PostgREST response for `workouts?select=*,workout_entries(*,workout_sets(*))` (embeds unordered).
    @Test func decodesCapturedPostgRESTWorkout() throws {
        let json = """
        [{"id":"8f7c0a2e-3b1d-4c55-9a51-2f7e0b8c9d10","user_id":"11111111-2222-3333-4444-555555555555",
          "started_at":"2026-09-26T17:00:00+00:00","ended_at":"2026-09-26T18:05:12.5+00:00","paused_sec":30.5,
          "routine_id":null,"name":"Push A","source":"app","note":null,"vol_kg":1234.56,
          "records":[{"exerciseId":"bench","kind":"volume","valueKg":900,"previousKg":800}],
          "client_updated_at":"2026-09-26T18:05:13.123456+00:00","updated_at":"2026-09-26T18:05:14.654321+00:00",
          "deleted_at":null,
          "workout_entries":[
            {"id":"b2b2b2b2-0000-4000-8000-000000000002","workout_id":"8f7c0a2e-3b1d-4c55-9a51-2f7e0b8c9d10",
             "user_id":"11111111-2222-3333-4444-555555555555","exercise_id":"row","position":1,"note":null,
             "superset_group":null,"workout_sets":[]},
            {"id":"a1a1a1a1-0000-4000-8000-000000000001","workout_id":"8f7c0a2e-3b1d-4c55-9a51-2f7e0b8c9d10",
             "user_id":"11111111-2222-3333-4444-555555555555","exercise_id":"bench","position":0,"note":"ok",
             "superset_group":"A","workout_sets":[
               {"id":"c0000000-0000-4000-8000-000000000002","entry_id":"a1a1a1a1-0000-4000-8000-000000000001",
                "user_id":"11111111-2222-3333-4444-555555555555","position":1,"w_kg":81.646627,"r":5,"sec":null,
                "min":null,"dist_m":null,"done":true,"warmup":false,"rir":2,"rpe":null,"multiplier":1,
                "completed_at":"2026-09-26T17:20:00.1+00:00"},
               {"id":"c0000000-0000-4000-8000-000000000001","entry_id":"a1a1a1a1-0000-4000-8000-000000000001",
                "user_id":"11111111-2222-3333-4444-555555555555","position":0,"w_kg":20.411656,"r":10,"sec":null,
                "min":null,"dist_m":null,"done":true,"warmup":true,"rir":null,"rpe":7.5,"multiplier":1,
                "completed_at":null}]}]}]
        """
        let dtos = try SyncJSON.decoder.decode([WorkoutDTO].self, from: Data(json.utf8))
        let row = try #require(dtos.first).toDomain()
        let w = row.value.workout
        #expect(w.name == "Push A")
        #expect(w.pausedSeconds == 30.5)
        #expect(w.entries.map(\.exerciseId) == ["bench", "row"])
        #expect(w.entries[0].sets.map(\.reps) == [10, 5])
        #expect(w.entries[0].sets[0].warmup)
        #expect(w.entries[0].sets[0].rpe == 7.5)
        #expect(w.entries[0].sets[1].weightKg == 81.646627)
        #expect(row.value.volumeKg == 1234.56)
        #expect(row.value.records.first?.kind == .volume)
        #expect(row.serverUpdatedAt == SyncDate.parse("2026-09-26T18:05:14.654321Z"))
        #expect(SyncDate.format(row.clientUpdatedAt) == "2026-09-26T18:05:13.123456Z")
    }

    @Test func decodesWorkoutPushResults() throws {
        let ok = try SyncJSON.decoder.decode(WorkoutPushResult.self,
                                             from: Data(#"{"status":"ok","updated_at":"2026-09-26T18:00:00.123456+00:00"}"#.utf8))
        #expect(ok == .ok(updatedAt: t0))
        let stale = try SyncJSON.decoder.decode(WorkoutPushResult.self,
                                                from: Data(#"{"status":"stale","updated_at":"2026-09-26T18:00:00.123456+00:00"}"#.utf8))
        #expect(stale == .stale(updatedAt: t0))
    }

    @Test func decodesProposal() throws {
        let json = """
        {"id":"0f0f0f0f-0000-4000-8000-000000000000","user_id":"11111111-2222-3333-4444-555555555555",
         "created_at":"2026-09-26T10:00:00.5+00:00","source":"claude","summary":"Bump bench",
         "changes":[{"id":"c1","type":"weight","routineId":"r1","exerciseId":"bench","weightKg":62.5}],
         "status":"pending","applied_change_ids":[],"resolved_at":null,
         "client_updated_at":"2026-09-26T10:00:00.5+00:00","updated_at":"2026-09-26T10:00:00.5+00:00"}
        """
        let dto = try SyncJSON.decoder.decode(ProposalDTO.self, from: Data(json.utf8))
        #expect(dto.proposal.changes.first?.type == .weight)
        #expect(dto.proposal.changes.first?.weightKg == 62.5)
        #expect(dto.status == "pending")
    }

    /// One unreadable row (unknown change type, bad field) decodes as `.malformed` instead of failing the list.
    @Test func pendingProposalsDecodePerRow() throws {
        let json = """
        [{"id":"0f0f0f0f-0000-4000-8000-000000000001","created_at":"2026-09-26T10:00:00Z","summary":"Ok",
          "changes":[{"id":"c1","type":"sets","routineId":"r1","exerciseId":"bench","sets":4}],"status":"pending"},
         {"id":"0f0f0f0f-0000-4000-8000-000000000002","created_at":"2026-09-26T10:00:00Z","summary":"Bad",
          "changes":[{"id":"c1","type":"teleport"}],"status":"pending"},
         {"id":"0f0f0f0f-0000-4000-8000-000000000003","created_at":"2026-09-26T10:00:00Z","summary":"Bad field",
          "changes":[{"id":"c1","type":"sets","sets":"four"}],"status":"pending"}]
        """
        let rows = try SyncJSON.decoder.decode([PulledProposal].self, from: Data(json.utf8))
        #expect(rows.count == 3)
        guard case .valid(let ok) = rows[0] else { Issue.record("first row should decode"); return }
        #expect(ok.summary == "Ok")
        guard case .malformed(let bad) = rows[1], case .malformed(let badField) = rows[2] else {
            Issue.record("rows 2 and 3 should be malformed"); return
        }
        #expect(bad.id == "0f0f0f0f-0000-4000-8000-000000000002")
        #expect(bad.createdAt != nil)
        #expect(bad.message.contains("changes"))
        #expect(badField.id == "0f0f0f0f-0000-4000-8000-000000000003")
    }
}
