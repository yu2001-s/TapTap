import Foundation

/// Per-tap location classifier exported from experiments/analysis/train.py.
/// Supports a random forest ("forest") or a standardized logistic regression ("logistic").
public struct TapClassifier: Decodable {
    public let type: String
    public let classes: [String]
    public let features: [String]

    // logistic
    let mean: [Double]?
    let scale: [Double]?
    let coef: [[Double]]?
    let intercept: [Double]?

    // forest
    let trees: [Tree]?

    struct Tree: Decodable {
        let left: [Int]
        let right: [Int]
        let feature: [Int]
        let threshold: [Double]
        let value: [[Double]]           // per node, class distribution (normalized)
    }

    public static func load(_ path: String) throws -> TapClassifier {
        let m = try JSONDecoder().decode(TapClassifier.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard m.features == TapDetector.featureNames else {
            throw NSError(domain: "TapClassifier", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "model features do not match TapDetector.featureNames"])
        }
        return m
    }

    /// Class probabilities, ordered as `classes`.
    public func probabilities(_ x: [Double]) -> [Double] {
        switch type {
        case "forest":
            var p = [Double](repeating: 0, count: classes.count)
            for t in trees! {
                var node = 0
                while t.left[node] >= 0 {
                    node = x[t.feature[node]] <= t.threshold[node] ? t.left[node] : t.right[node]
                }
                for c in 0..<p.count { p[c] += t.value[node][c] }
            }
            return p.map { $0 / Double(trees!.count) }
        default:
            let z = zip(zip(x, mean!), scale!).map { ($0.0 - $0.1) / $1 }
            let logits = zip(coef!, intercept!).map { w, b in zip(w, z).map(*).reduce(b, +) }
            let mx = logits.max()!
            let e = logits.map { exp($0 - mx) }
            let s = e.reduce(0, +)
            return e.map { $0 / s }
        }
    }
}
