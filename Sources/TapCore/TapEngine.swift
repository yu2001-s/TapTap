import Foundation

/// Sensor → detector → gesture recognizer. Runs directly on the sensor's HID thread:
/// hopping queues for every sample (800/s) cost more CPU than the detector itself.
///
/// In low-power mode the sensor idles at ~100 Hz, accelerometer only. Receiving reports is
/// almost the whole CPU cost, so this cuts it about sixfold. A jolt at the idle rate (the
/// first tap of a gesture) switches to 800 Hz + gyroscope within ~10 ms, in time for the
/// second tap; the first tap counts toward the gesture but is not classified.
public final class TapEngine {
    /// Called on the main queue.
    public var onGesture: ((Gesture) -> Void)?
    /// Debug trace; called on the sensor thread.
    public var onTrace: ((Double, [Double]?, String) -> Void)?

    public let classifier: TapClassifier
    public private(set) var isRunning = false
    public var hasGyro: Bool { sensor?.hasGyro ?? false }

    /// Minimum tap strength in mg (lower = more sensitive).
    public var minPeak: Double {
        get { lock.lock(); defer { lock.unlock() }; return _minPeak }
        set { lock.lock(); _minPeak = newValue; lock.unlock() }
    }

    /// Idle at a low sample rate between gestures. Takes effect on the next `start()`.
    public var lowPower = true

    /// Sample-to-sample change at the idle rate (mg) that wakes full-rate sampling. A still
    /// chassis stays under ~3.5 mg at 100 Hz; every first tap in our recordings exceeded 4.
    public var wakeThreshold = 4.5
    /// Stay at full rate this long after the last tap before idling again. Taps in a gesture
    /// are at most `GestureRecognizer.maxGap` (0.35 s) apart; most wakes are stray knocks.
    public var activeHold = 0.5

    private var sensor: SPUSensor?
    private let lock = NSLock()
    private var _minPeak = 8.0

    public init(classifier: TapClassifier) {
        self.classifier = classifier
    }

    public func start() throws {
        guard !isRunning else { return }
        let recognizer = GestureRecognizer(classifier: classifier)
        recognizer.minPeak = minPeak
        recognizer.onGesture = { [weak self] g in DispatchQueue.main.async { self?.onGesture?(g) } }
        recognizer.onTrace = { [weak self] t, p, v in self?.onTrace?(t, p, v) }

        let sensor = SPUSensor(rate: lowPower ? .idle : .full)
        let pipeline = TapPipeline(recognizer: recognizer, lowPower: lowPower,
                                   wakeThreshold: wakeThreshold, activeHold: activeHold,
                                   setRate: { sensor.setRate($0) },
                                   inputAges: { _ in sensor.inputAges() })
        pipeline.onTrace = { [weak self] t, v in self?.onTrace?(t, nil, v) }
        sensor.onSample = { [weak self] s in
            guard let self else { return }
            recognizer.minPeak = self.minPeak
            pipeline.feed(s)
        }
        try sensor.start()
        self.sensor = sensor
        isRunning = true
    }

    public func stop() {
        sensor?.stop()
        sensor = nil
        isRunning = false
    }
}

/// Idle/full-rate switching around a detector and recognizer. Used live by `TapEngine`
/// (on the sensor thread) and by `taptap eval --low-power` to replay recordings.
public final class TapPipeline {
    public var onTrace: ((Double, String) -> Void)?
    public private(set) var isIdle: Bool

    private let setRate: (SPUSensor.Rate) -> Void
    private let inputAges: (IMUSample) -> (key: Double, click: Double)
    private let recognizer: GestureRecognizer
    private let lowPower: Bool
    private let wakeThreshold: Double
    private let activeHold: Double

    private var detector: TapDetector?
    private var gyroBias: SIMD3<Double>?
    private var activeUntil = 0.0
    private var lastIdle: SIMD3<Double>?
    /// Recent idle-rate jolts (~0.3 s): a tap is a spike above this background, while
    /// speakers playing music or a vibrating desk raise it and should not wake us.
    private var background = [Double](repeating: 0, count: 30)
    private var backgroundIndex = 0
    private var backgroundSum = 0.0
    private let wakeRatio = 3.0

    public init(recognizer: GestureRecognizer, lowPower: Bool, wakeThreshold: Double = 4.5, activeHold: Double = 0.5,
                setRate: @escaping (SPUSensor.Rate) -> Void = { _ in },
                inputAges: @escaping (IMUSample) -> (key: Double, click: Double) = { ($0.keyAge, $0.clickAge) }) {
        self.setRate = setRate
        self.inputAges = inputAges
        self.recognizer = recognizer
        isIdle = lowPower
        self.lowPower = lowPower
        self.wakeThreshold = wakeThreshold
        self.activeHold = activeHold
        if !lowPower { detector = makeDetector() }
    }

    public func feed(_ s: IMUSample) {
        guard let detector else { return idle(s) }
        detector.feed(s)
        recognizer.tick(now: detector.now, moving: detector.isMoving)
        if lowPower, s.t > activeUntil, !recognizer.hasPendingGroup {
            gyroBias = detector.gyroBias
            self.detector = nil
            lastIdle = nil
            isIdle = true
            setRate(.idle)
            onTrace?(s.t, "idle")
        }
    }

    private func idle(_ s: IMUSample) {
        recognizer.tick(now: s.t, moving: false)
        defer { lastIdle = s.a }
        guard let prev = lastIdle else { return }
        let d = s.a - prev
        let jolt = (d * d).sum().squareRoot() * 1000
        let level = backgroundSum / Double(background.count)
        backgroundSum += jolt - background[backgroundIndex]
        background[backgroundIndex] = jolt
        backgroundIndex = (backgroundIndex + 1) % background.count
        // Typing and clicking shake the chassis constantly and never start a gesture.
        guard jolt > wakeThreshold, jolt > wakeRatio * (level + 0.5) else { return }
        let ages = inputAges(s)
        guard ages.key >= recognizer.keyQuiet, ages.click >= recognizer.clickQuiet else { return }

        isIdle = false
        setRate(.full)
        detector = makeDetector()
        activeUntil = s.t + activeHold
        onTrace?(s.t, String(format: "wake (%.0f mg)", jolt))
        recognizer.handlePreTap(at: s.t, keyAge: ages.key, clickAge: ages.click)
    }

    private func makeDetector() -> TapDetector {
        let d = TapDetector(gyroBias: gyroBias)
        d.onTap = { [unowned self] tap in
            // Only impulses that could be part of a gesture keep us at full rate; typing,
            // clicking and moving the laptop would otherwise never let it idle.
            if tap.keyAge >= self.recognizer.keyQuiet, tap.clickAge >= self.recognizer.clickQuiet, !tap.recentMotion {
                self.activeUntil = max(self.activeUntil, tap.t + self.activeHold)
            }
            self.recognizer.handle(tap)
        }
        return d
    }
}
