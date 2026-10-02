import AppKit
import os
import ServiceManagement
import TapCore

struct AppConfig: Codable, Equatable {
    var enabled = true
    var showHUD = true
    var showMenuBarIcon = true
    var minPeak = 8.0
    /// When only one side of a double/triple tap has an action, run it no matter which
    /// side the tap was classified as. Left/right is the least reliable part of detection.
    var eitherSideWhenOneSided = true
    /// Sample at ~100 Hz between gestures (well under 1% CPU) instead of 800 Hz all the time.
    var lowPower = true
    var actions: [GestureSlot: GestureAction] = [
        .leftDouble: GestureAction(kind: .media, media: .playPause),
        .rightDouble: GestureAction(kind: .media, media: .next),
    ]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, showHUD, showMenuBarIcon, minPeak, eitherSideWhenOneSided, lowPower, actions
    }

    // Older settings have no icon preference. Preserve their actions and other
    // preferences instead of rejecting the entire saved configuration.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        showHUD = try values.decodeIfPresent(Bool.self, forKey: .showHUD) ?? showHUD
        showMenuBarIcon = try values.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? showMenuBarIcon
        minPeak = try values.decodeIfPresent(Double.self, forKey: .minPeak) ?? minPeak
        eitherSideWhenOneSided = try values.decodeIfPresent(Bool.self, forKey: .eitherSideWhenOneSided) ?? eitherSideWhenOneSided
        lowPower = try values.decodeIfPresent(Bool.self, forKey: .lowPower) ?? lowPower
        actions = try values.decodeIfPresent([GestureSlot: GestureAction].self, forKey: .actions) ?? actions
    }

    func action(_ slot: GestureSlot) -> GestureAction { actions[slot] ?? GestureAction() }

    enum Resolution: Equatable {
        case run(GestureSlot)
        /// Both sides have actions and the classifier could not tell which side was tapped.
        case ambiguous(GestureSlot)
        case unsupported
    }

    /// Minimum share of the Mac probability on one side before a two-sided gesture runs.
    static let minSideConfidence = 0.6

    /// Picks the slot for a recognized gesture, accounting for unreliable left/right.
    func resolve(location: TapLocation, count: Int, sideConfidence: Double) -> Resolution {
        guard let detected = GestureSlot(rawValue: "\(location.rawValue)×\(count)") else { return .unsupported }
        let opposite = detected.opposite
        let mine = action(detected).kind != .none
        let theirs = action(opposite).kind != .none
        switch (mine, theirs) {
        case (true, true):
            return sideConfidence >= Self.minSideConfidence ? .run(detected) : .ambiguous(detected)
        case (false, true) where eitherSideWhenOneSided:
            return .run(opposite)
        default:
            return .run(detected)
        }
    }
}

extension GestureSlot {
    var opposite: GestureSlot {
        switch self {
        case .leftDouble: .rightDouble
        case .leftTriple: .rightTriple
        case .rightDouble: .leftDouble
        case .rightTriple: .leftTriple
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    enum Status: Equatable {
        case running, paused, noSensor, noModel(String), failed(String)
    }

    @Published var config: AppConfig {
        didSet { if config != oldValue { save(); apply(oldValue) } }
    }
    @Published private(set) var status: Status = .paused
    @Published private(set) var lastEvent: (slot: GestureSlot, at: Date, ran: Bool)?
    @Published private(set) var accessibilityTrusted = Accessibility.isTrusted
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginError: String?
    @Published var language = L10n.language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: L10n.languageKey)
            SettingsWindowController.shared.refreshTitle()
        }
    }

    private var engine: TapEngine?
    nonisolated private static let log = Logger(subsystem: "app.taptap.TapTap", category: "gesture")
    private static let defaultsKey = "config"

    init() {
        let preview = ProcessInfo.processInfo.environment["TAPTAP_SNAPSHOT"] != nil
            && ProcessInfo.processInfo.environment["TAPTAP_SNAPSHOT_DEFAULTS"] == "1"
        if !preview, let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let c = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = c
        } else {
            config = AppConfig()
        }
        loadEngine()
        if preview {
            // Documentation previews use fresh defaults and no live sensor.
            // The user's saved gestures, permissions, and settings are untouched.
            if engine != nil { status = .running }
        } else if config.enabled { start() }
        Snapshot.runIfRequested(model: self)

        // Permission can be granted while the app runs; keep the UI in sync.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = Accessibility.isTrusted
                if trusted != self.accessibilityTrusted { self.accessibilityTrusted = trusted }
            }
        }
    }

    var needsAccessibility: Bool {
        GestureSlot.allCases.contains { config.action($0).needsAccessibility } && !accessibilityTrusted
    }

    var statusText: String {
        switch status {
        case .running: L10n.text("Running")
        case .paused: L10n.text("Paused")
        case .noSensor: L10n.text("This Mac has no supported motion sensor")
        case .noModel(let e): L10n.format("Could not load model: %@", e)
        case .failed(let e): L10n.format("Could not start: %@", e)
        }
    }

    // MARK: - Engine

    private func loadEngine() {
        guard SPUSensor.isAvailable else { status = .noSensor; return }
        let path = Bundle.main.path(forResource: "tapmodel", ofType: "json") ?? "model/tapmodel.json"
        do {
            let e = TapEngine(classifier: try TapClassifier.load(path))
            e.minPeak = config.minPeak
            e.lowPower = config.lowPower
            e.onGesture = { [weak self] g in self?.handle(g) }
            // Per-tap verdicts for diagnosing missed gestures:
            //   log stream --level info --predicate 'subsystem == "app.taptap.TapTap"'
            let classes = e.classifier.classes
            e.onTrace = { t, p, verdict in
                let probs = p.map { zip(classes, $0).map { "\($0)=\(Int($1 * 100))" }.joined(separator: " ") } ?? ""
                Self.log.info("\(String(format: "%.3f", t), privacy: .public) \(verdict, privacy: .public) \(probs, privacy: .public)")
            }
            engine = e
        } catch {
            status = .noModel(error.localizedDescription)
        }
    }

    private func start() {
        guard let engine else { return }
        do {
            try engine.start()
            status = .running
        } catch {
            status = .failed("\(error)")
        }
    }

    private func stop() {
        engine?.stop()
        if engine != nil { status = .paused }
    }

    private func apply(_ old: AppConfig) {
        if config.minPeak != old.minPeak { engine?.minPeak = config.minPeak }
        if config.lowPower != old.lowPower, let engine {
            engine.lowPower = config.lowPower
            if engine.isRunning { engine.stop(); start() }
        }
        if config.enabled != old.enabled { config.enabled ? start() : stop() }
    }

    private func handle(_ g: Gesture) {
        guard config.enabled else { return }
        let slot: GestureSlot
        switch config.resolve(location: g.location, count: g.count, sideConfidence: g.sideConfidence) {
        case .unsupported:
            return
        case .ambiguous(let detected):
            Self.log.info("gesture \(detected.rawValue, privacy: .public) side \(Int(g.sideConfidence * 100))% → ambiguous, not run")
            if config.showHUD {
                HUD.show(slot: detected, action: config.action(detected), ran: false,
                         error: L10n.text("Couldn't tell left from right. Try again."))
            }
            return
        case .run(let s):
            slot = s
        }
        let action = config.action(slot)
        let canRun = action.kind != .none && (!action.needsAccessibility || Accessibility.isTrusted)
        let error = canRun ? ActionRunner.run(action) : nil
        let ran = canRun && error == nil
        Self.log.info("gesture \(g.location.rawValue, privacy: .public)×\(g.count) mac \(Int(g.confidence * 100))% side \(Int(g.sideConfidence * 100))% → \(slot.rawValue, privacy: .public) \(action.kind.rawValue, privacy: .public) ran=\(ran) \(error ?? "", privacy: .public)")
        lastEvent = (slot, Date(), ran)
        if config.showHUD { HUD.show(slot: slot, action: action, ran: ran, error: error) }
    }

    // MARK: - Settings

    func setAction(_ a: GestureAction, for slot: GestureSlot) {
        config.actions[slot] = a
    }

    func showSettings() {
        SettingsWindowController.shared.show(model: self)
    }

    func requestAccessibility() {
        Accessibility.request()
        Accessibility.openSettings()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
