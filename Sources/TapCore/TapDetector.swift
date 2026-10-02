import Foundation

/// An impulse found in the IMU stream, with features over the 60 ms after onset.
public struct TapEvent {
    public let t: Double
    public let features: [Double]        // ordered as TapDetector.featureNames
    public let keyAge: Double
    public let clickAge: Double
    /// Chassis was being moved between 300 ms before onset and the end of the feature window.
    public let recentMotion: Bool

    public func feature(_ name: String) -> Double {
        features[TapDetector.featureNames.firstIndex(of: name)!]
    }
}

/// Streaming, causal tap detector for ~800 Hz SPU accelerometer data.
///
/// Onset: jerk RMS (8 ms) suddenly ≥ 2.2× its mean over the window 15–80 ms earlier.
/// That ratio still fires when taps land inside the previous tap's ~300 ms ringing.
/// Motion: 150 ms mean of |gyro − bias| > 4 dps. Taps never sustain that; moving the laptop does.
public final class TapDetector {
    public static let fs = 800.0
    public static let featureNames = [
        "peak_mg", "jerk_mg", "rise_ms", "width_ms", "ex", "ey", "ez",
        "gyro_peak", "centroid_hz", "gyro_per_g",
        "ax_att", "ax_pk", "ay_att", "ay_pk", "az_att", "az_pk",
        "gx_att", "gx_pk", "gy_att", "gy_pk", "gz_att", "gz_pk",
        "anx_att", "any_att", "anz_att", "gnx_att", "gny_att", "gnz_att",
    ]

    public var onTap: ((TapEvent) -> Void)?
    public private(set) var isMoving = false
    public private(set) var lastMotionTime = -Double.infinity
    public private(set) var now = 0.0

    // Tunables
    let envFloor = 1.0          // mg/sample; ignore anything quieter
    let scoreThreshold = 2.2
    let minPeakGap = 96         // samples (120 ms)
    let motionDps = 4.0

    // Window geometry, in samples
    let envLen = 6, prevFrom = 13, prevTo = 64
    let preFrom = 80, preTo = 12          // baseline: 100–15 ms before onset
    let winLen = 48, attLen = 20          // 60 ms window, 25 ms attack
    let motionLen = 120                   // 150 ms

    private static let size = 512
    private var time = [Double](repeating: 0, count: size)
    private var acc = [SIMD3<Double>](repeating: .zero, count: size)
    private var gyr = [SIMD3<Double>](repeating: .zero, count: size)
    private var jerk = [Double](repeating: 0, count: size)
    private var env = [Double](repeating: 0, count: size)
    private var score = [Double](repeating: 0, count: size)
    private var keyAge = [Double](repeating: 99, count: size)
    private var clickAge = [Double](repeating: 99, count: size)
    private var gdev = [Double](repeating: 0, count: size)
    private var n = 0

    private var gyroBias = SIMD3<Double>(repeating: 0)
    private var gdevSum = 0.0
    private var candPeak = -1, candStart = 0, lastPeak = -10_000
    private var pending: [Int] = []

    public init() {}

    @inline(__always) private func r(_ k: Int) -> Int { k & (Self.size - 1) }

    public func feed(_ s: IMUSample) {
        let i = r(n)
        now = s.t
        time[i] = s.t; acc[i] = s.a; gyr[i] = s.g; keyAge[i] = s.keyAge; clickAge[i] = s.clickAge
        jerk[i] = n > 0 ? length(s.a - acc[r(n - 1)]) * 1000 : 0

        var sq = 0.0
        let m = min(envLen, n + 1)
        for k in 0..<m { let j = jerk[r(n - k)]; sq += j * j }
        env[i] = (sq / Double(m)).squareRoot()

        if n >= prevTo {
            var p = 0.0
            for k in prevFrom...prevTo { p += env[r(n - k)] }
            score[i] = env[i] / (p / Double(prevTo - prevFrom + 1) + 0.3)
        } else {
            score[i] = 0
        }

        updateMotion(s)
        pickPeaks()

        while let o = pending.first, n >= o + winLen - 1 {
            pending.removeFirst()
            emit(onset: o)
        }
        n += 1
    }

    private func updateMotion(_ s: IMUSample) {
        let i = r(n)
        if n == 0 { gyroBias = s.g }
        let d = length(s.g - gyroBias)
        if d < 2.0 { gyroBias += 0.002 * (s.g - gyroBias) }
        gdev[i] = d
        gdevSum += d
        if n >= motionLen { gdevSum -= gdev[r(n - motionLen)] }
        isMoving = n >= motionLen && gdevSum / Double(motionLen) > motionDps
        if isMoving { lastMotionTime = s.t }
    }

    private func pickPeaks() {
        let i = r(n)
        if candPeak >= 0 {
            if score[i] > score[r(candPeak)] && env[i] > envFloor { candPeak = n }
            if n - candStart >= 8 {
                finalize(peak: candPeak)
                candPeak = -1
            }
        } else if n >= preFrom + 40, env[i] > envFloor, score[i] > scoreThreshold, n - lastPeak >= minPeakGap {
            candPeak = n
            candStart = n
        }
    }

    private func finalize(peak p: Int) {
        lastPeak = p
        var o = p
        let level = 0.25 * env[r(p)]
        while o > p - 16 && jerk[r(o - 1)] > level { o -= 1 }
        pending.append(o)
    }

    private func emit(onset o: Int) {
        let t = time[r(o)]
        let ev = TapEvent(
            t: t,
            features: features(onset: o),
            keyAge: keyAge[r(o)],
            clickAge: clickAge[r(o)],
            recentMotion: lastMotionTime >= t - 0.3
        )
        onTap?(ev)
    }

    private func features(onset o: Int) -> [Double] {
        var b = SIMD3<Double>(repeating: 0), gb = SIMD3<Double>(repeating: 0)
        for k in (o - preFrom)..<(o - preTo) { b += acc[r(k)]; gb += gyr[r(k)] }
        let npre = Double(preFrom - preTo)
        b /= npre; gb /= npre

        var A = [SIMD3<Double>](), G = [SIMD3<Double>](), mag = [Double]()
        var jerkMax = 0.0
        for k in 0..<winLen {
            let a = (acc[r(o + k)] - b) * 1000
            A.append(a); G.append(gyr[r(o + k)] - gb); mag.append(length(a))
            jerkMax = max(jerkMax, jerk[r(o + k)])
        }
        let peak = mag.max()!
        let pk = mag.firstIndex(of: peak)!
        let width = Double(mag.filter { $0 > 0.3 * peak }.count) / Self.fs * 1000
        var e = SIMD3<Double>(repeating: 0)
        for a in A { e += a * a }
        let ef = e / max(e.sum(), 1e-12)
        let gyroPeak = G.map(length).max()!

        // Spectral centroid of |a|, 64-point DFT of the zero-padded 48-sample window.
        let mean = mag.reduce(0, +) / Double(winLen)
        var num = 0.0, den = 0.0
        for f in 0...32 {
            var re = 0.0, im = 0.0
            for k in 0..<winLen {
                let ph = 2 * Double.pi * Double(f * k) / 64
                re += (mag[k] - mean) * cos(ph); im -= (mag[k] - mean) * sin(ph)
            }
            let amp = (re * re + im * im).squareRoot()
            num += amp * Double(f) * Self.fs / 64; den += amp
        }
        let centroid = num / max(den, 1e-9)

        var out: [Double] = [peak, jerkMax, Double(pk) / Self.fs * 1000, width, ef.x, ef.y, ef.z,
                             gyroPeak, centroid, gyroPeak / max(peak, 1e-6) * 1000]
        let wt = (0..<attLen).map { exp(-Double($0) / 9) }
        let wsum = wt.reduce(0, +)
        for series in [A, G] {
            for axis in 0..<3 {
                var att = 0.0
                for k in 0..<attLen { att += series[k][axis] * wt[k] }
                let pkv = series.max { abs($0[axis]) < abs($1[axis]) }![axis]
                out.append(att / wsum)
                out.append(pkv)
            }
        }
        // Attack direction normalized by tap strength, so light and hard taps on one side look alike.
        let att = [out[10], out[12], out[14], out[16], out[18], out[20]]
        out += att[0..<3].map { $0 / max(peak, 1e-6) }
        out += att[3..<6].map { $0 / max(peak, 1e-6) * 100 }
        return out
    }
}

@inline(__always) func length(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }
