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
/// 2. a private aggregate device (tap + one or more output devices) runs an IOProc,
/// 3. the IOProc copies tap → every output device, scaled by the gain.
final class AppTap {
    let processObjects: Set<AudioObjectID>
    /// Output devices this app plays on, in order; the first is the clock master.
    let outputUIDs: [String]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let state: UnsafeMutablePointer<IOState>
    /// Per output buffer of the aggregate: channels before it within its own device, and that device's channel count.
    /// Lets each device get its own left/right, even when several devices share one aggregate.
    private var channelMap: UnsafeMutablePointer<Int32>?
    private var channelMapCount = 0

    var gain: Float {
        get { state.pointee.targetGain }
        set { state.pointee.targetGain = max(0, min(newValue, 2)) }
    }

    /// For the self-test: how the aggregate's output buffers line up with the per-device channel map.
    var debugDescription: String {
        let streams = CA.objectIDs(aggregateID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).count
        return "outputs \(outputUIDs.count), aggregate output streams \(streams), channel map entries \(channelMapCount)"
    }

    /// Peak levels since the last call (for debugging / self-test).
    func takePeaks() -> (input: Float, output: Float) {
        let p = (state.pointee.peakIn, state.pointee.peakOut)
        state.pointee.peakIn = 0
        state.pointee.peakOut = 0
        return p
    }

    convenience init(processObjects: [AudioObjectID], outputUID: String, gain: Float) throws {
        try self.init(processObjects: processObjects, outputUIDs: [outputUID], gain: gain)
    }

    init(processObjects: [AudioObjectID], outputUIDs: [String], gain: Float) throws {
        precondition(!outputUIDs.isEmpty)
        self.processObjects = Set(processObjects)
        self.outputUIDs = outputUIDs
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
        channelMap?.deallocate()
    }

    private func start(processObjects: [AudioObjectID]) throws {
        // 1. Tap
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "AUDIX"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try caCheck(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")

        let format: AudioStreamBasicDescription = CA.scalar(
            tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBufferCount = nonInterleaved ? max(1, Int(format.mChannelsPerFrame)) : 1

        // 2. Aggregate device: output devices (first one is the clock master; the others are kept in step
        //    with drift compensation), tap as input.
        let subDevices: [[String: Any]] = outputUIDs.enumerated().map { index, uid in
            [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: index > 0]
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AUDIX",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUIDs[0],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try caCheck(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                    "Create aggregate device")

        buildChannelMap()

        // 3. IOProc
        let state = self.state
        let map = channelMap, mapCount = channelMapCount
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inData, _, outData, _ in
            AppTap.render(input: inData, output: outData, tapBufferCount: tapBufferCount,
                          channelMap: map, channelMapCount: mapCount, state: state)
        }, "Create IOProc")

        // The output device may have its own inputs (e.g. AirPods mic). We only want the tap,
        // so switch the device's input streams off — otherwise Bluetooth headsets drop to call quality.
        disableSubDeviceInputs()

        try caCheck(AudioDeviceStart(aggregateID, procID), "Start audio")
    }

    /// The aggregate's output buffers are the sub-devices' output streams, in sub-device order.
    private func buildChannelMap() {
        let devices = CA.outputDevices()
        var entries: [Int32] = []
        for uid in outputUIDs {
            guard let device = devices.first(where: { $0.uid == uid }) else { continue }
            let streams = CA.objectIDs(device.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            let channels = streams.map { stream -> Int in
                let asbd: AudioStreamBasicDescription = CA.scalar(stream, kAudioStreamPropertyVirtualFormat,
                                                                  default: AudioStreamBasicDescription())
                return max(1, Int(asbd.mChannelsPerFrame))
            }
            let total = channels.reduce(0, +)
            var before = 0
            for count in channels {
                entries += [Int32(before), Int32(total)]
                before += count
            }
        }
        channelMapCount = entries.count / 2
        let map = UnsafeMutablePointer<Int32>.allocate(capacity: max(entries.count, 1))
        map.initialize(from: entries, count: entries.count)
        channelMap = map
    }

    private func disableSubDeviceInputs() {
        guard let procID else { return }
        let devices = CA.outputDevices()
        let deviceInputs = outputUIDs.reduce(0) { sum, uid in
            guard let device = devices.first(where: { $0.uid == uid }) else { return sum }
            return sum + CA.objectIDs(device.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count
        }
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
                               channelMap: UnsafeMutablePointer<Int32>?,
                               channelMapCount: Int,
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
        // Use the per-device channel map when it matches the buffers; otherwise treat each buffer as its own device.
        let mapped = channelMap != nil && channelMapCount == outs.count
        var peakIn = state.pointee.peakIn
        var peakOut = state.pointee.peakOut

        for (index, buffer) in outs.enumerated() {
            let channels = Int(buffer.mNumberChannels)
            guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self), channels > 0 else { continue }
            let before = mapped ? Int(channelMap![index * 2]) : 0
            let deviceChannels = mapped ? Int(channelMap![index * 2 + 1]) : channels
            let n = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
            guard n > 0 else { continue }
            let step = (target - start) / Float(n)
            for c in 0..<channels {
                let deviceChannel = before + c
                guard deviceChannel < 2 else { continue } // each device: left, right; extra channels stay silent
                for f in 0..<n {
                    let l = left[f * stride], r = right[f * stride]
                    let sample: Float
                    if deviceChannels == 1 { sample = (l + r) * 0.5 }
                    else { sample = deviceChannel == 0 ? l : r }
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
