import Combine
import CoreAudio
import Foundation

/// Headphone sensitivity as printed on a spec sheet. Passive headphones can't report it.
struct Sensitivity: Codable, Equatable {
    var value: Double?
    /// True when `value` is dB SPL per milliwatt, which needs `impedance` to convert.
    var perMilliwatt = false
    var impedance: Double?
    /// Name of the database model these figures came from, if any.
    var model: String?

    /// dB SPL produced by 1 V RMS.
    var decibelsPerVolt: Double? {
        guard let value else { return nil }
        guard perMilliwatt else { return value }
        guard let impedance, impedance > 0 else { return nil }
        return value + 10 * log10(1000 / impedance)
    }
}

@MainActor
final class Limiter: ObservableObject {
    static let shared = Limiter()
    static let limitRange: ClosedRange<Double> = -60...0
    static let defaultLimit = -15.0

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); enforce() }
    }

    /// Maximum allowed gain in dB relative to the device's full output (0 dB = no limit).
    @Published var limit: Double {
        didSet { defaults.set(limit, forKey: Keys.limit); enforce() }
    }

    /// When on, limited outputs are attenuated in software so their volume control runs from
    /// mute to the limit. When off (or unavailable), the volume control itself is pulled back.
    @Published var rescale: Bool {
        didSet { defaults.set(rescale, forKey: Keys.rescale); failedRescales = []; enforce() }
    }
    /// UIDs of the devices currently being attenuated in software.
    @Published private(set) var rescaledUIDs: Set<String> = []

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID = 0
    /// Current output level per device in dB relative to its maximum, software attenuation included.
    @Published private(set) var volumes: [AudioDeviceID: Float32] = [:]
    /// Per-device user choice, keyed by device UID. Absent means "auto-detect".
    @Published private(set) var overrides: [String: Bool]

    /// Per-device headphone sensitivity, keyed by device UID.
    @Published var sensitivities: [String: Sensitivity] {
        didSet { defaults.set(try? JSONEncoder().encode(sensitivities), forKey: Keys.sensitivities) }
    }
    /// DAC or amp model picked by hand per device UID. Absent means "match by device name".
    @Published var sourceChoices: [String: String] {
        didSet { defaults.set(sourceChoices, forKey: Keys.sources) }
    }
    /// Full-scale RMS voltage the headphone jack's DAC reports for the current load.
    @Published private(set) var jackVoltage: Double?

    private enum Keys {
        static let sensitivities = "deviceSensitivities"
        static let sources = "deviceSources"
        static let enabled = "enabled"
        static let rescale = "rescale"
        static let limit = "limitDecibels"
        static let overrides = "deviceOverrides"
    }

    private let defaults = UserDefaults.standard
    private var systemListeners: [CoreAudioHelper.Listener] = []
    private var deviceListeners: [CoreAudioHelper.Listener] = []
    private var timer: Timer?
    private var rescalers: [String: Rescaler] = [:]
    /// Devices whose rescaler couldn't start; they fall back to clamping until something changes.
    private var failedRescales: Set<String> = []

    private init() {
        defaults.register(defaults: [Keys.enabled: true, Keys.rescale: true, Keys.limit: Self.defaultLimit])
        enabled = defaults.bool(forKey: Keys.enabled)
        rescale = defaults.bool(forKey: Keys.rescale)
        let stored = defaults.double(forKey: Keys.limit)
        limit = min(max(stored, Self.limitRange.lowerBound), Self.limitRange.upperBound)
        overrides = (defaults.dictionary(forKey: Keys.overrides) as? [String: Bool]) ?? [:]
        sensitivities = defaults.data(forKey: Keys.sensitivities)
            .flatMap { try? JSONDecoder().decode([String: Sensitivity].self, from: $0) } ?? [:]
        sourceChoices = (defaults.dictionary(forKey: Keys.sources) as? [String: String]) ?? [:]

        for address in CoreAudioHelper.systemListenerAddresses() {
            if let listener = CoreAudioHelper.listen(AudioObjectID(kAudioObjectSystemObject), address, { [weak self] in
                MainActor.assumeIsolated { self?.reloadDevices() }
            }) {
                systemListeners.append(listener)
            }
        }
        reloadDevices()

        // Safety net in case a device never delivers a change notification.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.enforce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func isLimited(_ device: AudioDevice) -> Bool {
        overrides[device.uid] ?? device.looksLikeHeadphones
    }

    func setLimited(_ limited: Bool, for device: AudioDevice) {
        overrides[device.uid] = limited
        defaults.set(overrides, forKey: Keys.overrides)
        enforce()
    }

    /// True when the device currently playing system audio is being capped.
    var isLimitingCurrentOutput: Bool {
        guard enabled, let device = devices.first(where: { $0.id == defaultDeviceID }) else { return false }
        return device.canSetVolume && isLimited(device)
    }

    /// Hands limited devices back to plain clamping, so quitting never leaves them louder than the limit.
    func shutdown() {
        timer?.invalidate()
        for device in devices where rescalers[device.uid] != nil {
            CoreAudioHelper.clamp(device.id, toDecibels: Float32(limit))
        }
        rescalers = [:]
    }

    var currentDevice: AudioDevice? { devices.first { $0.id == defaultDeviceID } }

    /// The external DAC or amp behind a device: the user's pick, else a match on the device name.
    /// Nil for the Mac's own jack, which reports its voltage directly.
    func source(for device: AudioDevice) -> SourceModel? {
        guard !device.isHeadphoneJack else { return nil }
        return Database.source(named: sourceChoices[device.uid]) ?? Database.source(matchingDeviceName: device.name)
    }

    /// Full-scale RMS voltage at 0 dB volume: read from the Mac's jack, or looked up for a known DAC.
    func fullScaleVoltage(_ device: AudioDevice) -> Double? {
        if device.isHeadphoneJack { return jackVoltage }
        return source(for: device)?.voltage(into: sensitivities[device.uid]?.impedance)
    }

    /// Loudest level the limit allows, in dB SPL, for a full-scale sine.
    func limitSPL(_ device: AudioDevice) -> Double? {
        guard let voltage = fullScaleVoltage(device), let perVolt = sensitivities[device.uid]?.decibelsPerVolt else { return nil }
        return perVolt + 20 * log10(voltage) + limit
    }

    private func reloadDevices() {
        let latest = CoreAudioHelper.outputDevices()
        if latest != devices {
            devices = latest
            failedRescales = []
            deviceListeners.forEach(CoreAudioHelper.remove)
            deviceListeners = []
            for device in latest {
                for address in CoreAudioHelper.deviceListenerAddresses() {
                    if let listener = CoreAudioHelper.listen(device.id, address, { [weak self] in
                        MainActor.assumeIsolated { self?.deviceChanged() }
                    }) {
                        deviceListeners.append(listener)
                    }
                }
            }
        }
        let current = CoreAudioHelper.defaultOutputDevice()
        if current != defaultDeviceID { defaultDeviceID = current }
        enforce()
    }

    private func deviceChanged() {
        // A data source change (e.g. plugging into the jack) alters how a device is classified.
        let latest = CoreAudioHelper.outputDevices()
        if latest != devices { reloadDevices() } else { enforce() }
    }

    /// Applies the limit to every limited device, then refreshes displayed volumes.
    /// Apps can play to any device, not just the system default, so all of them are checked.
    private func enforce() {
        let cap = Float32(limit)
        var latest: [AudioDeviceID: Float32] = [:]
        for uid in rescalers.keys where !devices.contains(where: { $0.uid == uid }) {
            rescalers[uid] = nil
        }
        for device in devices where device.canSetVolume {
            let limited = enabled && isLimited(device)
            if limited, rescale, rescalers[device.uid] == nil, !failedRescales.contains(device.uid) {
                rescalers[device.uid] = Rescaler(deviceUID: device.uid, decibels: limit)
                if rescalers[device.uid] == nil { failedRescales.insert(device.uid) }
                NSLog("Rescaling %@: %@", device.name, rescalers[device.uid] == nil ? "failed, clamping instead" : "started")
            }
            if limited, rescale, let rescaler = rescalers[device.uid] {
                rescaler.setGain(decibels: limit)
            } else {
                // Pull the hardware volume down before the software attenuation goes away.
                if limited { CoreAudioHelper.clamp(device.id, toDecibels: cap) }
                rescalers[device.uid] = nil
            }
            if let volume = CoreAudioHelper.decibels(device.id) {
                latest[device.id] = volume + (rescalers[device.uid] == nil ? 0 : cap)
            }
        }
        let active = Set(rescalers.keys)
        if active != rescaledUIDs { rescaledUIDs = active }
        if latest != volumes { volumes = latest }
        let voltage = HeadphoneJack.fullScaleVoltage()
        if voltage != jackVoltage { jackVoltage = voltage }
    }
}
