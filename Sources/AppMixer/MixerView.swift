import SwiftUI

/// One panel that grows with what's going on:
/// silence → output device + volume · sound playing → + the apps making it, hanging off the speaker
/// · mic on → + input device + level.
struct MixerView: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let apps = model.forceQuiet ? [] : model.visibleApps
        let micOn = model.micInUse && !model.forceQuiet

        let multi = model.multiOutputActive

        VStack(alignment: .leading, spacing: 0) {
            if multi {
                // Multi-output: one section per connected output, each with the apps playing and an
                // on/off per app for that device.
                ForEach(Array(model.connectedOutputs.enumerated()), id: \.element.uid) { index, device in
                    OutputDeviceSection(device: device)
                        .padding(.top, index == 0 ? 0 : 12)
                    if !apps.isEmpty {
                        appTree(apps, device: device)
                    }
                }
            } else {
                DeviceSection(isInput: false)
                if !apps.isEmpty {
                    appTree(apps, device: nil)
                }
            }

            if micOn {
                DeviceSection(isInput: true)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only offered when there's more than one output connected.
            if model.multiOutputAvailable {
                MultiOutputToggle()
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 296, alignment: .leading)
        .background(alignment: .topLeading) {
            // ⌘Q still quits with no visible Quit button.
            Button("Quit") { quit() }
                .keyboardShortcut("q")
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .liquidGlass(cornerRadius: 20)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4) // follows the rounded glass
        .animation(.easeInOut(duration: 0.2), value: micOn)
        .animation(.easeInOut(duration: 0.2), value: apps.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: multi)
        .animation(.easeInOut(duration: 0.2), value: model.connectedOutputs.map(\.uid))
        .contextMenu {
            Toggle("Show battery levels", isOn: Binding(get: { model.showBatteries },
                                                        set: { model.setShowBatteries($0) }))
            Divider()
            Button("Reset all apps") { model.resetAll() }
                .disabled(model.settings.isEmpty)
            Divider()
            Button("Quit AppMixer") { quit() }
        }
    }

    /// Apps playing, hanging off the speaker icon. With a `device`, each row's speaker button turns that
    /// app on/off for that device (multi-output); without one, it mutes the app.
    private func appTree(_ apps: [AudioApp], device: AudioDevice?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                let last = index == apps.count - 1
                AppRow(app: app, isLast: last, device: device)
                if device == nil {
                    TabRows(browser: app.id, parentIsLast: last, bridge: model.tabBridge)
                }
            }
        }
        .padding(.top, 2)
        .transition(.opacity)
    }

    private func quit() {
        model.restoreSoftMutes()
        NSApp.terminate(nil)
    }
}

/// The multi-output switch: play on every connected output at once.
struct MultiOutputToggle: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(model.multiOutputActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Multi-output")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.multiOutputActive
                     ? "Playing on \(model.connectedOutputs.count) devices"
                     : "Play on all \(model.connectedOutputs.count) outputs at once")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Multi-output", isOn: Binding(get: { model.multiOutput }, set: { model.setMultiOutput($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
    }
}

/// One connected output in multi-output mode: its name (and battery), volume and mute.
struct OutputDeviceSection: View {
    let device: AudioDevice
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let state = model.state(of: device)

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(device.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if device.id == model.defaultOutput?.id {
                    Text("System")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .help("Alerts and apps that aren't playing go here")
                }
            }

            if model.showBatteries {
                BatteryRow(batteries: model.batteries, deviceName: device.name)
            }

            HStack(spacing: 10) {
                Button {
                    model.toggleMute(of: device)
                } label: {
                    Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.muted ? Color.red : Color.primary)
                .disabled(!state.canMute)

                if let volume = state.volume {
                    VolumeBar(value: Double(volume), dimmed: state.muted, label: "\(device.name) volume") {
                        model.setVolume(Float($0), of: device)
                    }
                } else {
                    Text("Fixed volume")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                Button {
                    model.toggleMute(of: device)
                } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .frame(width: 20, height: 16, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!state.canMute)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Output / input

/// Device name (click to switch) over a volume bar, in the style of the macOS volume HUD.
/// Left icon mutes; icons are plain monochrome symbols.
struct DeviceSection: View {
    let isInput: Bool
    @EnvironmentObject var model: MixerModel

    /// Centre of the left icon, measured from the panel's left edge. Nested app rows hang from here.
    static let iconCenterX: CGFloat = 14 + 8

    var body: some View {
        let state = model.deviceState(input: isInput)
        let devices = isInput ? model.inputDevices : model.devices

        VStack(alignment: .leading, spacing: 7) {
            Menu {
                ForEach(devices) { device in
                    Button {
                        model.selectDevice(device, input: isInput)
                    } label: {
                        if device.id == state.device?.id { Image(systemName: "checkmark") }
                        Text(device.name)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(state.device?.name ?? (isInput ? "No microphone" : "No output"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(isInput ? "Choose microphone" : "Choose output device")

            // Bluetooth battery (AirPods left / right / case). The mic row skips it when it's the same device.
            if model.showBatteries, !(isInput && state.device?.name == model.output.device?.name) {
                BatteryRow(batteries: model.batteries, deviceName: state.device?.name)
            }

            HStack(spacing: 10) {
                Button {
                    model.toggleDeviceMute(input: isInput)
                } label: {
                    Image(systemName: lowIcon(state))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.muted ? Color.red : Color.primary)
                .disabled(!state.canMute)
                .help(state.muted ? "Unmute" : "Mute")

                if let volume = state.volume {
                    VolumeBar(value: Double(volume), dimmed: state.muted,
                              label: isInput ? "Input level" : "Output volume") {
                        model.setDeviceVolume(Float($0), input: isInput)
                    }
                } else {
                    Text("Fixed volume")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                // Right icon mutes too, so either end of the bar works.
                Button {
                    model.toggleDeviceMute(input: isInput)
                } label: {
                    Image(systemName: isInput ? "waveform" : "speaker.wave.3.fill")
                        .frame(width: 20, height: 16, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!state.canMute)
                .help(state.muted ? "Unmute" : "Mute")
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
    }

    private func lowIcon(_ state: DeviceState) -> String {
        if isInput { return state.muted ? "mic.slash.fill" : "mic.fill" }
        return state.muted ? "speaker.slash.fill" : "speaker.fill"
    }
}

/// Small battery readouts under a Bluetooth device's name: AirPods left / right / case, or one battery.
/// A green bolt marks a part that's charging; 20% or below (and not charging) turns red.
/// The case is always shown for AirPods: live, or dimmed with the last level seen.
struct BatteryRow: View {
    @ObservedObject var batteries: BluetoothBatteries
    let deviceName: String?

    var body: some View {
        if let device = batteries.device(named: deviceName) {
            let pro = device.kind == .airPodsPro
            HStack(spacing: 12) {
                if let part = device.left {
                    chip(device.isAirPods ? (pro ? "airpodpro.left" : "airpod.left") : nil, text: "L", name: "Left", part)
                }
                if let part = device.right {
                    chip(device.isAirPods ? (pro ? "airpodpro.right" : "airpod.right") : nil, text: "R", name: "Right", part)
                }
                if let part = device.main {
                    // AirPods sometimes report both buds as one level; other devices have a single battery.
                    let symbol = device.isAirPods ? (pro ? "airpodspro" : "airpods")
                        : device.kind == .headphones ? "headphones" : "battery.75percent"
                    chip(symbol, text: "", name: device.isAirPods ? "Both AirPods" : "Battery", part)
                }
                if device.isAirPods || device.case != nil {
                    let symbol = pro ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill"
                    if let part = device.case {
                        chip(device.isAirPods ? symbol : nil, text: "Case", name: "Case", part)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: symbol)
                            Text("–")
                        }
                        .foregroundStyle(.tertiary)
                        .help("Case: open it near your Mac to update")
                    }
                }
            }
            .font(.system(size: 10))
            .transition(.opacity)
        }
    }

    private func chip(_ symbol: String?, text: String, name: String, _ part: BluetoothBatteries.Part) -> some View {
        let stale = part.lastSeen != nil
        let low = part.level <= 20 && !part.charging
        return HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Text(text).fontWeight(.semibold)
            }
            Text("\(part.level)%").monospacedDigit()
            if part.charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
        .foregroundStyle(low ? Color.red : Color.secondary)
        .opacity(stale ? 0.5 : 1)
        .help(tooltip(name, part))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) battery \(part.level) percent\(part.charging ? ", charging" : "")")
    }

    private func tooltip(_ name: String, _ part: BluetoothBatteries.Part) -> String {
        var text = "\(name): \(part.level)%"
        if part.charging { text += ", charging" }
        if let seen = part.lastSeen {
            let ago = RelativeDateTimeFormatter().localizedString(for: seen, relativeTo: Date())
            text += " (last seen \(ago))"
        }
        return text
    }
}

/// The slider thumb shown while dragging: a capsule of Liquid Glass (clear, with a light rim),
/// like the macOS 26 slider thumb when you grab it. Falls back to a white capsule before macOS 26.
struct KnobView: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26.0, *) {
            shape
                .fill(Color.white.opacity(0.16))
                .frame(width: width, height: height)
                .glassEffect(.clear.interactive(), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.28), radius: 3, y: 1.5)
        } else {
            shape
                .fill(Color.white)
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
    }
}

/// Thick, knob-less capsule slider like the system volume HUD. Drag or click anywhere on it.
struct VolumeBar: View {
    let value: Double
    var dimmed = false
    var thickness: CGFloat = 6
    var label = "Volume"
    let onChange: (Double) -> Void

    /// The round knob only appears while the bar is being dragged; the rest of the time it's a clean bar.
    @State private var dragging = UserDefaults.standard.bool(forKey: "previewKnob") // preview: show the knob

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            // Apple-style thumb: a short capsule, a bit wider than tall.
            let knobH = max(thickness * 2.6, 12)
            let knobW = knobH * 1.55
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2))
                    .frame(height: thickness)
                Capsule()
                    .fill(Color.primary.opacity(dimmed ? 0.45 : 1))
                    .frame(width: max(thickness, width * value), height: thickness)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                KnobView(width: knobW, height: knobH)
                    .offset(x: min(max(width * value - knobW / 2, -knobW / 4), width - knobW * 3 / 4))
                    .scaleEffect(dragging ? 1 : 0.5)
                    .opacity(dragging ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging { withAnimation(.spring(duration: 0.2)) { dragging = true } }
                        onChange(min(1, max(0, drag.location.x / width)))
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.25)) { dragging = false }
                    }
            )
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(1, value + 1.0 / 16))
            case .decrement: onChange(max(0, value - 1.0 / 16))
            @unknown default: break
            }
        }
    }
}

extension View {
    /// Frosted Liquid Glass on macOS 26+ (regular material before that). It follows the system light/dark
    /// appearance, so text stays readable over bright and dark backgrounds alike.
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

// MARK: - Sources nested under Output

/// The tree line on the left of a nested row. `branch` draws a curved ├ or └, `pass` draws │ (or nothing).
struct TreeGuide: View {
    enum Kind { case branch(last: Bool), pass(continues: Bool) }
    let kind: Kind
    var width: CGFloat = 18

    var body: some View {
        GeometryReader { g in
            Path { p in
                let x: CGFloat = 0.5
                let mid = g.size.height / 2
                let end = g.size.width - 1
                let radius = min(7, mid, end - x)
                switch kind {
                case .branch(let last):
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: last ? mid - radius : g.size.height))
                    p.move(to: CGPoint(x: x, y: mid - radius))
                    p.addQuadCurve(to: CGPoint(x: x + radius, y: mid), control: CGPoint(x: x, y: mid))
                    p.addLine(to: CGPoint(x: end, y: mid))
                case .pass(let continues):
                    if continues {
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: g.size.height))
                    }
                }
            }
            .stroke(Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .frame(width: width)
    }
}

/// An app making sound, hanging off the speaker icon. Right-click to send it to another device.
/// In multi-output mode (`device` set) the speaker button plays / stops this app on that device.
struct AppRow: View {
    let app: AudioApp
    let isLast: Bool
    var device: AudioDevice? = nil
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let setting = model.setting(for: app.id)
        let offHere = device.map { model.isMuted(app, on: $0) } ?? false
        let silent = setting.muted || offHere

        HStack(spacing: 7) {
            TreeGuide(kind: .branch(last: isLast))

            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .opacity(app.isPlaying ? 1 : 0.45)
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if device == nil, setting.outputUID != nil {
                    Text("→ " + model.outputName(for: app))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 68, alignment: .leading)
            .help(app.name)

            VolumeBar(value: Double(setting.volume), dimmed: silent, thickness: 4, label: "\(app.name) volume") {
                model.setVolume(app, Float($0))
            }

            Text("\(Int((setting.volume * 100).rounded()))%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)

            Button {
                if let device { model.toggle(app, on: device) } else { model.toggleMute(app) }
            } label: {
                Image(systemName: silent ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(silent ? Color.red : Color.secondary)
            .help(device.map { offHere ? "Play \(app.name) on \($0.name)" : "Stop \(app.name) on \($0.name)" }
                  ?? (setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)"))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, DeviceSection.iconCenterX)
        .padding(.trailing, 14)
        .contentShape(Rectangle())
        .contextMenu {
            if device == nil { routingMenu(setting) }
        }
    }

    @ViewBuilder
    private func routingMenu(_ setting: AppSetting) -> some View {
            Section("Play \(app.name) through") {
                Button {
                    model.setOutput(app, uid: nil)
                } label: {
                    if setting.outputUID == nil { Image(systemName: "checkmark") }
                    Text("System output (\(model.defaultOutput?.name ?? "none"))")
                }
                ForEach(model.devices) { device in
                    Button {
                        model.setOutput(app, uid: device.uid)
                    } label: {
                        if setting.outputUID == device.uid { Image(systemName: "checkmark") }
                        Text(device.name)
                    }
                }
            }
    }
}

/// Browser tabs (from the AppMixer Tabs extension), nested one level below their browser.
struct TabRows: View {
    let browser: String
    let parentIsLast: Bool
    @ObservedObject var bridge: TabBridge

    var body: some View {
        let tabs = bridge.tabs(for: browser)
        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
            HStack(spacing: 7) {
                TreeGuide(kind: .pass(continues: !parentIsLast))
                TreeGuide(kind: .branch(last: index == tabs.count - 1), width: 14)
                    .padding(.leading, 8) // hang from the centre of the app icon above

                Group {
                    if let url = tab.favicon.flatMap(URL.init(string:)) {
                        AsyncImage(url: url) { $0.resizable() } placeholder: { Image(systemName: "globe") }
                    } else {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 14, height: 14)
                .opacity(tab.playing ? 1 : 0.45)
                .padding(.vertical, 5)

                Text(tab.title)
                    .font(.system(size: 11))
                    .foregroundStyle(tab.playing ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 52, alignment: .leading)
                    .help(tab.host.map { "\(tab.title) — \($0)" } ?? tab.title)

                VolumeBar(value: Double(tab.volume), dimmed: tab.muted, thickness: 4, label: "\(tab.title) volume") {
                    bridge.set(browser: browser, tab: tab.id, volume: Float($0), muted: $0 > 0 ? false : tab.muted)
                }

                Text("\(Int((tab.volume * 100).rounded()))%")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)

                Button {
                    bridge.set(browser: browser, tab: tab.id, volume: tab.volume, muted: !tab.muted)
                } label: {
                    Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.muted ? Color.red : Color.secondary)
                .help(tab.muted ? "Unmute tab" : "Mute tab")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, DeviceSection.iconCenterX)
            .padding(.trailing, 14)
        }
    }
}
