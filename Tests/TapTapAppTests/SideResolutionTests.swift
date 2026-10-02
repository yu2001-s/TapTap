import Testing
import TapCore
@testable import TapTapApp

private func config(_ actions: [GestureSlot: GestureAction.Kind], eitherSide: Bool = true) -> AppConfig {
    var c = AppConfig()
    c.actions = actions.mapValues { GestureAction(kind: $0) }
    c.eitherSideWhenOneSided = eitherSide
    return c
}

@Test func oneSidedGestureRunsFromEitherSide() {
    let c = config([.rightTriple: .shell])
    #expect(c.resolve(location: .macLeft, count: 3, sideConfidence: 0.9) == .run(.rightTriple))
    #expect(c.resolve(location: .macRight, count: 3, sideConfidence: 0.5) == .run(.rightTriple))
}

@Test func oneSidedFallbackCanBeTurnedOff() {
    let c = config([.rightTriple: .shell], eitherSide: false)
    #expect(c.resolve(location: .macLeft, count: 3, sideConfidence: 0.9) == .run(.leftTriple))
}

@Test func twoSidedGestureNeedsAConfidentSide() {
    let c = config([.leftDouble: .shell, .rightDouble: .shell])
    #expect(c.resolve(location: .macLeft, count: 2, sideConfidence: 0.8) == .run(.leftDouble))
    #expect(c.resolve(location: .macRight, count: 2, sideConfidence: 0.55) == .ambiguous(.rightDouble))
}

@Test func desksAreNotGestureSlots() {
    #expect(config([:]).resolve(location: .desk, count: 2, sideConfidence: 1) == .unsupported)
}
