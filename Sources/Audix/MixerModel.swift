import AppKit
import Combine
import CoreAudio

struct AudioApp: Identifiable {
    /// Bundle ID of the owning app (or "pid:N" for unbundled processes).
    let id: String
    var name: String
    var icon: NSImage?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    /// A real app you use (Dock app, or a third-party menu bar app). False for system sounds: charging chime,
    /// screenshot shutter, alerts, Siri, background daemons.
    var isUserApp = false
}

struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    /// nil = follow the system output device.
    var outputUID: String?

    var isDefault: Bool { volume >= 0.995 && !muted && outputUID == nil }
}

/// The system's current input or output device and its level.
struct DeviceState: Equatable {
    var device: AudioDevice?
    /// nil when the device has a fixed volume (e.g. HDMI, some USB interfaces).
    var volume: Float?
    var muted = false
    var canMute = false
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var visibleApps: [AudioApp] = []
    /// Output devices.
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var defaultOutput: AudioDevice?
    @Published private(set) var output = DeviceState()
    @Published private(set) var input = DeviceState()
    /// Some app is recording from a microphone right now.
    @Published private(set) var micInUse = false
    private var micActivity = Date.distantPast
    /// `--preview-mic`: pretend the mic is on, to check the layout.
    private let forceMic = CommandLine.arguments.contains("--preview-mic")
    /// `--preview-quiet`: pretend nothing is playing, to check the quiet card.
    let forceQuiet = CommandLine.arguments.contains("--preview-quiet")
    /// Per-tab volume, reported by the AUDIX Tabs browser extension.
    let tabBridge = TabBridge()
    /// Battery levels of connected Bluetooth devices (AirPods left/right/case…).
    let batteries = BluetoothBatteries()
    /// Show battery levels under the device name. Toggle from the right-click menu.
    @Published private(set) var showBatteries = UserDefaults.standard.object(forKey: "showBatteries") as? Bool ?? true

    func setShowBatteries(_ show: Bool) {
        showBatteries = show
        UserDefaults.standard.set(show, forKey: "showBatteries")
        if show { batteries.refresh() }
    }
    // MARK: Multi-output state

    /// Real output devices connected right now (no virtual/aggregate ones), system output first.
    @Published private(set) var connectedOutputs: [AudioDevice] = []
    /// Level and mute of each connected output, by UID (for the per-device sections in multi-output mode).
    @Published private(set) var outputStates: [String: DeviceState] = [:]
    /// The multi-output switch. Only takes effect while two or more outputs are connected.
    @Published private(set) var multiOutput = UserDefaults.standard.bool(forKey: "multiOutput")
    /// Multi-output: for each app, the devices it's muted on. Everything plays everywhere unless listed here.
    @Published private(set) var deviceMutes: [String: Set<String>] = {
        guard let data = UserDefaults.standard.data(forKey: "deviceMutes"),
              let saved = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return saved.mapValues(Set.init)
    }()

    /// The switch is offered only when there's more than one output to play on.
    var multiOutputAvailable: Bool { connectedOutputs.count >= 2 }
    var multiOutputActive: Bool { multiOutput && multiOutputAvailable }

    /// Devices without a hardware mute are muted by zeroing their volume; this is the level to restore.
    private var softMuteRestore: [AudioObjectID: Float] = [:]
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published private(set) var errorMessage: String?

    private var allApps: [String: AudioApp] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var taps: [String: AppTap] = [:]
    /// Tap configurations that failed, so we don't retry every second.
    private var failedConfigs: Set<String> = []
    private var timer: Timer?
    private let selfPID = ProcessInfo.processInfo.processIdentifier
    private let settingsKey = "appSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Multi-output actions

    func setMultiOutput(_ on: Bool) {
        multiOutput = on
        UserDefaults.standard.set(on, forKey: "multiOutput")
        failedConfigs = []
        for app in allApps.values { reconcile(app) }
    }

    func isMuted(_ app: AudioApp, on device: AudioDevice) -> Bool {
        deviceMutes[app.id]?.contains(device.uid) ?? false
    }

    /// Multi-output: play / stop playing this app on one device.
    func toggle(_ app: AudioApp, on device: AudioDevice) {
        var muted = deviceMutes[app.id] ?? []
        if muted.contains(device.uid) { muted.remove(device.uid) } else { muted.insert(device.uid) }
        deviceMutes[app.id] = muted.isEmpty ? nil : muted
        if let data = try? JSONEncoder().encode(deviceMutes.mapValues { Array($0) }) {
            UserDefaults.standard.set(data, forKey: "deviceMutes")
        }
        failedConfigs = failedConfigs.filter { !$0.hasPrefix(app.id + "|") }
        reconcile(app)
    }

    func state(of device: AudioDevice) -> DeviceState {
        outputStates[device.uid] ?? DeviceState(device: device)
    }

    func setVolume(_ volume: Float, of device: AudioDevice) {
        applyVolume(volume, to: device.id, input: false)
        updateDeviceStates()
    }

    func toggleMute(of device: AudioDevice) {
        applyMuteToggle(to: device.id, input: false)
        updateDeviceStates()
    }

    // MARK: Device actions

    func deviceState(input isInput: Bool) -> DeviceState { isInput ? input : output }

    func selectDevice(_ device: AudioDevice, input isInput: Bool) {
        CA.setDefaultDevice(device.id, input: isInput)
        refresh()
    }

    func setDeviceVolume(_ volume: Float, input isInput: Bool) {
        guard let device = deviceState(input: isInput).device else { return }
        applyVolume(volume, to: device.id, input: isInput)
        updateDeviceStates()
    }

    func toggleDeviceMute(input isInput: Bool) {
        guard let device = deviceState(input: isInput).device else { return }
        applyMuteToggle(to: device.id, input: isInput)
        updateDeviceStates()
    }

    private func applyVolume(_ volume: Float, to device: AudioObjectID, input isInput: Bool) {
        softMuteRestore[device] = nil
        if volume > 0, CA.isMuted(device, input: isInput) == true {
            CA.setMuted(device, input: isInput, false)
        }
        CA.setVolume(device, input: isInput, volume)
    }

    private func applyMuteToggle(to device: AudioObjectID, input isInput: Bool) {
        if let hardwareMuted = CA.isMuted(device, input: isInput) {
            CA.setMuted(device, input: isInput, !hardwareMuted)
        } else if let restore = softMuteRestore.removeValue(forKey: device) {
            CA.setVolume(device, input: isInput, restore)
        } else if let current = CA.volume(device, input: isInput) {
            softMuteRestore[device] = current
            CA.setVolume(device, input: isInput, 0)
        }
    }

    /// Put back any volumes we zeroed to fake a mute (called on quit).
    func restoreSoftMutes() {
        for (id, volume) in softMuteRestore {
            CA.setVolume(id, input: inputDevices.contains { $0.id == id }, volume)
        }
        softMuteRestore = [:]
    }

    private func updateDeviceStates() {
        let newOutput = readState(defaultOutput, input: false)
        let newInput = readState(inputDevices.first { $0.id == CA.defaultDeviceID(input: true) }, input: true)
        if newOutput != output { output = newOutput }
        if newInput != input { input = newInput }
        var states: [String: DeviceState] = [:]
        for device in connectedOutputs { states[device.uid] = readState(device, input: false) }
        if states != outputStates { outputStates = states }
    }

    private func readState(_ device: AudioDevice?, input isInput: Bool) -> DeviceState {
        guard let device else { return DeviceState() }
        let volume = CA.volume(device.id, input: isInput)
        if let hardwareMuted = CA.isMuted(device.id, input: isInput) {
            return DeviceState(device: device, volume: volume, muted: hardwareMuted, canMute: true)
        }
        if let restore = softMuteRestore[device.id] {
            return DeviceState(device: device, volume: restore, muted: true, canMute: true)
        }
        return DeviceState(device: device, volume: volume, muted: false, canMute: volume != nil)
    }

    // MARK: App actions

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }

    func setVolume(_ app: AudioApp, _ volume: Float) {
        update(app) { $0.volume = volume; if volume > 0 { $0.muted = false } }
    }

    func toggleMute(_ app: AudioApp) {
        update(app) { $0.muted.toggle() }
    }

    func setOutput(_ app: AudioApp, uid: String?) {
        update(app) { $0.outputUID = uid }
    }

    func resetAll() {
        settings = [:]
        failedConfigs = []
        save()
        for key in Array(taps.keys) { taps[key] = nil }
    }

    func outputName(for app: AudioApp) -> String {
        if let uid = setting(for: app.id).outputUID {
            return devices.first { $0.uid == uid }?.name ?? "Unavailable device"
        }
        return defaultOutput?.name ?? "System output"
    }

    // MARK: Internals

    private func update(_ app: AudioApp, _ change: (inout AppSetting) -> Void) {
        var s = setting(for: app.id)
        change(&s)
        settings[app.id] = s.isDefault ? nil : s
        failedConfigs = failedConfigs.filter { !$0.hasPrefix(app.id + "|") }
        save()
        reconcile(app)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    func refresh() {
        let outputs = CA.outputDevices()
        let inputs = CA.inputDevices()
        if outputs != devices { devices = outputs }
        if inputs != inputDevices { inputDevices = inputs }
        let defaultID = CA.defaultOutputDeviceID()
        let newDefault = devices.first { $0.id == defaultID }
        if newDefault != defaultOutput { defaultOutput = newDefault }
        let physical = devices.filter { CA.isPhysical($0.id) }
            .sorted { ($0.id == defaultID ? 0 : 1, $0.name) < ($1.id == defaultID ? 0 : 1, $1.name) }
        if physical != connectedOutputs { connectedOutputs = physical }
        updateDeviceStates()

        // Group Core Audio process objects by the app the user sees.
        var grouped: [String: AudioApp] = [:]
        for process in CA.audioProcesses() where process.pid > 0 && process.pid != selfPID {
            let owner = responsiblePID(for: process.pid)
            let running = NSRunningApplication(processIdentifier: owner)
                ?? NSRunningApplication(processIdentifier: process.pid)
            let key = running?.bundleIdentifier ?? process.bundleID ?? "pid:\(owner)"
            let name = running?.localizedName
                ?? process.bundleID.flatMap { $0.isEmpty ? nil : $0.split(separator: ".").last.map(String.init) }
                ?? processName(process.pid)
                ?? "Process \(owner)"

            var app = grouped[key] ?? AudioApp(id: key, name: name, icon: running?.icon,
                                               processObjects: [], isPlaying: false)
            app.isUserApp = isUserApp(running)
            app.processObjects.append(process.objectID)
            app.isPlaying = app.isPlaying || process.isRunningOutput
            grouped[key] = app
            // Count real apps only: system services like Siri's listener (CoreSpeech) open the mic in the
            // background whenever audio plays, and macOS doesn't show the orange mic dot for them either.
            if process.isRunningInput, let running, running.activationPolicy != .prohibited {
                micActivity = Date()
            }
        }
        allApps = grouped

        let now = Date()

        // Drop taps for apps that quit.
        for key in taps.keys where grouped[key] == nil { taps[key] = nil }
        for app in grouped.values { reconcile(app) }

        // For apps we're routing, trust the measured signal: an idle app's tap keeps running silently.
        for (key, tap) in taps {
            let heard = tap.takePeaks().input > 0.0005
            grouped[key]?.isPlaying = heard
        }
        for app in grouped.values where app.isPlaying { lastPlayed[app.id] = now }

        // Sources: what's playing now, plus a short grace period so rows don't flicker between tracks.
        let sources = grouped.values
            .filter { app in
                app.isUserApp && (app.isPlaying || (lastPlayed[app.id].map { now.timeIntervalSince($0) < 4 } ?? false))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if sources.map(\.id) != visibleApps.map(\.id) || sources.map(\.isPlaying) != visibleApps.map(\.isPlaying) {
            visibleApps = sources
        }

        let micActive = forceMic || now.timeIntervalSince(micActivity) < 2
        if micActive != micInUse { micInUse = micActive }
    }

    private func reconcile(_ app: AudioApp) {
        let s = setting(for: app.id)
        let gain = s.muted ? 0 : s.volume * s.volume // squared: slider feels linear to the ear

        // Multi-output: every app that's playing goes to all connected outputs, minus the ones it's muted on.
        // Idle apps are left alone (no point keeping several devices busy for them).
        if multiOutputActive, app.isUserApp {
            let recent = app.isPlaying || (lastPlayed[app.id].map { Date().timeIntervalSince($0) < 30 } ?? false)
            guard recent, !app.processObjects.isEmpty else { taps[app.id] = nil; return }
            let muted = deviceMutes[app.id] ?? []
            let targets = connectedOutputs.map(\.uid).filter { !muted.contains($0) }
            if targets.isEmpty {
                // Muted everywhere: keep it tapped (that's what silences it), at zero gain.
                ensureTap(app, outputs: [connectedOutputs[0].uid], gain: 0)
            } else {
                ensureTap(app, outputs: targets, gain: gain)
            }
            return
        }

        let pinnedUID = s.outputUID.flatMap { uid in devices.first { $0.uid == uid }?.uid }
        let defaultUID = defaultOutput?.uid
        let targetUID = pinnedUID ?? defaultUID
        let needsTap = s.muted || s.volume < 0.995 || (pinnedUID != nil && pinnedUID != defaultUID)

        guard needsTap, let targetUID, !app.processObjects.isEmpty else {
            taps[app.id] = nil
            return
        }
        ensureTap(app, outputs: [targetUID], gain: gain)
    }

    private func ensureTap(_ app: AudioApp, outputs: [String], gain: Float) {
        if let tap = taps[app.id], tap.outputUIDs == outputs, tap.processObjects == Set(app.processObjects) {
            tap.gain = gain
            return
        }

        let config = "\(app.id)|\(outputs.joined(separator: ","))|\(app.processObjects.sorted())"
        guard !failedConfigs.contains(config) else { return }

        taps[app.id] = nil
        do {
            taps[app.id] = try AppTap(processObjects: app.processObjects, outputUIDs: outputs, gain: gain)
            errorMessage = nil
        } catch {
            failedConfigs.insert(config)
            errorMessage = "Couldn't control \(app.name): \(error)"
        }
    }

    /// Dock apps always count. Menu bar (accessory) apps count unless they're Apple's own helpers
    /// (screenshot UI, Control Center, Siri…). Background processes with no app don't count.
    private func isUserApp(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        switch app.activationPolicy {
        case .regular: return true
        case .accessory: return !(app.bundleIdentifier ?? "com.apple.").hasPrefix("com.apple.")
        default: return false
        }
    }

    // MARK: Self-test support

    func tap(for id: String) -> AppTap? { taps[id] }
    func app(for id: String) -> AudioApp? { allApps[id] }
    var allAppIDs: [String] { Array(allApps.keys) }
}
