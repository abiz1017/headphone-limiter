import CoreAudio
import Foundation

/// Takes over everything playing to one output device and replays it attenuated, so the
/// device's own volume control keeps its whole range while the output never exceeds the limit.
///
/// A muting process tap captures the audio headed for the device; a private aggregate device
/// joins that tap to the real device, and the IO callback copies tap to device with a fixed gain.
final class Rescaler {
    /// Prefix of the private aggregate devices, so they can be kept out of the device list.
    static let uidPrefix = "local.headphone-limiter.rescaler."

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Linear gain read by the audio thread.
    private let gain = UnsafeMutablePointer<Float32>.allocate(capacity: 1)

    init?(deviceUID: String, decibels: Double) {
        gain.initialize(to: 0)
        setGain(decibels: decibels)

        let description = CATapDescription(excludingProcesses: Self.ownProcessObject(), deviceUID: deviceUID, stream: 0)
        description.name = "Headphone Limiter"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Headphone Limiter",
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            stop()
            return nil
        }

        let gain = gain
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            Self.render(from: input, to: output, gain: gain.pointee)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            stop()
            return nil
        }
    }

    deinit {
        stop()
        gain.deallocate()
    }

    func setGain(decibels: Double) {
        gain.pointee = Float32(pow(10, min(decibels, 0) / 20))
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// This app's own audio must stay out of the tap, or its output would feed back into itself.
    private static func ownProcessObject() -> [AudioObjectID] {
        var address = CoreAudioHelper.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    // MARK: Audio thread

    /// Copies the tapped audio to the device, clipped to full scale and then attenuated.
    /// Runs on the realtime audio thread: no allocation, no locks.
    private static func render(from input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>, gain: Float32) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var inputChannels = 0
        for buffer in inputs where buffer.mData != nil { inputChannels += Int(buffer.mNumberChannels) }

        var channel = 0
        for buffer in outputs {
            let stride = Int(buffer.mNumberChannels)
            guard stride > 0, let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * stride)
            for offset in 0..<stride {
                // Extra output channels repeat the last input channel (mono plays on both sides).
                var wanted = min(channel, inputChannels - 1)
                channel += 1
                var copied = 0
                if wanted >= 0 {
                    for source in inputs {
                        let sourceStride = Int(source.mNumberChannels)
                        guard sourceStride > 0, let sourceData = source.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                        if wanted >= sourceStride { wanted -= sourceStride; continue }
                        copied = min(frames, Int(source.mDataByteSize) / (MemoryLayout<Float32>.size * sourceStride))
                        for frame in 0..<copied {
                            let sample = sourceData[frame * sourceStride + wanted]
                            data[frame * stride + offset] = max(-1, min(1, sample)) * gain
                        }
                        break
                    }
                }
                for frame in copied..<frames { data[frame * stride + offset] = 0 }
            }
        }
    }
}
