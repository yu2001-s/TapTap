import AppKit
import ServiceManagement
import TapCore

struct AppConfig: Codable, Equatable {
    var enabled = true
    var showHUD = true
    var showMenuBarIcon = true
    var minPeak = 8.0
    var actions: [GestureSlot: GestureAction] = [
        .leftDouble: GestureAction(kind: .media, media: .playPause),
        .rightDouble: GestureAction(kind: .media, media: .next),
    ]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, showHUD, showMenuBarIcon, minPeak, actions
    }

    // Older settings have no icon preference. Preserve their actions and other
    // preferences instead of rejecting the entire saved configuration.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        showHUD = try values.decodeIfPresent(Bool.self, forKey: .showHUD) ?? showHUD
        showMenuBarIcon = try values.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? showMenuBarIcon
        minPeak = try values.decodeIfPresent(Double.self, forKey: .minPeak) ?? minPeak
        actions = try values.decodeIfPresent([GestureSlot: GestureAction].self, forKey: .actions) ?? actions
    }

    func action(_ slot: GestureSlot) -> GestureAction { actions[slot] ?? GestureAction() }
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
            e.onGesture = { [weak self] g in self?.handle(g) }
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
        if config.enabled != old.enabled { config.enabled ? start() : stop() }
    }

    private func handle(_ g: Gesture) {
        guard config.enabled, let slot = GestureSlot(rawValue: "\(g.location.rawValue)×\(g.count)") else { return }
        let action = config.action(slot)
        let canRun = action.kind != .none && (!action.needsAccessibility || Accessibility.isTrusted)
        let error = canRun ? ActionRunner.run(action) : nil
        let ran = canRun && error == nil
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
