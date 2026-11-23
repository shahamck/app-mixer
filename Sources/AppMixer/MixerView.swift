import SwiftUI

/// One panel that grows with what's going on:
/// silence → output device + volume · sound playing → + the apps making it, hanging off the speaker
/// · mic on → + input device + level.
struct MixerView: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let apps = model.forceQuiet ? [] : model.visibleApps
        let micOn = model.micInUse && !model.forceQuiet

        VStack(alignment: .leading, spacing: 0) {
            DeviceSection(isInput: false)

            if !apps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        let last = index == apps.count - 1
                        AppRow(app: app, isLast: last)
                        TabRows(browser: app.id, parentIsLast: last, bridge: model.tabBridge)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
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

    private func quit() {
        model.restoreSoftMutes()
        NSApp.terminate(nil)
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

/// Thick, knob-less capsule slider like the system volume HUD. Drag or click anywhere on it.
struct VolumeBar: View {
    let value: Double
    var dimmed = false
    var thickness: CGFloat = 6
    var label = "Volume"
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2))
                Capsule()
                    .fill(Color.primary.opacity(dimmed ? 0.45 : 1))
                    .frame(width: max(thickness, width * value))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(min(1, max(0, drag.location.x / width)))
            })
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
struct AppRow: View {
    let app: AudioApp
    let isLast: Bool
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let setting = model.setting(for: app.id)

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
                if setting.outputUID != nil {
                    Text("→ " + model.outputName(for: app))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 68, alignment: .leading)
            .help(app.name)

            VolumeBar(value: Double(setting.volume), dimmed: setting.muted, thickness: 4, label: "\(app.name) volume") {
                model.setVolume(app, Float($0))
            }

            Text("\(Int((setting.volume * 100).rounded()))%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)

            Button {
                model.toggleMute(app)
            } label: {
                Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(setting.muted ? Color.red : Color.secondary)
            .help(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, DeviceSection.iconCenterX)
        .padding(.trailing, 14)
        .contentShape(Rectangle())
        .contextMenu {
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
