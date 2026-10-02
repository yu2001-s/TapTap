import Foundation

/// Sensor → detector → gesture recognizer. Runs directly on the sensor's HID thread:
/// hopping queues for every sample (800/s) cost more CPU than the detector itself.
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

    private var sensor: SPUSensor?
    private let lock = NSLock()
    private var _minPeak = 8.0

    public init(classifier: TapClassifier) {
        self.classifier = classifier
    }

    public func start() throws {
        guard !isRunning else { return }
        // Fresh detector state each start: the sensor clock restarts at zero.
        let detector = TapDetector()
        let recognizer = GestureRecognizer(classifier: classifier)
        recognizer.minPeak = minPeak
        detector.onTap = { recognizer.handle($0) }
        recognizer.onGesture = { [weak self] g in DispatchQueue.main.async { self?.onGesture?(g) } }
        recognizer.onTrace = { [weak self] t, p, v in self?.onTrace?(t, p, v) }

        let sensor = SPUSensor()
        sensor.onSample = { [weak self] s in
            guard let self else { return }
            recognizer.minPeak = self.minPeak
            detector.feed(s)
            recognizer.tick(now: detector.now, moving: detector.isMoving)
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
