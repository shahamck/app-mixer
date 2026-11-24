import AppKit
import SwiftUI

@main
struct AppMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // The menu bar icon and glass panel are AppKit (see StatusPanel.swift); no SwiftUI windows.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: MixerModel?
    private var statusPanel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--devicetest"), args.count > i + 1 {
            DeviceTest.run(logPath: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--selftest"), args.count > i + 4 {
            SelfTest.run(bundleID: args[i + 1], volume: Float(args[i + 2]) ?? 0.3,
                         seconds: Double(args[i + 3]) ?? 6, logPath: args[i + 4])
            return
        }

        let model = MixerModel()
        self.model = model
        // `--preview`: open the panel in the middle of the screen and keep it open (for screenshots).
        statusPanel = StatusPanelController(model: model, preview: args.contains("--preview"))
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.restoreSoftMutes()
    }
}

/// `AppMixer --devicetest <logPath>`: nudges default output/input volume by 10%, reads it back, restores it.
enum DeviceTest {
    static func run(logPath: String) {
        var lines: [String] = []
        for isInput in [false, true] {
            let id = CA.defaultDeviceID(input: isInput)
            let name = CA.devices(input: isInput).first { $0.id == id }?.name ?? "?"
            let label = isInput ? "input" : "output"
            guard let before = CA.volume(id, input: isInput) else {
                lines.append("\(label) \(name): fixed volume, mute=\(String(describing: CA.isMuted(id, input: isInput)))")
                continue
            }
            let target = before > 0.5 ? before - 0.1 : before + 0.1
            CA.setVolume(id, input: isInput, target)
            let after = CA.volume(id, input: isInput) ?? -1
            CA.setVolume(id, input: isInput, before)
            let restored = CA.volume(id, input: isInput) ?? -1
            lines.append(String(format: "%@ %@: before %.2f set %.2f read %.2f restored %.2f hwMute=%@",
                                label, name, before, target, after, restored,
                                String(describing: CA.isMuted(id, input: isInput))))
        }
        try? lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

/// `AppMixer --selftest <bundleID> <volume> <seconds> <logPath>`
/// Taps one app at a fixed volume and logs input/output peaks, then quits.
enum SelfTest {
    static func run(bundleID: String, volume: Float, seconds: Double, logPath: String) {
        var lines: [String] = []
        func log(_ s: String) {
            lines.append(s)
            try? lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }

        let devices = CA.outputDevices()
        let defaultID = CA.defaultOutputDeviceID()
        log("devices: " + devices.map { "\($0.name)\($0.id == defaultID ? " (default)" : "")" }.joined(separator: ", "))

        let processes = CA.audioProcesses().filter { $0.pid > 0 }
        for p in processes {
            let owner = responsiblePID(for: p.pid)
            let app = NSRunningApplication(processIdentifier: owner)
            log("process obj=\(p.objectID) pid=\(p.pid) bundle=\(p.bundleID ?? "-") owner=\(app?.bundleIdentifier ?? "\(owner)") playing=\(p.isRunningOutput)")
        }

        let targets = processes.filter {
            let owner = NSRunningApplication(processIdentifier: responsiblePID(for: $0.pid))
            return owner?.bundleIdentifier == bundleID || $0.bundleID == bundleID || String($0.pid) == bundleID
        }.map(\.objectID)
        guard !targets.isEmpty, let output = devices.first(where: { $0.id == defaultID }) else {
            log("RESULT: no audio processes for \(bundleID) or no default output")
            NSApp.terminate(nil)
            return
        }

        do {
            // `-selftestOutputs "Name A,Name B"`: play on several devices at once (multi-output).
            let names = (UserDefaults.standard.string(forKey: "selftestOutputs") ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let chosen = names.compactMap { name in devices.first { $0.name == name } }
            let outputs = chosen.isEmpty ? [output] : chosen
            let tap = try AppTap(processObjects: targets, outputUIDs: outputs.map(\.uid), gain: volume)
            log("tap started on \(outputs.map(\.name).joined(separator: " + ")) at gain \(volume)")
            log(tap.debugDescription)
            var ticks = 0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                let p = tap.takePeaks()
                log(String(format: "peak in %.3f  out %.3f", p.input, p.output))
                ticks += 1
                if Double(ticks) * 0.5 >= seconds {
                    timer.invalidate()
                    withExtendedLifetime(tap) {}
                    log("RESULT: done")
                    NSApp.terminate(nil)
                }
            }
        } catch {
            log("RESULT: \(error)")
            NSApp.terminate(nil)
        }
    }
}
