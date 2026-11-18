import CoreAudio
import Foundation
import IOKit

private func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

/// The volume the macOS volume keys and menu bar slider control (0.0 – 1.0).
private let virtualMainVolume = AudioObjectPropertySelector(fourCC("vmvc"))
/// Data source reported by older Macs when something is plugged into the headphone jack.
private let headphonesDataSource = fourCC("hdpn")

private let outputScope = kAudioObjectPropertyScopeOutput
private let systemObject = AudioObjectID(kAudioObjectSystemObject)

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let dataSource: UInt32?
    let canSetVolume: Bool
    /// False when the device has no decibel control and the dB figures are estimates.
    let hasDecibelControl: Bool

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Best guess; the user can override it per device in the menu.
    var looksLikeHeadphones: Bool {
        let lower = name.lowercased()
        let speakerWords = ["speaker", "soundbar", "homepod", "display", "monitor", "tv"]
        let headphoneWords = [
            "headphone", "headset", "airpods", "earbuds", "earphone", "earpods",
            "buds", "beats", "in-ear", "wh-1000", "wf-1000", "quietcomfort",
        ]
        if headphoneWords.contains(where: lower.contains) { return true }
        if dataSource == headphonesDataSource { return true }
        if speakerWords.contains(where: lower.contains) { return false }
        // Most Bluetooth audio outputs are worn on the head; err on the safe side.
        return isBluetooth
    }

    /// The Mac's own 3.5 mm jack, whose DAC reports the output mode it picked for the plugged-in load.
    var isHeadphoneJack: Bool {
        transport == kAudioDeviceTransportTypeBuiltIn && (dataSource == headphonesDataSource || looksLikeHeadphones)
    }

    var transportLabel: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return "Other"
        }
    }
}

enum CoreAudioHelper {
    typealias Listener = (object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: Reading

    private static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func write(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Float32) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    // MARK: Devices

    static func defaultOutputDevice() -> AudioDeviceID {
        read(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioDeviceID(0)) ?? 0
    }

    static func outputDevices() -> [AudioDevice] {
        var listAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &listAddress, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            // Only devices that actually have output streams.
            var streams = address(kAudioDevicePropertyStreams, scope: outputScope)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            guard let uid = readString(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(Rescaler.uidPrefix) else { return nil }

            return AudioDevice(
                id: id,
                uid: uid,
                name: readString(id, kAudioObjectPropertyName) ?? "Unknown device",
                transport: read(id, address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0,
                dataSource: read(id, address(kAudioDevicePropertyDataSource, scope: outputScope), initial: UInt32(0)),
                canSetVolume: !volumeAddresses(id).isEmpty || !decibelAddresses(id).isEmpty,
                hasDecibelControl: !decibelAddresses(id).isEmpty
            )
        }
    }

    // MARK: Volume

    private static let channelElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    /// Settable volume controls for a device: the virtual main volume when available,
    /// otherwise the raw per-channel controls.
    private static func volumeAddresses(_ id: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let main = address(virtualMainVolume, scope: outputScope)
        if isSettable(id, main) { return [main] }
        return channelElements
            .map { address(kAudioDevicePropertyVolumeScalar, scope: outputScope, element: $0) }
            .filter { isSettable(id, $0) }
    }

    /// The device's own gain controls in decibels (0 dB = the device's maximum output).
    private static func decibelAddresses(_ id: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        channelElements
            .map { address(kAudioDevicePropertyVolumeDecibels, scope: outputScope, element: $0) }
            .filter { isSettable(id, $0) }
    }

    /// Stand-in span for devices that expose no decibel control: their 0–100% volume is
    /// treated as a straight line across this many dB. Only an estimate.
    private static let estimatedSpan: Float32 = 63.5

    /// Loudest current gain on the device in dB relative to its maximum (always <= 0).
    static func decibels(_ id: AudioDeviceID) -> Float32? {
        let exact = decibelAddresses(id).compactMap { read(id, $0, initial: Float32(0)) }
        if let loudest = exact.max() { return loudest }
        return volumeAddresses(id).compactMap { read(id, $0, initial: Float32(0)) }.max().map { ($0 - 1) * estimatedSpan }
    }

    /// Lowers any gain control above `cap` dB. Returns true if something was lowered.
    @discardableResult
    static func clamp(_ id: AudioDeviceID, toDecibels cap: Float32) -> Bool {
        var lowered = false
        let exact = decibelAddresses(id)
        if !exact.isEmpty {
            for control in exact {
                guard let current = read(id, control, initial: Float32(0)), current > cap + 0.05 else { continue }
                if write(id, control, cap) { lowered = true }
            }
            return lowered
        }
        let scalarCap = max(0, min(1, 1 + cap / estimatedSpan))
        for control in volumeAddresses(id) {
            guard let current = read(id, control, initial: Float32(0)), current > scalarCap + 0.004 else { continue }
            if write(id, control, scalarCap) { lowered = true }
        }
        return lowered
    }

    // MARK: Listeners

    static func systemListenerAddresses() -> [AudioObjectPropertyAddress] {
        [address(kAudioHardwarePropertyDevices), address(kAudioHardwarePropertyDefaultOutputDevice)]
    }

    static func deviceListenerAddresses() -> [AudioObjectPropertyAddress] {
        [address(virtualMainVolume, scope: outputScope), address(kAudioDevicePropertyDataSource, scope: outputScope)]
            + channelElements.map { address(kAudioDevicePropertyVolumeScalar, scope: outputScope, element: $0) }
            + channelElements.map { address(kAudioDevicePropertyVolumeDecibels, scope: outputScope, element: $0) }
    }

    static func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) -> Listener? {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return nil }
        return (object, address, block)
    }

    static func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
    }
}

/// What the Mac's headphone DAC reports about itself and the load on the jack.
///
/// The codec measures the plugged-in headphones' impedance and publishes the output mode it
/// chose as `DCIDMode` in the IORegistry. Apple documents the full-scale level per mode:
/// 1.25 V RMS below 150 ohms, 3 V RMS from 150 ohms to 1 kilohm.
@MainActor
enum HeadphoneJack {
    private static var codec: io_registry_entry_t = 0

    /// Raw mode string from the codec, e.g. "Low Impedance". Nil on Macs without this detection.
    static func mode() -> String? {
        if codec == 0 { codec = findCodec() }
        guard codec != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(codec, "DCIDMode" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// RMS voltage of a full-scale sine at 0 dB volume, or nil when the mode is unknown.
    static func fullScaleVoltage() -> Double? {
        guard let mode = mode()?.lowercased().filter({ $0.isLetter || $0.isNumber }) else { return nil }
        if mode.contains("highimpedance") { return 3.0 }
        if mode.contains("lowimpedance") { return 1.25 }
        if mode.contains("1vrms") { return 1.0 }
        return nil
    }

    private static func findCodec() -> io_registry_entry_t {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if let value = IORegistryEntryCreateCFProperty(entry, "DCIDMode" as CFString, kCFAllocatorDefault, 0) {
                value.release()
                return entry
            }
            IOObjectRelease(entry)
        }
        return 0
    }
}
