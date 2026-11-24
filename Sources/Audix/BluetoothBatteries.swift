import Foundation
import IOKit.ps

/// Battery levels and charging state of connected Bluetooth devices: AirPods left / right / case,
/// headsets, keyboards… Same data as the Bluetooth menu, no extra permission needed.
///
/// Main source: the accessory power sources (one entry per part, with "Is Charging").
/// Backup: `system_profiler SPBluetoothDataType` for devices that don't publish a power source.
@MainActor
final class BluetoothBatteries: ObservableObject {
    struct Part: Equatable {
        var level: Int
        var charging: Bool
        /// Not reported right now; this is the last value we saw (AirPods cases only report while open).
        var lastSeen: Date?
    }

    struct Device: Equatable {
        enum Kind { case airPodsPro, airPods, headphones, other }
        let name: String
        var kind: Kind
        var left: Part?
        var right: Part?
        var `case`: Part?
        var main: Part?

        var isAirPods: Bool { kind == .airPodsPro || kind == .airPods }
        var hasLevels: Bool { left != nil || right != nil || `case` != nil || main != nil }
    }

    /// Connected devices with at least one battery level, keyed by name
    /// (the same name Core Audio uses for the output/input device).
    @Published private(set) var devices: [String: Device] = [:]

    /// Last case level per AirPods, so the case still shows after it's closed.
    private var lastCase: [String: Part] = [:]
    private var timer: Timer?
    private var lastRefresh = Date.distantPast
    private var running = false
    private var notification: CFRunLoopSource?

    init() {
        if let data = UserDefaults.standard.data(forKey: "lastCaseBattery"),
           let saved = try? JSONDecoder().decode([String: SavedPart].self, from: data) {
            lastCase = saved.mapValues { Part(level: $0.level, charging: false, lastSeen: $0.date) }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // macOS posts this when any power source changes (plugging the case in, a level dropping…).
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<BluetoothBatteries>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in me.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            notification = source
        }
    }

    func device(named name: String?) -> Device? {
        guard let name else { return nil }
        return devices[name]
    }

    /// Re-read now unless we did a moment ago (called when the panel opens).
    func refreshSoon() {
        if Date().timeIntervalSince(lastRefresh) > 3 { refresh() }
    }

    func refresh() {
        guard !running else { return }
        running = true
        lastRefresh = Date()
        Task.detached(priority: .utility) {
            var found = Self.readAccessoryPowerSources()
            // Backup for devices that only show up in the Bluetooth report.
            for (name, device) in Self.readSystemProfiler() {
                guard var existing = found[name] else { found[name] = device; continue }
                // Power sources sometimes give only a combined AirPods level; take left/right/case from here.
                existing.left = existing.left ?? device.left
                existing.right = existing.right ?? device.right
                existing.case = existing.case ?? device.case
                found[name] = existing
            }
            // With separate buds known, the combined level is redundant.
            for (name, var device) in found where device.isAirPods && (device.left != nil || device.right != nil) {
                device.main = nil
                found[name] = device
            }
            let result = found
            await MainActor.run { self.publish(result) }
        }
    }

    private func publish(_ found: [String: Device]) {
        running = false
        var result = found
        let now = Date()
        if UserDefaults.standard.bool(forKey: "previewCharging") { // preview only: pretend everything is charging
            for (name, var device) in result where device.isAirPods {
                device.left?.charging = true
                device.right?.charging = true
                device.case = Part(level: 62, charging: true)
                result[name] = device
            }
        }
        for (name, var device) in result where device.isAirPods {
            if let live = device.case {
                lastCase[name] = Part(level: live.level, charging: false, lastSeen: now)
            } else if let remembered = lastCase[name] {
                device.case = remembered // shown dimmed, with "last seen" in the tooltip
            }
            result[name] = device
        }
        saveLastCase()
        if result != devices { devices = result }
    }

    // MARK: Accessory power sources (per part, with charging)

    private typealias CopyByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private nonisolated static let copyByType: CopyByType? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopyByType.self)
    }()

    private nonisolated static func readAccessoryPowerSources() -> [String: Device] {
        let accessories: Int32 = 4 // kIOPSSourceForAccessories
        guard let copy = copyByType, let info = copy(accessories)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [:] }

        // Entries come per part. The case is its own entry named "<AirPods> Case", and a "Combined" entry may
        // nest the buds under "Combined Parts". Everything of one device shares a Group Identifier.
        var entries: [[String: Any]] = []
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d["Transport Type"] as? String) == "Bluetooth" else { continue }
            entries.append(d)
            entries += d["Combined Parts"] as? [[String: Any]] ?? []
        }

        var groups: [String: Device] = [:]
        for d in entries {
            guard let rawName = d["Name"] as? String, let level = d["Current Capacity"] as? Int else { continue }
            let partID = (d["Part Identifier"] as? String)?.lowercased()
            let group = d["Group Identifier"] as? String ?? rawName
            // The device's own name, without the " Case" suffix the case entry carries.
            let name = partID == "case" && rawName.hasSuffix(" Case") ? String(rawName.dropLast(5)) : rawName
            let charging = (d["Is Charging"] as? Int ?? 0) == 1 || (d["Power Source State"] as? String) == "AC Power"
            let part = Part(level: level, charging: charging)
            let product = d["Product ID"] as? Int ?? 0

            var device = groups[group] ?? Device(name: name, kind: kind(name: name, productID: product,
                                                                          category: d["Accessory Category"] as? String))
            switch partID {
            case "left": device.left = part
            case "right": device.right = part
            case "case": device.case = part
            default: device.main = part // "Combined", or a single-battery device
            }
            groups[group] = device
        }

        var result: [String: Device] = [:]
        for device in groups.values { result[device.name] = device }
        return result
    }

    // MARK: system_profiler backup (levels only)

    private nonisolated static func readSystemProfiler() -> [String: Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }

        func part(_ value: Any?) -> Part? {
            guard let text = value as? String,
                  let level = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
            return Part(level: level, charging: false)
        }

        var result: [String: Device] = [:]
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let product = Int((info["device_productID"] as? String ?? "").replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
                    let device = Device(
                        name: name,
                        kind: kind(name: name, productID: product, category: info["device_minorType"] as? String),
                        left: part(info["device_batteryLevelLeft"]),
                        right: part(info["device_batteryLevelRight"]),
                        case: part(info["device_batteryLevelCase"]),
                        main: part(info["device_batteryLevelMain"] ?? info["device_batteryLevel"])
                    )
                    if device.hasLevels { result[name] = device }
                }
            }
        }
        return result
    }

    private nonisolated static func kind(name: String, productID: Int, category: String?) -> Device.Kind {
        // Apple product IDs: AirPods Pro 0x200E / 0x2014 / 0x2024 / 0x2027; other AirPods 0x2002, 0x200F, 0x2013, 0x2019, 0x201B.
        if [0x200E, 0x2014, 0x2024, 0x2027].contains(productID) || name.localizedCaseInsensitiveContains("airpods pro") {
            return .airPodsPro
        }
        if [0x2002, 0x200F, 0x2013, 0x2019, 0x201B].contains(productID) || name.localizedCaseInsensitiveContains("airpod") {
            return .airPods
        }
        return ["Headphones", "Headset"].contains(category ?? "") ? .headphones : .other
    }

    // MARK: Remembered case level

    private struct SavedPart: Codable { let level: Int; let date: Date }

    private func saveLastCase() {
        let saved = lastCase.compactMapValues { p in p.lastSeen.map { SavedPart(level: p.level, date: $0) } }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "lastCaseBattery")
        }
    }
}
