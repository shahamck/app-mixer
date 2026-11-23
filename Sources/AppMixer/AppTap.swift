import CoreAudio
import Foundation

/// State shared with the real-time IO thread. Plain memory, no locks: Float writes are atomic enough for a gain knob.
private struct IOState {
    var targetGain: Float
    var currentGain: Float
    var peakIn: Float = 0
    var peakOut: Float = 0
}

/// Takes over one app's audio:
/// 1. a process tap captures the app's processes and mutes their normal output,
/// 2. a private aggregate device (tap + chosen output device) runs an IOProc,
/// 3. the IOProc copies tap → output, scaled by the gain.
final class AppTap {
    let processObjects: Set<AudioObjectID>
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let state: UnsafeMutablePointer<IOState>

    var gain: Float {
        get { state.pointee.targetGain }
        set { state.pointee.targetGain = max(0, min(newValue, 2)) }
    }

    /// Peak levels since the last call (for debugging / self-test).
    func takePeaks() -> (input: Float, output: Float) {
        let p = (state.pointee.peakIn, state.pointee.peakOut)
        state.pointee.peakIn = 0
        state.pointee.peakOut = 0
        return p
    }

    init(processObjects: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processObjects = Set(processObjects)
        self.outputUID = outputUID
        state = .allocate(capacity: 1)
        state.initialize(to: IOState(targetGain: gain, currentGain: gain))

        do {
            try start(processObjects: processObjects)
        } catch {
            teardown()
            state.deallocate()
            throw error
        }
    }

    deinit {
        teardown()
        state.deallocate()
    }

    private func start(processObjects: [AudioObjectID]) throws {
        // 1. Tap
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "AppMixer"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try caCheck(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")

        let format: AudioStreamBasicDescription = CA.scalar(
            tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBufferCount = nonInterleaved ? max(1, Int(format.mChannelsPerFrame)) : 1

        // 2. Aggregate device: output device as clock master, tap as input.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppMixer",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try caCheck(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                    "Create aggregate device")

        // 3. IOProc
        let state = self.state
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inData, _, outData, _ in
            AppTap.render(input: inData, output: outData, tapBufferCount: tapBufferCount, state: state)
        }, "Create IOProc")

        // The output device may have its own inputs (e.g. AirPods mic). We only want the tap,
        // so switch the device's input streams off — otherwise Bluetooth headsets drop to call quality.
        disableSubDeviceInputs()

        try caCheck(AudioDeviceStart(aggregateID, procID), "Start audio")
    }

    private func disableSubDeviceInputs() {
        guard let procID,
              let device = CA.outputDevices().first(where: { $0.uid == outputUID }) else { return }
        let deviceInputs = CA.objectIDs(device.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count
        guard deviceInputs > 0 else { return }

        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr,
              let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let streamCount = Int(usage.pointee.mNumberStreams)
        let flags = (raw + offset).assumingMemoryBound(to: UInt32.self)
        // Sub-device streams come first, the tap's stream(s) last.
        for i in 0..<min(deviceInputs, streamCount) { flags[i] = 0 }
        AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, size, raw)
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Real-time render (no allocation, no locks)

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               tapBufferCount: Int,
                               state: UnsafeMutablePointer<IOState>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outs where buffer.mData != nil {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }

        // Locate left/right source channels: the tap's buffers are the last ones in the input list.
        guard ins.count >= tapBufferCount else { return }
        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?
        var stride = 1
        var frames = 0
        if tapBufferCount == 1 {
            let b = ins[ins.count - 1]
            guard let p = b.mData?.assumingMemoryBound(to: Float.self), b.mNumberChannels > 0 else { return }
            stride = Int(b.mNumberChannels)
            left = p
            right = stride > 1 ? p + 1 : p
            frames = Int(b.mDataByteSize) / (4 * stride)
        } else {
            let bl = ins[ins.count - tapBufferCount]
            let br = ins[ins.count - tapBufferCount + 1]
            guard let pl = bl.mData?.assumingMemoryBound(to: Float.self),
                  let pr = br.mData?.assumingMemoryBound(to: Float.self) else { return }
            left = pl
            right = pr
            frames = Int(min(bl.mDataByteSize, br.mDataByteSize)) / 4
        }
        guard let left, let right, frames > 0 else { return }

        let start = state.pointee.currentGain
        let target = state.pointee.targetGain
        let totalOutChannels = outs.reduce(0) { $0 + Int($1.mNumberChannels) }
        var peakIn = state.pointee.peakIn
        var peakOut = state.pointee.peakOut

        var channelBase = 0
        for buffer in outs {
            let channels = Int(buffer.mNumberChannels)
            defer { channelBase += channels }
            guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self), channels > 0 else { continue }
            let n = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
            guard n > 0 else { continue }
            let step = (target - start) / Float(n)
            for c in 0..<channels {
                let globalChannel = channelBase + c
                guard globalChannel < 2 else { continue } // extra channels stay silent
                for f in 0..<n {
                    let l = left[f * stride], r = right[f * stride]
                    let sample: Float
                    if totalOutChannels == 1 { sample = (l + r) * 0.5 }
                    else { sample = globalChannel == 0 ? l : r }
                    let g = start + step * Float(f)
                    let out = sample * g
                    dst[f * channels + c] = out
                    peakIn = max(peakIn, abs(sample))
                    peakOut = max(peakOut, abs(out))
                }
            }
        }

        state.pointee.currentGain = target
        state.pointee.peakIn = peakIn
        state.pointee.peakOut = peakOut
    }
}
