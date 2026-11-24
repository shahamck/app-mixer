import AppKit
import AudioToolbox
import CoreAudio
import Darwin

/// Prefix for the private aggregate devices this app creates, so we can hide them from the device list.
let aggregateUIDPrefix = "studio.b1t.appmixer.agg."

struct CAError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String { "\(what) failed (\(fourCC(status)))" }
}

func caCheck(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CAError(status: status, what: what) }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return "\(status)"
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

/// Thin wrappers around the Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          default fallback: T) -> T {
        var addr = address(selector, scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? value : fallback
    }

    static func objectIDs(_ object: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / stride))
    }

    static func string(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let ref else { return nil }
        let value = ref.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    // MARK: Devices

    static func outputDevices() -> [AudioDevice] { devices(input: false) }
    static func inputDevices() -> [AudioDevice] { devices(input: true) }

    static func devices(input: Bool) -> [AudioDevice] {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return objectIDs(system, kAudioHardwarePropertyDevices).compactMap { dev in
            guard !objectIDs(dev, kAudioDevicePropertyStreams, scope).isEmpty,
                  let uid = string(dev, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(aggregateUIDPrefix),
                  let name = string(dev, kAudioObjectPropertyName)
            else { return nil }
            return AudioDevice(id: dev, uid: uid, name: name)
        }
    }

    /// A real, connected device (speakers, headphones, USB, HDMI, AirPlay…), not a virtual or aggregate one.
    static func isPhysical(_ device: AudioObjectID) -> Bool {
        let transport: UInt32 = scalar(device, kAudioDevicePropertyTransportType, default: 0)
        let excluded: Set<UInt32> = [0, kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                                     kAudioDeviceTransportTypeAutoAggregate]
        let alive: UInt32 = scalar(device, kAudioDevicePropertyDeviceIsAlive, default: 1)
        return !excluded.contains(transport) && alive != 0
    }

    static func defaultOutputDeviceID() -> AudioObjectID { defaultDeviceID(input: false) }

    static func defaultDeviceID(input: Bool) -> AudioObjectID {
        scalar(system, input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
               default: AudioObjectID(kAudioObjectUnknown))
    }

    static func setDefaultDevice(_ device: AudioObjectID, input: Bool) {
        var id = device
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(system, &addr, 0, nil, size, &id)
        if !input {
            // Keep alerts and sound effects on the same device, like System Settings does.
            var sysAddr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(system, &sysAddr, 0, nil, size, &id)
        }
    }

    // MARK: Device volume and mute

    private static func scope(_ input: Bool) -> AudioObjectPropertyScope {
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    /// Main volume 0…1, or nil if the device has no software-controllable volume.
    static func volume(_ device: AudioObjectID, input: Bool) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(input))
        guard AudioHardwareServiceHasProperty(device, &addr) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioHardwareServiceIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ device: AudioObjectID, input: Bool, _ volume: Float) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(input))
        var value = Float32(max(0, min(1, volume)))
        AudioHardwareServiceSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// Hardware mute state, or nil if the device can't be muted directly.
    static func isMuted(_ device: AudioObjectID, input: Bool) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, scope(input))
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return nil }
        return scalar(device, kAudioDevicePropertyMute, scope(input), default: UInt32(0)) != 0
    }

    static func setMuted(_ device: AudioObjectID, input: Bool, _ muted: Bool) {
        var addr = address(kAudioDevicePropertyMute, scope(input))
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Processes

    static func audioProcesses() -> [AudioProcess] {
        objectIDs(system, kAudioHardwarePropertyProcessObjectList).map { obj in
            AudioProcess(
                objectID: obj,
                pid: scalar(obj, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: string(obj, kAudioProcessPropertyBundleID),
                isRunningOutput: scalar(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0,
                isRunningInput: scalar(obj, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0
            )
        }
    }
}

/// Audio is often rendered by helper processes (Chrome Helper, WebKit GPU process…).
/// The "responsible" PID points back at the app the user actually sees.
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

/// Executable name for processes without an app bundle (e.g. `afplay`).
func processName(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

func responsiblePID(for pid: pid_t) -> pid_t {
    guard let fn = responsibleFn else { return pid }
    let owner = fn(pid)
    return owner > 0 ? owner : pid
}
