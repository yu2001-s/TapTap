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
    /// Called on the sensor's HID thread for every accelerometer report (~800 Hz); keep it cheap.
    public var onSample: ((IMUSample) -> Void)?
    public private(set) var hasGyro = false

    private var accel: IOHIDDevice?
    private var gyro: IOHIDDevice?
    private let lock = NSLock()
    private var latestGyro = SIMD3<Double>(repeating: 0)
    private var keyAge = 99.0
    private var clickAge = 99.0
    private let t0 = CFAbsoluteTimeGetCurrent()
    private var timers: [DispatchSourceTimer] = []
    private var runLoop: CFRunLoop?
    private var samplesSinceCheck = 0
    private let accelBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    private let gyroBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)

    public init() {}

    public func start() throws {
        Self.wake()
        guard let a = Self.open(usage: 3) else { throw SensorError.unavailable }
        accel = a
        gyro = Self.open(usage: 9)
        hasGyro = gyro != nil

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(a, accelBuf, 4096, { ctx, _, _, _, _, rep, len in
            guard let ctx, len == 22 else { return }
            Unmanaged<SPUSensor>.fromOpaque(ctx).takeUnretainedValue().handleAccel(spuReadXYZ(rep))
        }, ctx)
        if let g = gyro {
            IOHIDDeviceRegisterInputReportCallback(g, gyroBuf, 4096, { ctx, _, _, _, _, rep, len in
                guard let ctx, len == 22 else { return }
                Unmanaged<SPUSensor>.fromOpaque(ctx).takeUnretainedValue().handleGyro(spuReadXYZ(rep))
            }, ctx)
        }

        let devices = [a] + (gyro.map { [$0] } ?? [])
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            for d in devices {
                IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            }
            CFRunLoopRun()
        }
        thread.name = "TapTap.SPU"
        thread.qualityOfService = .userInteractive
        thread.start()

        // macOS parks the IMU (or drops it to ~100 Hz) when the chassis is still. Re-arm only
        // when the rate sags: poking every driver unconditionally costs several % CPU.
        let wake = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        wake.schedule(deadline: .now() + 0.5, repeating: 0.5)
        wake.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let n = self.samplesSinceCheck
            self.samplesSinceCheck = 0
            self.lock.unlock()
            if n < 225 { Self.wake() }          // < 450 Hz over the last 0.5 s
        }
        wake.resume()

        // Seconds since last key/click; needs no Input Monitoring permission.
        let input = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        input.schedule(deadline: .now(), repeating: 0.02, leeway: .milliseconds(5))
        input.setEventHandler { [weak self] in
            let k = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
            let c = min(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown),
                        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .rightMouseDown))
            guard let self else { return }
            self.lock.lock(); self.keyAge = k; self.clickAge = c; self.lock.unlock()
        }
        input.resume()
        timers = [wake, input]
    }

    public func stop() {
        timers.forEach { $0.cancel() }
        timers = []
        if let rl = runLoop { CFRunLoopStop(rl) }
        runLoop = nil
        for d in [accel, gyro].compactMap({ $0 }) { IOHIDDeviceClose(d, 0) }
        accel = nil
        gyro = nil
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

    static func wake() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            setProp(s, "SensorPropertyReportingState", 1)
            setProp(s, "SensorPropertyPowerState", 1)
            setProp(s, "ReportInterval", 8000)
            setProp(s, "ReportInterval", 1250)     // ~800 Hz
            IOObjectRelease(s)
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
