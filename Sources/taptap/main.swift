import Foundation
import TapCore

let usage = """
usage:
  taptap live    [--model model/tapmodel.json] [--min-peak 8] [--verbose]
  taptap collect [--protocol taps|gestures] [--surface NAME] [--note TEXT] [--only a,b]
  taptap extract <session-dir>                 write per-tap features to <session-dir>/events_swift.csv
  taptap eval    <session-dir> [--model PATH] [--min-peak 8] [--verbose]   run the full pipeline on every recording
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let verbose = args.contains("--verbose")
let modelPath = option("--model") ?? "model/tapmodel.json"
let minPeak = option("--min-peak").flatMap(Double.init) ?? 8
var positional: [String] {
    var out: [String] = [], skip = false
    for a in args {
        if skip { skip = false; continue }
        if a == "--verbose" || a == "--trace" { continue }
        if a.hasPrefix("--") { skip = true; continue }
        out.append(a)
    }
    return out
}

func loadModel() -> TapClassifier {
    do { return try TapClassifier.load(modelPath) } catch {
        print("cannot load model at \(modelPath): \(error)"); exit(1)
    }
}

func describe(_ g: Gesture) -> String {
    let place = ["mac_left": "Mac left", "mac_right": "Mac right", "desk": "Desk"][g.location.rawValue]!
    return "\(place) \(g.count == 2 ? "double tap" : "triple tap")  (\(Int(g.confidence * 100))%)"
}

func recordings(in dir: String) -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return files.filter { $0.hasSuffix(".csv") && !$0.hasPrefix("events") }.sorted()
}

switch command {
case "live":
    let model = loadModel()
    let engine = TapEngine(classifier: model)
    engine.minPeak = minPeak
    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss.SSS"
    engine.onGesture = { g in print("\(clock.string(from: Date()))  ▶ \(describe(g))"); fflush(stdout) }
    if verbose {
        engine.onTrace = { t, p, verdict in
            let probs = p.map { zip(model.classes, $0).map { "\($0)=\(Int($1 * 100))" }.joined(separator: " ") } ?? ""
            print(String(format: "  %8.3f  %@  %@", t, verdict, probs)); fflush(stdout)
        }
    }
    do { try engine.start() } catch { print(error); exit(1) }
    print("TapTap listening (\(hardwareModel()), gyro \(engine.hasGyro ? "on" : "off")). Double/triple-tap the left or right palm rest. Ctrl-C to quit.")
    fflush(stdout)
    dispatchMain()

case "extract":
    guard let dir = positional.first else { print(usage); exit(2) }
    var out = "file,t,in_motion,key_age,click_age," + TapDetector.featureNames.joined(separator: ",") + "\n"
    for file in recordings(in: dir) {
        let label = String(file.dropLast(4))
        let samples = try Recording.load("\(dir)/\(file)")
        let detector = TapDetector()
        var events: [TapEvent] = []
        var moving: [Double] = []           // timestamps of samples flagged as motion
        detector.onTap = { events.append($0) }
        for s in samples {
            detector.feed(s)
            if detector.isMoving { moving.append(s.t) }
        }
        // Offline label: any motion within ±300 ms of onset (live mode can only look back).
        var nMove = 0
        for e in events {
            let lo = e.t - 0.3, hi = e.t + 0.3
            var a = 0, b = moving.count
            while a < b { let m = (a + b) / 2; if moving[m] < lo { a = m + 1 } else { b = m } }
            let inMotion = a < moving.count && moving[a] <= hi
            if inMotion { nMove += 1 }
            out += "\(label),\(e.t),\(inMotion ? "True" : "False"),\(e.keyAge),\(e.clickAge),"
            out += e.features.map { String($0) }.joined(separator: ",") + "\n"
        }
        print(label.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: "%5.1fs  taps=%3d  in_motion=%3d", samples.last?.t ?? 0, events.count, nMove))
    }
    try out.write(toFile: "\(dir)/events_swift.csv", atomically: true, encoding: .utf8)
    print("wrote \(dir)/events_swift.csv")

case "eval":
    guard let dir = positional.first else { print(usage); exit(2) }
    let model = loadModel()
    let locs: [TapLocation] = [.macLeft, .macRight]
    print("file              expected      " + locs.flatMap { l in [2, 3].map { "\(l.rawValue)×\($0)" } }.map { $0.padding(toLength: 12, withPad: " ", startingAt: 0) }.joined())
    for file in recordings(in: dir) {
        let label = String(file.dropLast(4))
        let detector = TapDetector()
        let recognizer = GestureRecognizer(classifier: model)
        recognizer.minPeak = minPeak
        var counts = [String: Int]()
        detector.onTap = { recognizer.handle($0) }
        if args.contains("--trace") {
            recognizer.onTrace = { t, p, verdict in
                if verdict.hasPrefix("tap #") { return }
                let probs = p.map { zip(model.classes, $0).map { "\($0)=\(Int($1 * 100))" }.joined(separator: " ") } ?? ""
                print(String(format: "    %@ %7.2fs  %@  %@", label as NSString, t, verdict, probs))
            }
        }
        recognizer.onGesture = { g in
            counts["\(g.location.rawValue)×\(g.count)", default: 0] += 1
            if verbose { print(String(format: "    %@ %7.2fs  %@", label as NSString, g.t, describe(g))) }
        }
        for s in try Recording.load("\(dir)/\(file)") {
            detector.feed(s)
            recognizer.tick(now: detector.now, moving: detector.isMoving)
        }
        recognizer.tick(now: .infinity, moving: false)
        var expected = "-"
        if let r = label.range(of: #"_x[23]$"#, options: .regularExpression) {
            expected = "\(label[..<r.lowerBound])×\(label.last!)"
        }
        let row = locs.flatMap { l in [2, 3].map { counts["\(l.rawValue)×\($0)"] ?? 0 } }
        print(label.padding(toLength: 18, withPad: " ", startingAt: 0) + expected.padding(toLength: 14, withPad: " ", startingAt: 0)
              + row.map { String($0).padding(toLength: 12, withPad: " ", startingAt: 0) }.joined())
    }

case "collect":
    runCollect(protocolName: option("--protocol") ?? "gestures", surface: option("--surface") ?? "unknown",
               note: option("--note") ?? "", only: option("--only").map { Set($0.split(separator: ",").map(String.init)) })

default:
    print(usage); exit(2)
}
