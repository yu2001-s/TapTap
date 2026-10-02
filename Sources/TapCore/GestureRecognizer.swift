import Foundation

public enum TapLocation: String, CaseIterable {
    case macLeft = "mac_left"
    case macRight = "mac_right"
    case desk = "desk"
}

public struct Gesture {
    public let location: TapLocation
    public let count: Int               // 2 or 3
    public let t: Double                // onset of the first tap
    /// Mac gestures: P(mac_left) + P(mac_right), averaged over the group. Desk: P(desk).
    public let confidence: Double
    /// Mac gestures: share of the Mac probability on the chosen side (0.5 = coin flip).
    /// Telling left from right is much less reliable than telling "tapped the Mac" from
    /// everything else, so callers decide how much side certainty they need.
    public let sideConfidence: Double
}

/// Groups classified taps into double/triple gestures.
///
/// Taps closer than `maxGap` form a group. A third tap emits a triple immediately;
/// otherwise the group is emitted as a double once `maxGap` passes with no new tap.
/// Single taps are dropped — that is what keeps bumps and set-down cups from triggering.
/// The location is the argmax of the class probabilities averaged over the group.
public final class GestureRecognizer {
    public var maxGap = 0.35
    public var keyQuiet = 0.45          // MacTap uses 0.45 s after a key press
    public var clickQuiet = 0.30
    public var minConfidence = 0.45
    /// Minimum P(mac_left) + P(mac_right) for a Mac gesture.
    public var minMacConfidence = 0.6
    /// Score triples by their two most Mac-like taps.
    public var trimTriples = true
    /// Deliberate taps in one gesture are similar in strength; a crash plus its rattle is not.
    public var maxPeakRatio = 8.0
    /// Locations that produce gestures. The classifier still knows "desk" so desk knocks are
    /// rejected instead of being forced into left/right.
    public var enabledLocations: Set<TapLocation> = [.macLeft, .macRight]
    /// Weaker impulses never count as taps. MacTap uses ~21–23 mg, but deliberate double/triple taps
    /// are much lighter (right palm rest often 7–15 mg), so this stays low.
    public var minPeak = 8.0
    /// MacTap-style burst lockout: `burstCount` impulses within `burstWindow` (a hand rubbing the
    /// palm rest, a rattle) blocks taps for `burstLockout`. Impulses below `burstMinPeak` are not counted.
    public var burstCount = 4
    public var burstWindow = 0.5
    public var burstLockout = 0.4
    public var burstMinPeak = 8.0
    /// After a double tap the finger lifting or the hand rebounding often adds a much weaker
    /// impulse; taps below this fraction of the group's strongest tap are not counted.
    public var minRelativePeak = 0.35

    public var onGesture: ((Gesture) -> Void)?
    /// Debug trace: (tap time, probabilities or nil, verdict).
    public var onTrace: ((Double, [Double]?, String) -> Void)?

    private let classifier: TapClassifier
    private var group: [(t: Double, p: [Double], peak: Double)] = []
    private var impulses: [Double] = []
    private var lockedUntil = -Double.infinity

    public init(classifier: TapClassifier) {
        self.classifier = classifier
    }

    public func handle(_ tap: TapEvent) {
        let peak = tap.feature("peak_mg")
        // Count impulses even while locked, so continuous rubbing keeps extending the lockout.
        if peak >= burstMinPeak {
            impulses.append(tap.t)
            impulses.removeAll { tap.t - $0 > burstWindow }
            if impulses.count >= burstCount {
                lockedUntil = max(lockedUntil, tap.t + burstLockout)
                impulses.removeAll()
            }
        }
        if tap.t < lockedUntil {
            cancel(at: tap.t, reason: "burst")
            return
        }
        if tap.keyAge < keyQuiet || tap.clickAge < clickQuiet {
            cancel(at: tap.t, reason: tap.keyAge < keyQuiet ? "typing" : "click")
            return
        }
        if tap.recentMotion {
            cancel(at: tap.t, reason: "motion")
            return
        }
        if peak < minPeak {
            onTrace?(tap.t, nil, String(format: "too weak (%.0f mg)", peak))
            return
        }
        if let last = group.last, tap.t - last.t > maxGap { flush() }
        if let strongest = group.map(\.peak).max(), peak < minRelativePeak * strongest {
            onTrace?(tap.t, nil, String(format: "rebound (%.0f mg vs %.0f mg)", peak, strongest))
            return
        }

        let p = classifier.probabilities(tap.features)
        group.append((tap.t, p, peak))
        onTrace?(tap.t, p, String(format: "tap #%d %.0f mg", group.count, peak))
        if group.count == 3 { flush() }
    }

    /// Call regularly (every sample is fine) with the detector's clock and motion state.
    public func tick(now: Double, moving: Bool) {
        guard let last = group.last else { return }
        if moving {
            cancel(at: now, reason: "motion")
        } else if now - last.t > maxGap {
            flush()
        }
    }

    private func cancel(at t: Double, reason: String) {
        onTrace?(t, nil, group.isEmpty ? "ignored (\(reason))" : "ignored, group of \(group.count) dropped (\(reason))")
        group.removeAll()
    }

    private func flush() {
        defer { group.removeAll() }
        guard group.count >= 2 else { return }
        let peaks = group.map(\.peak)
        if peaks.max()! / max(peaks.min()!, 1e-6) > maxPeakRatio {
            onTrace?(group.last!.t, nil, "group of \(group.count) rejected (uneven strength)")
            return
        }
        let iL = classifier.classes.firstIndex(of: TapLocation.macLeft.rawValue)
        let iR = classifier.classes.firstIndex(of: TapLocation.macRight.rawValue)
        func macProb(_ p: [Double]) -> Double { (iL.map { p[$0] } ?? 0) + (iR.map { p[$0] } ?? 0) }
        // The first tap of a triple lands on a still chassis, the others in the previous tap's
        // ringing, and it is often the odd one out (looks like a desk knock). Score a triple
        // by its two most Mac-like taps; doubles have no tap to spare.
        var voters = group.map(\.p)
        if trimTriples, voters.count == 3, let worst = voters.indices.min(by: { macProb(voters[$0]) < macProb(voters[$1]) }) {
            voters.remove(at: worst)
        }
        var mean = [Double](repeating: 0, count: classifier.classes.count)
        for v in voters { for c in 0..<mean.count { mean[c] += v[c] / Double(voters.count) } }
        func p(_ l: TapLocation) -> Double { classifier.classes.firstIndex(of: l.rawValue).map { mean[$0] } ?? 0 }
        let left = p(.macLeft), right = p(.macRight), mac = left + right
        let last = group.last!.t

        if mac >= minMacConfidence, enabledLocations.contains(.macLeft) || enabledLocations.contains(.macRight) {
            let loc: TapLocation = left >= right ? .macLeft : .macRight
            onGesture?(Gesture(location: loc, count: group.count, t: group[0].t,
                               confidence: mac, sideConfidence: max(left, right) / mac))
            return
        }
        let best = mean.indices.max { mean[$0] < mean[$1] }!
        if classifier.classes[best] == TapLocation.desk.rawValue, mean[best] >= minConfidence {
            guard enabledLocations.contains(.desk) else {
                onTrace?(last, mean, "group of \(group.count) ignored (desk disabled)")
                return
            }
            onGesture?(Gesture(location: .desk, count: group.count, t: group[0].t, confidence: mean[best], sideConfidence: 1))
            return
        }
        onTrace?(last, mean, "group of \(group.count) rejected (mac \(Int(mac * 100))%, \(classifier.classes[best]) \(Int(mean[best] * 100))%)")
    }
}
