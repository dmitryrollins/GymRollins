#if DEBUG
import Foundation
import GymCore

/// Sample exports used when launched with `-importFixture [fitbod|strong|hevy|fitNotes]` (default Fitbod):
/// `ImportCSVView` uses this text directly instead of presenting `.fileImporter`, since XCUITest can't drive the
/// system Files picker reliably. Kept as embedded strings (rather than bundled files + `Bundle.main.url`) because
/// the app target and the `GymRollinsTests` fixtures live in different bundles.
///
/// Each mirrors `GymRollinsTests/Fixtures/<source>-sample.csv` (`ImportFixtureSyncTests` fails if they drift), so
/// the same expectations apply either way. The Fitbod one has 3 workouts, a warm-up set, a cardio row, an
/// unresolved exercise and one bad row; the others are described in `docs/plans/2026-09-29-plan-13-importers.md`.
enum ImportFixture {
    static func fileName(for source: ImportSource) -> String {
        "\(source == .fitNotes ? "fitnotes" : source.rawValue)-sample.csv"
    }

    static func csv(for source: ImportSource) -> String {
        switch source {
        case .fitbod: fitbod
        case .strong: strong
        case .hevy: hevy
        case .fitNotes: fitNotes
        }
    }

    /// Kept for callers written against the Fitbod-only fixture.
    static let fileName = fileName(for: .fitbod)
    static let csv = fitbod

    static let fitbod = """
    Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier
    2026-01-05 18:00:00 +0000,Barbell Bench Press,10,20.0,0.0,0.0,0.0,0.0,true,,1.0
    2026-01-05 18:00:00 +0000,Barbell Bench Press,8,60.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-05 18:00:00 +0000,Barbell Bench Press,8,60.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-05 18:00:00 +0000,Barbell Bench Press,8,60.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-05 18:00:00 +0000,Lat Pulldown,10,50.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-05 18:00:00 +0000,Lat Pulldown,10,50.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-05 18:00:00 +0000,Lat Pulldown,10,50.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-05 18:00:00 +0000,Clam,15,0.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-05 18:00:00 +0000,Clam,15,0.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-05 18:00:00 +0000,Dumbbell Biceps Curls,10,12.0,0.0,0.0,0.0,0.0,false,,2.0
    2026-01-05 18:00:00 +0000,Dumbbell Biceps Curls,10,12.0,0.0,0.0,0.0,0.0,false,,2.0
    2026-01-07 18:30:00 +0000,Walking,0,0.0,1200.0,1500.0,0.0,0.0,false,,1.0
    2026-01-07 18:30:00 +0000,Barbell Deadlift,5,100.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-07 18:30:00 +0000,Barbell Deadlift,5,100.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-07 18:30:00 +0000,Barbell Deadlift,5,100.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-07 18:30:00 +0000,Lat Pulldown,abc,50.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-07 18:30:00 +0000,Zorblax Press,10,30.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-07 18:30:00 +0000,Zorblax Press,10,30.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-07 18:30:00 +0000,Handle Band Row,12,20.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-07 18:30:00 +0000,Handle Band Row,12,20.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Swimming,0,0.0,900.0,800.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Swimming,0,0.0,600.0,500.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Barbell Bench Press,8,62.5,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Barbell Bench Press,8,62.5,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Barbell Bench Press,8,62.5,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Clam,20,0.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Clam,20,0.0,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Lat Pulldown,10,52.5,0.0,0.0,0.0,0.0,false,,1.0
    2026-01-09 07:00:00 +0000,Lat Pulldown,10,52.5,0.0,0.0,0.0,0.0,false,,1.0
    """

    static let strong = "\u{FEFF}" + """
    Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),W,95,10,0,0,,"Slept well, felt good",
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),1,135,8,0,0,,"Slept well, felt good",8
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),2,135,8,0,0,"Paused, 1s","Slept well, felt good",8.5
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),D,115,10,0,0,,"Slept well, felt good",
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Bench Press (Barbell),Rest Timer,0,0,0,90,,"Slept well, felt good",
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Lateral Raise (Dumbbell),1,20,12,0,0,,"Slept well, felt good",
    2026-01-05 18:00:00,"Push, heavy",1h 5m,Lateral Raise (Dumbbell),F,20,9,0,0,,"Slept well, felt good",

    2026-01-07 07:30:00,Legs,45m,Squat (Barbell),W,95,5,0,0,,,
    2026-01-07 07:30:00,Legs,45m,Squat (Barbell),1,185,5,0,0,,,
    2026-01-07 07:30:00,Legs,45m,Squat (Barbell),2,185,5,0,0,,,
    2026-01-07 07:30:00,Legs,45m,Squat (Barbell),3,abc,5,0,0,,,
    2026-01-07 07:30:00,Legs,45m,Romanian Deadlift (Barbell),1,155,8,0,0,,,
    2026-01-07 07:30:00,Legs,45m,Plank,1,0,0,0,60,,,
    2026-01-07 07:30:00,Legs,45m,Running (Treadmill),1,0,0,1600,600,,,
    2026-01-07 07:30:00,Legs,45m,Zorblax Carry (Dumbbell),1,50,20,0,0,,,
    2026-01-09 12:00:00,Pull,50m,Pull Up,1,0,10,0,0,,,
    2026-01-09 12:00:00,Pull,50m,Pull Up,2,0,8,0,0,,,
    2026-01-09 12:00:00,Pull,50m,Lat Pulldown (Cable),1,120,10,0,0,,,
    2026-01-09 12:00:00,Pull,50m,Seated Row (Cable),1,110,12,0,0,,,
    2026-01-09 12:00:00,Pull,50m,Bicep Curl (Dumbbell),1,30,10,0,0,,,
    """

    static let hevy = """
    title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,\
    weight_kg,reps,distance_km,duration_seconds,rpe
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Bench Press (Barbell)",,"Pause at bottom",0,"warmup",40,10,,,
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Bench Press (Barbell)",,"Pause at bottom",1,"normal",80,8,,,8
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Bench Press (Barbell)",,"Pause at bottom",2,"drop_set",60,10,,,
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Bicep Curl (Dumbbell)",1,"",0,"normal",14,10,,,
    "Upper, A","5 Jan 2026, 18:00","5 Jan 2026, 19:10","Chest focus","Triceps Pushdown",1,"",0,"failure",30,12,,,9.5
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Squat (Barbell)",,"",0,"warmup",60,5,,,
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Squat (Barbell)",,"",1,"normal",100,5,,,
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Squat (Barbell)",,"",2,"normal",100,x,,,
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Plank",,"",0,"normal",,,,60,
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Running",,"",0,"normal",,,2.5,900,
    "Legs","7 Jan 2026, 07:30","7 Jan 2026, 08:25","","Zorblax Carry (Dumbbell)",,"",0,"normal",20,20,,,
    "Pull","9 Jan 2026, 12:00","9 Jan 2026, 12:55","Back day
    felt strong","Pull Up",,"",0,"normal",,10,,,
    "Pull","9 Jan 2026, 12:00","9 Jan 2026, 12:55","Back day
    felt strong","Pull Up",,"",1,"normal",,8,,,
    """

    static let fitNotes = """
    Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind
    2026-01-05,Flat Barbell Bench Press,Chest,60.0,,8,,,,,wr
    2026-01-05,Flat Barbell Bench Press,Chest,60.0,,8,,,,"slow, controlled",wr
    2026-01-05,Lat Pulldown,Back,50.0,,10,,,,,wr
    2026-01-05,Dumbbell Curl,Biceps,,25,10,,,,,wr
    2026-01-05,Chin Up,Back,,,8,,,,,r
    2026-01-07,Barbell Squat,Legs,100.0,,5,,,,,wr
    2026-01-07,Barbell Squat,Legs,100.0,,x,,,,,wr
    2026-01-07,Plank,Abs,,,,,,01:00,,t
    2026-01-07,Running (Treadmill),Cardio,,,,5,km,25:30,,dt
    2026-01-07,Cycling,Cardio,,,,10,mi,1:00:00,,dt
    2026-01-07,Zorblax Carry,Legs,40.0,,20,,,,,wr
    """
}
#endif
