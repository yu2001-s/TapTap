import Foundation
import Testing
import TapCore

private func model() throws -> TapClassifier {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try TapClassifier.load(root.appendingPathComponent("model/tapmodel.json").path)
}

@Test func lowPowerWakesOnAJoltAndIdlesAgain() throws {
    var rates: [SPUSensor.Rate] = []
    let pipeline = TapPipeline(recognizer: GestureRecognizer(classifier: try model()), lowPower: true,
                               setRate: { rates.append($0) })
    let rest = SIMD3<Double>(0, 0, -1)
    var t = 0.0
    // One second of a still chassis at the idle rate: stays idle.
    for _ in 0..<100 { pipeline.feed(IMUSample(t: t, a: rest, g: .zero)); t += 0.01 }
    #expect(pipeline.isIdle && rates.isEmpty)

    // A 10 mg jolt wakes full-rate sampling.
    pipeline.feed(IMUSample(t: t, a: rest + SIMD3(0, 0, 0.010), g: .zero)); t += 0.01
    #expect(!pipeline.isIdle && rates == [.full])

    // With no further taps it returns to idle after the hold time.
    for _ in 0..<1600 { pipeline.feed(IMUSample(t: t, a: rest, g: .zero)); t += 1.0 / 800 }
    #expect(pipeline.isIdle && rates == [.full, .idle])
}

@Test func typingDoesNotWakeFullRate() throws {
    var rates: [SPUSensor.Rate] = []
    let pipeline = TapPipeline(recognizer: GestureRecognizer(classifier: try model()), lowPower: true,
                               setRate: { rates.append($0) })
    let rest = SIMD3<Double>(0, 0, -1)
    pipeline.feed(IMUSample(t: 0, a: rest, g: .zero, keyAge: 0.1))
    pipeline.feed(IMUSample(t: 0.01, a: rest + SIMD3(0, 0, 0.02), g: .zero, keyAge: 0.1))
    #expect(pipeline.isIdle && rates.isEmpty)
}
