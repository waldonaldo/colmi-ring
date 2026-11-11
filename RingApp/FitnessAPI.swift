import Foundation

// MARK: - Fitness server API (phone app)
//
// The Fitness tab reads and writes the self-hosted Fitness server over the same
// link and ring token as the ring uploads (/api/app/*). The server keeps all the
// logic: schedules, reminders, scoring, Atlas sync. Kept in its own files so the
// fork stays easy to merge with upstream colmi-ring.

enum FitnessAPIError: LocalizedError {
    case notConfigured
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set up the Fitness server in Settings first."
        case .http(401, _): return "The Fitness server rejected the ring token."
        case .http(let code, let message): return message ?? "Fitness server answered HTTP \(code)."
        }
    }
}

struct EmptyReply: Decodable {}

extension FitnessLink {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Calls the Fitness server and decodes the JSON answer.
    func api<T: Decodable>(_ path: String, method: String = "GET",
                           body: [String: Any]? = nil) async throws -> T {
        guard isConfigured else { throw FitnessAPIError.notConfigured }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        guard let req = request(path, method: method, body: data, timeout: 15) else {
            throw FitnessAPIError.notConfigured
        }
        let (out, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let json = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
            throw FitnessAPIError.http(code, json?["error"] as? String)
        }
        return try Self.decoder.decode(T.self, from: out)
    }

    /// The web app, for things the phone doesn't edit (schedules, plans).
    func webURL(_ path: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }
}

/// "2026-11-08T07:30" (server local wall time) <-> Date.
enum LocalStamp {
    private static let f: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func string(_ d: Date) -> String { f.string(from: d) }
    static func date(_ s: String) -> Date? { f.date(from: String(s.prefix(16))) }
    static func dayDate(_ s: String) -> Date? { day.date(from: String(s.prefix(10))) }
    static func today() -> String { day.string(from: Date()) }
}

// MARK: - Models

struct AppToday: Decodable {
    let date: String
    let meds: [AppMed]
    let medsTaken: Int
    let workoutsToday: [WorkoutRow]
    let week: [WorkoutRow]
    let bp: BPBrief
}

struct AppMed: Decodable, Identifiable {
    let id: Int
    let name: String
    let type: String
    let dosage: String?
    let instructions: String?
    let description: String?
    let warnings: String?
    let labels: [String]
    let scheduleId: Int?
    let status: String          // pending | taken | skipped
    let dueAt: String?
    let dueLabel: String
    let trigger: String
    let late: Bool

    var isMedication: Bool { type == "medication" }
}

struct WorkoutRow: Decodable, Identifiable {
    let id: Int
    let name: String
    let scheduledDate: String?
    let startTime: String?
    let status: String          // scheduled | in_progress | completed | missed | cancelled
    let exerciseCount: Int?
    let rank: String?
    let completionPct: Int?
    let caloriesEst: Int?
    let durationSec: Int?
}

struct WorkoutState: Decodable {
    let id: Int
    let name: String
    let status: String
    let scheduledDate: String?
    let startedAt: String?
    let completedAt: String?
    let exercises: [WorkoutExercise]
    let sets: [WorkoutSet]?
    let result: WorkoutResult?
    let muscles: MuscleSummary?    // Fitness 2026-11-11
}

/// Muscle keys and group keys a workout or routine works.
struct MuscleSummary: Decodable {
    let primary: [String]?
    let secondary: [String]?
    let groups: [String]?
    let secondaryGroups: [String]?
}

struct WorkoutExercise: Decodable, Identifiable {
    let id: Int                 // workout_exercise id
    let exerciseId: Int
    let exerciseName: String
    let exerciseType: String    // strength | cardio | bodyweight | flexibility
    let bodyweightMode: String? // reps | time
    let targetSets: Int?
    let targetReps: Int?
    let targetWeight: Double?
    let targetDurationSec: Int?
    let restSeconds: Int?
    let notes: String?
    // How-to (Fitness 2026-11-10). All optional so older servers still decode.
    let gifPath: String?
    let images: [String]?          // "/media/<id>/lib-0.jpg" start, end photos
    let videoUrl: String?
    let videoPath: String?
    let exerciseInstructions: [String]?
    let tips: [String]?
    let description: String?
    let mediaCredit: String?
    let primaryMuscles: [String]?
    let equipment: [String]?
    let defaultSpeed: Double?      // cardio: mph to pre-fill
    // Muscles and distance (Fitness 2026-11-11). Optional for older servers.
    let secondaryMuscles: [String]?
    let targetDistanceMi: Double?
    // Recommended setup for you (Fitness 2026-11-11). Optional for older servers.
    let recommended: ExerciseRecommendation?

    var isCardio: Bool { exerciseType == "cardio" }

    /// Logged by time (planks, treadmill) rather than reps.
    var isTimed: Bool {
        exerciseType == "cardio" || bodyweightMode == "time" || (targetReps == nil && targetDurationSec != nil)
    }
    var setCount: Int { max(1, targetSets ?? 1) }

    var targetText: String {
        if exerciseType == "cardio" {
            var parts: [String] = []
            if let d = targetDistanceMi, d > 0 { parts.append("\(SetEntry.miles(d)) mi") }
            if let s = targetDurationSec { parts.append("\(s / 60) min") }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        let sets = targetSets.map { "\($0) × " } ?? ""
        if let r = targetReps { return "\(sets)\(r) reps" }
        if let s = targetDurationSec { return "\(sets)\(s) s" }
        return sets.isEmpty ? "" : "\(targetSets ?? 1) sets"
    }
}

/// The server's suggested sets/reps/time for this exercise, from how often you
/// train and what you did last time. Numbers are Double so an odd value can't
/// break decoding the whole workout.
struct ExerciseRecommendation: Decodable {
    let text: String?              // "3 sets × 10-12 reps · 60 s rest"
    let how: String?               // reps | seconds | time
    let note: String?
    let sets: Double?
    let reps: [Double]?            // min, max
    let seconds: Double?
    let minutes: Double?
    let distanceMi: Double?
    let mph: Double?
    let rest: Double?
    let side: String?              // arm | leg | side
    let level: String?             // starting | building | regular
    let why: [String]?
    let targets: RecommendedTargets?
    let last: RecommendedLast?
}

struct RecommendedTargets: Decodable {
    let targetSets: Double?
    let targetReps: Double?
    let targetDurationSec: Double?
    let targetDistanceMi: Double?
    let restSeconds: Double?
}

/// What you did last time on this exercise (best completed set).
struct RecommendedLast: Decodable {
    let date: String?
    let sets: Double?
    let reps: Double?
    let seconds: Double?
    let weight: Double?
    let miles: Double?
}

struct WorkoutSet: Decodable {
    let id: Int
    let workoutExerciseId: Int
    let setNumber: Int
    let reps: Int?
    let weight: Double?
    let durationSec: Int?
    let heartRate: Int?
    let isCompleted: Int
    // Treadmill (Fitness 2026-11-11). Optional so older servers still decode.
    let speed: Double?
    let incline: Double?
    let distanceMi: Double?
    let completedAt: String?
}

struct WorkoutResult: Decodable {
    let completionPct: Int
    let caloriesEst: Int?
    let rank: String
    let durationSec: Int?
}

struct CompleteReply: Decodable {
    let score: WorkoutScore
}

struct WorkoutScore: Decodable {
    let completionPct: Int
    let caloriesEst: Int?
    let rank: String
    let durationSec: Int?
    let plannedSets: Int?
    let completedSets: Int?
}

struct WorkoutHistory: Decodable { let workouts: [WorkoutRow] }

// Muscles worked this week (/api/app/workouts/muscles). done = sets completed
// (secondary muscles count half), planned = sets still scheduled.

struct MuscleWeek: Decodable {
    let from: String?
    let to: String?
    let workouts: Int?
    let groups: [MuscleWeekGroup]?
}

struct MuscleWeekGroup: Decodable, Identifiable {
    let key: String?
    let label: String?
    let done: Double?
    let planned: Double?
    let last: String?              // YYYY-MM-DD
    let muscles: [MuscleWeekMuscle]?
    var id: String { key ?? label ?? "" }
}

struct MuscleWeekMuscle: Decodable, Identifiable {
    let key: String?
    let label: String?
    let done: Double?
    let planned: Double?
    var id: String { key ?? label ?? "" }
}

// Routines (/api/app/routines). Made on the website; the phone turns them on/off.

struct RoutineList: Decodable {
    let routines: [AppRoutine]?
    let aheadDays: Int?
}

struct AppRoutine: Decodable, Identifiable {
    let id: Int
    let name: String?
    let days: [Int]?               // 0 = Sunday ... 6 = Saturday
    let startTime: String?         // "HH:MM"
    let estDurationMin: Int?
    let notes: String?
    let isActive: Int?             // 0 / 1
    let nextDate: String?
    let exercises: [RoutineExercise]?
    let muscles: MuscleSummary?
}

struct RoutineExercise: Decodable {
    let exerciseId: Int?
    let exerciseName: String?
    let exerciseType: String?
    let targetSets: Int?
    let targetReps: Int?
    let targetDurationSec: Int?
    let targetDistanceMi: Double?
    let primaryMuscles: [String]?
    let secondaryMuscles: [String]?
}

// Blood pressure

struct BPCategory: Decodable {
    let key: String             // normal | elevated | stage1 | stage2 | crisis
    let label: String
    let rating: Int
}

struct BPRating: Decodable {
    let rating: Int
    let category: BPCategory
    let lines: [String]
    // Fuller read (Fitness 2026-11-11). Optional so older servers still decode.
    let meaning: BPMeaning?
    let driver: String?            // which number set the level
    let verdict: String?           // better | worse | same | mixed | first
    let headline: String?
    let vsLast: BPCompare?
    let vsAvg7: BPCompare?
    let tips: [String]?
}

/// What the category means: "Top 130-139 or bottom 80-89" + a plain sentence.
struct BPMeaning: Decodable {
    let range: String?
    let text: String?
    let label: String?
}

/// This reading against the last one or the 7-day average. systolic and
/// diastolic are the changes (negative = lower).
struct BPCompare: Decodable {
    let verdict: String?
    let systolic: Int?
    let diastolic: Int?
    let against: String?           // "132/84"
    let text: String?
}

struct BPReading: Decodable, Identifiable {
    let id: Int
    let takenAt: String
    let systolic: Int
    let diastolic: Int
    let pulse: Int?
    let note: String?
    let source: String
    let category: BPCategory
    let analysis: BPRating?

    var date: Date { LocalStamp.date(takenAt) ?? Date() }
}

struct BPAverage: Decodable {
    let systolic: Int?
    let diastolic: Int?
    let pulse: Int?
    let count: Int
    let category: BPCategory
}

struct BPGoal: Decodable {
    let systolic: Int
    let diastolic: Int
}

struct BPBrief: Decodable {
    let latest: BPReading?
    let week: BPAverage?
    let goal: BPGoal
    let insights: [String]
}

struct BPDay: Decodable, Identifiable {
    let date: String
    let systolic: Int
    let diastolic: Int
    let count: Int
    var id: String { date }
}

struct BPPeriod: Decodable {
    let insights: [String]
}

struct BPSummary: Decodable {
    let goal: BPGoal
    let latest: BPReading?
    let week: BPAverage?
    let weekAtGoal: Int
    let readings: [BPReading]
    let daily: [BPDay]
    let analysis: BPPeriod
}
