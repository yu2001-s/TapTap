import Foundation
import TapCore

struct Step {
    let label: String
    let instruction: String
    let target: String
}

let protocols: [String: [Step]] = [
    // Single taps per location plus negatives; used to train the per-tap classifier.
    "taps": [
        Step(label: "idle", instruction: "Keep your hands off the Mac and desk. Stay still for 30 seconds, then press Enter.", target: "30 seconds"),
        Step(label: "mac_left", instruction: "Single-tap the left palm rest. Wait at least 1 second between taps; mix light, medium, and firm taps.", target: "20 taps"),
        Step(label: "mac_right", instruction: "Single-tap the right palm rest. Wait at least 1 second between taps; mix light, medium, and firm taps.", target: "20 taps"),
        Step(label: "desk_left", instruction: "Single-tap the desk about 10 cm left of the Mac. Wait at least 1 second between taps; vary the strength.", target: "20 taps"),
        Step(label: "desk_right", instruction: "Single-tap the desk about 10 cm right of the Mac. Wait at least 1 second between taps; vary the strength.", target: "20 taps"),
        Step(label: "desk_front", instruction: "Single-tap the desk about 10 cm in front of the Mac. Wait at least 1 second between taps; vary the strength.", target: "20 taps"),
        Step(label: "desk_back", instruction: "Single-tap the desk behind the screen. Wait at least 1 second between taps; vary the strength.", target: "20 taps"),
        Step(label: "palm", instruction: "Rest your hands on the palm rest and adjust them naturally as you would before or after typing. Do not tap; continue for 30 seconds.", target: "30 seconds"),
        Step(label: "typing", instruction: "Type normally in this terminal for about 60 seconds, then press Enter.", target: "60 seconds"),
        Step(label: "trackpad", instruction: "Use the trackpad normally: click, scroll, and drag for about 30 seconds.", target: "30 seconds"),
        Step(label: "move", instruction: "Move the Mac: push it, rotate it, or lift and set it down. Wait 2 seconds between movements.", target: "10 repetitions"),
        Step(label: "bump", instruction: "Create everyday disturbances: set a cup or book on the desk, rest your hands on the palm rest, or bump the desk. Wait 2 seconds between actions.", target: "10 repetitions"),
    ],
    // Whole gestures; used to evaluate the end-to-end recognizer.
    "gestures": [
        Step(label: "mac_left_x2", instruction: "Double-tap the left palm rest. Wait at least 2 seconds between groups.", target: "10 groups"),
        Step(label: "mac_left_x3", instruction: "Triple-tap the left palm rest. Wait at least 2 seconds between groups.", target: "10 groups"),
        Step(label: "mac_right_x2", instruction: "Double-tap the right palm rest. Wait at least 2 seconds between groups.", target: "10 groups"),
        Step(label: "mac_right_x3", instruction: "Triple-tap the right palm rest. Wait at least 2 seconds between groups.", target: "10 groups"),
        Step(label: "desk", instruction: "Double- or triple-tap anywhere on the desk (these should not trigger). Wait at least 2 seconds between groups.", target: "15 groups"),
        Step(label: "single", instruction: "Single-tap the palm rest or desk. Wait at least 2 seconds between taps.", target: "15 repetitions"),
        Step(label: "palm", instruction: "Rest your hands on the palm rest and adjust them naturally as you would before or after typing. Do not tap; continue for 30 seconds.", target: "30 seconds"),
        Step(label: "typing", instruction: "Type normally in this terminal for about 30 seconds, then press Enter.", target: "30 seconds"),
        Step(label: "bump", instruction: "Create everyday disturbances: set a cup or book on the desk, rest your hands on the palm rest, or bump the desk. Wait 2 seconds between actions.", target: "10 repetitions"),
        Step(label: "move", instruction: "Move the Mac: push it, rotate it, or lift and set it down. Wait 2 seconds between movements.", target: "10 repetitions"),
    ],
]

final class SegmentRecorder {
    private let lock = NSLock()
    private var recording = false
    private var start = 0.0
    private var latest = 0.0
    private var rows: [IMUSample] = []

    func add(_ s: IMUSample) {
        lock.lock(); defer { lock.unlock() }
        latest = s.t
        guard recording else { return }
        var r = s
        r.t -= start
        rows.append(r)
    }
    func begin() {
        lock.lock(); rows.removeAll(keepingCapacity: true); start = latest; recording = true; lock.unlock()
    }
    /// Stops and drops the last `trimTail` seconds (the Enter key press).
    func end(trimTail: Double) -> [IMUSample] {
        lock.lock(); defer { lock.unlock() }
        recording = false
        let stop = (rows.last?.t ?? 0) - trimTail
        let out = rows.filter { $0.t <= stop }
        rows.removeAll()
        return out
    }
}

func prompt(_ s: String) -> String {
    print(s, terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "q"
}

func runCollect(protocolName: String, surface: String, note: String, only: Set<String>?) {
    guard let all = protocols[protocolName] else { print("unknown protocol \(protocolName)"); exit(2) }
    let steps = all.filter { only?.contains($0.label) ?? true }

    let sensor = SPUSensor()
    let rec = SegmentRecorder()
    sensor.onSample = { rec.add($0) }
    do { try sensor.start() } catch { print(error); exit(1) }

    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss"
    let session = fmt.string(from: Date())
    let dir = URL(fileURLWithPath: "experiments/data/\(session)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var segments: [[String: Any]] = []

    func saveSession() {
        let meta: [String: Any] = ["session": session, "protocol": protocolName, "model": hardwareModel(),
                                   "surface": surface, "note": note, "gyro": sensor.hasGyro, "segments": segments]
        let data = try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: dir.appendingPathComponent("session.json"))
    }

    DispatchQueue.global().async {
        print("""
        ── TapTap data collection (\(protocolName)) ──
        Mac \(hardwareModel()), gyro \(sensor.hasGyro ? "available" : "unavailable"), surface: \(surface)
        Output: \(dir.path)
        For each step: press Enter to prepare, start at the cue, then press Enter to finish.
        Recording starts 1 second after Enter; the last 0.6 seconds are discarded to exclude keypress vibrations.

        """)
        var i = 0
        var take = [String: Int]()
        while i < steps.count {
            let step = steps[i]
            print("[\(i + 1)/\(steps.count)] \(step.label)  Target: \(step.target)")
            print("    \(step.instruction)")
            let cmd = prompt("    Enter to start, s to skip, q to finish > ")
            if cmd == "q" { break }
            if cmd == "s" { i += 1; print(""); continue }

            print("    Get ready…", terminator: ""); fflush(stdout)
            Thread.sleep(forTimeInterval: 1.0)
            rec.begin()
            print("\u{7} Start! Press Enter when finished", terminator: ""); fflush(stdout)
            _ = readLine()
            let rows = rec.end(trimTail: 0.6)

            // Rough count from the real detector, for on-the-spot feedback.
            let det = TapDetector()
            var taps = 0
            det.onTap = { _ in taps += 1 }
            rows.forEach(det.feed)
            let dur = rows.last?.t ?? 0
            print(String(format: "    Recorded %.1f seconds at %.0f Hz; detected %d taps", dur, Double(rows.count) / max(dur, 1e-9), taps))
            if prompt("    Enter to keep, r to retry > ") == "r" { print(""); continue }

            let k = (take[step.label] ?? 0) + 1
            take[step.label] = k
            let file = k == 1 ? "\(step.label).csv" : "\(step.label)_\(k).csv"
            var csv = Recording.header + "\n"
            csv.reserveCapacity(rows.count * 80)
            for r in rows { csv += Recording.row(r) }
            try! csv.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            segments.append(["label": step.label, "file": file, "seconds": dur, "taps": taps, "target": step.target])
            saveSession()
            print("    Saved \(file)\n")
            i += 1
        }
        saveSession()
        print("Finished: \(segments.count) segments saved to \(dir.path)")
        exit(0)
    }
    dispatchMain()
}
