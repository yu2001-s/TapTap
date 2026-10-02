import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

/// One accelerometer report with the most recent gyro reading and input-activity ages.
public struct IMUSample {
    public var t: Double                 // seconds
    public var a: SIMD3<Double>          // g
    public var g: SIMD3<Double>          // deg/s
    public var keyAge: Double            // seconds since last key down
    public var clickAge: Double          // seconds since last mouse/trackpad click

    public init(t: Double, a: SIMD3<Double>, g: SIMD3<Double>, keyAge: Double = 99, clickAge: Double = 99) {
        self.t = t; self.a = a; self.g = g; self.keyAge = keyAge; self.clickAge = clickAge
    }
}

public enum SensorError: Error, CustomStringConvertible {
    case unavailable
    public var description: String { "this Mac does not expose the SPU accelerometer" }
}

/// Undocumented Bosch IMU behind AppleSPUHIDDevice (vendor page 0xFF00; usage 3 = accel, 9 = gyro).
/// Reports are 22 bytes; x/y/z are little-endian Int32 at offsets 6/10/14, scaled by 1/65536.
public final class SPUSensor {
    public enum Rate: Equatable {
        /// Accelerometer + gyroscope at ~800 Hz: needed to classify a tap.
        case full
        /// Accelerometer only at ~100 Hz: enough to notice that something hit the chassis,
        /// at about a sixth of the CPU cost (receiving each report is the dominant cost).
        case idle
    }

    /// Called on the sensor's HID thread for every accelerometer report; keep it cheap.
    public var onSample: ((IMUSample) -> Void)?
    public private(set) var hasGyro = false
    /// Current rate. Change it with `setRate(_:)` from `onSample` (the sensor thread).
    public private(set) var rate: Rate

    private var accel: IOHIDDevice?
    private var gyro: IOHIDDevice?
    private var gyroOpen = false
    private let lock = NSLock()
    private var latestGyro = SIMD3<Double>(repeating: 0)
    private var keyAge = 99.0
    private var clickAge = 99.0
    private let t0 = CFAbsoluteTimeGetCurrent()
    private var timers: [DispatchSourceTimer] = []
    private var inputTimer: DispatchSourceTimer?
    private var inputPolling = false
    private var runLoop: CFRunLoop?
    private var samplesSinceCheck = 0
    private var lockedRate: Rate
    private let accelBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    private let gyroBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)

    public init(rate: Rate = .full) {
        self.rate = rate
        lockedRate = rate
    }

    public func start() throws {
        Self.configureDrivers(for: rate)
        guard let a = Self.open(usage: 3) else { throw SensorError.unavailable }
        accel = a
        if let s = Self.findService(usage: 9) {
            gyro = IOHIDDeviceCreate(nil, s)
            IOObjectRelease(s)
        }
        hasGyro = gyro != nil

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(a, accelBuf, 4096, { ctx, _, _, _, _, rep, len in
            guard let ctx, len == 22 else { return }
            Unmanaged<SPUSensor>.fromOpaque(ctx).takeUnretainedValue().handleAccel(spuReadXYZ(rep))
        }, ctx)

        let thread = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            IOHIDDeviceScheduleWithRunLoop(a, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            if self.rate == .full { self.openGyro() }
            CFRunLoopRun()
        }
        thread.name = "TapTap.SPU"
        thread.qualityOfService = .userInteractive
        thread.start()

        // macOS parks the IMU (or drops its rate) when the chassis is still. Re-arm only when
        // the rate sags below about half the target: poking the drivers unconditionally is costly.
        let wake = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        wake.schedule(deadline: .now() + 0.5, repeating: 0.5)
        wake.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let n = self.samplesSinceCheck
            let rate = self.lockedRate
            self.samplesSinceCheck = 0
            self.lock.unlock()
            if n < (rate == .full ? 225 : 25) { Self.configureDrivers(for: rate) }
        }
        wake.resume()

        // Seconds since last key/click, polled only at full rate: each poll is three IPCs to
        // the window server, which at idle would cost more than the sensor itself. At idle
        // the pipeline asks `inputAges()` once, when a jolt might start a gesture.
        let input = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        input.schedule(deadline: .now(), repeating: 0.02, leeway: .milliseconds(5))
        input.setEventHandler { [weak self] in self?.refreshInputAges() }
        inputTimer = input
        timers = [wake]
        setInputPolling(rate == .full)
    }

    /// Seconds since the last key press and mouse/trackpad click, queried now.
    @discardableResult
    public func inputAges() -> (key: Double, click: Double) {
        refreshInputAges()
        lock.lock(); defer { lock.unlock() }
        return (keyAge, clickAge)
    }

    private func refreshInputAges() {
        let k = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let c = min(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown),
                    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .rightMouseDown))
        lock.lock(); keyAge = k; clickAge = c; lock.unlock()
    }

    private func setInputPolling(_ on: Bool) {
        guard let t = inputTimer, on != inputPolling else { return }
        inputPolling = on
        if on { refreshInputAges(); t.resume() } else { t.suspend() }
    }

    /// Switches between full and idle rate. Call on the sensor thread (from `onSample`).
    /// Going to full rate takes ~10 ms for the accelerometer and gyroscope to reach 800 Hz.
    public func setRate(_ new: Rate) {
        guard new != rate else { return }
        rate = new
        lock.lock(); lockedRate = new; samplesSinceCheck = 0; lock.unlock()
        Self.configureDrivers(for: new)
        if new == .full { openGyro() } else { closeGyro() }
        setInputPolling(new == .full)
    }

    public func stop() {
        timers.forEach { $0.cancel() }
        timers = []
        setInputPolling(true)          // a suspended dispatch source must be resumed before cancel
        inputTimer?.cancel()
        inputTimer = nil
        if let rl = runLoop { CFRunLoopStop(rl) }
        runLoop = nil
        if let a = accel { IOHIDDeviceClose(a, 0) }
        if gyroOpen, let g = gyro { IOHIDDeviceClose(g, 0) }
        gyroOpen = false
        accel = nil
        gyro = nil
    }

    // The gyroscope is only opened at full rate: a closed device delivers no reports.
    private func openGyro() {
        guard let g = gyro, !gyroOpen, IOHIDDeviceOpen(g, 0) == kIOReturnSuccess else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(g, gyroBuf, 4096, { ctx, _, _, _, _, rep, len in
            guard let ctx, len == 22 else { return }
            Unmanaged<SPUSensor>.fromOpaque(ctx).takeUnretainedValue().handleGyro(spuReadXYZ(rep))
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(g, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        gyroOpen = true
    }

    private func closeGyro() {
        guard let g = gyro, gyroOpen else { return }
        IOHIDDeviceUnscheduleFromRunLoop(g, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(g, 0)
        gyroOpen = false
    }

    private func handleGyro(_ g: SIMD3<Double>) {
        lock.lock(); latestGyro = g; lock.unlock()
    }

    private func handleAccel(_ a: SIMD3<Double>) {
        lock.lock()
        let s = IMUSample(t: CFAbsoluteTimeGetCurrent() - t0, a: a, g: latestGyro, keyAge: keyAge, clickAge: clickAge)
        samplesSinceCheck += 1
        lock.unlock()
        onSample?(s)
    }

    // MARK: - IORegistry

    public static var isAvailable: Bool {
        guard let s = findService(usage: 3) else { return false }
        IOObjectRelease(s)
        return true
    }

    /// Sets the accelerometer (and at full rate, gyroscope) drivers' reporting rate. Only
    /// these two drivers are touched; the SPU also hosts ambient light, lid angle and others.
    static func configureDrivers(for rate: Rate) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let product = IORegistryEntryCreateCFProperty(s, "Product" as CFString, nil, 0)?.takeRetainedValue() as? String
            guard product == "accel" || (product == "gyro" && rate == .full) else { continue }
            setProp(s, "SensorPropertyReportingState", 1)
            setProp(s, "SensorPropertyPowerState", 1)
            if rate == .full {
                setProp(s, "ReportInterval", 8000)     // wakes a parked sensor
                setProp(s, "ReportInterval", 1250)     // ~800 Hz
            } else {
                setProp(s, "ReportInterval", 10000)    // ~100 Hz
            }
        }
    }

    private static func setProp(_ s: io_service_t, _ k: String, _ v: Int32) {
        var x = v
        IORegistryEntrySetCFProperty(s, k as CFString, CFNumberCreate(nil, .sInt32Type, &x))
    }

    private static func intProp(_ s: io_service_t, _ k: String) -> Int? {
        IORegistryEntryCreateCFProperty(s, k as CFString, nil, 0)?.takeRetainedValue() as? Int
    }

    private static func findService(usage: Int) -> io_service_t? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            if intProp(s, "PrimaryUsagePage") == 0xFF00, intProp(s, "PrimaryUsage") == usage, intProp(s, "MaxInputReportSize") == 22 {
                return s
            }
            IOObjectRelease(s)
        }
        return nil
    }

    private static func open(usage: Int) -> IOHIDDevice? {
        guard let s = findService(usage: usage) else { return nil }
        defer { IOObjectRelease(s) }
        guard let dev = IOHIDDeviceCreate(nil, s), IOHIDDeviceOpen(dev, 0) == kIOReturnSuccess else { return nil }
        return dev
    }
}

private func spuReadXYZ(_ rep: UnsafePointer<UInt8>) -> SIMD3<Double> {
    func rd(_ o: Int) -> Double {
        let u = UInt32(rep[o]) | UInt32(rep[o + 1]) << 8 | UInt32(rep[o + 2]) << 16 | UInt32(rep[o + 3]) << 24
        return Double(Int32(bitPattern: u)) / 65536
    }
    return SIMD3(rd(6), rd(10), rd(14))
}

public func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
}
