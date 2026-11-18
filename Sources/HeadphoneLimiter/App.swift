import ServiceManagement
import SwiftUI

@main
enum Entry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--status") {
            printStatus()
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--lookup"), CommandLine.arguments.count > flag + 1 {
            printLookup(CommandLine.arguments[flag + 1])
            return
        }
        LimiterApp.main()
    }

    /// Diagnostic: `HeadphoneLimiter --lookup "hd 600"` searches the bundled model database.
    private static func printLookup(_ query: String) {
        for model in Database.searchHeadphones(query) {
            print("headphones |", model.name, "| \(model.impedance) Ω | \(model.perMilliwatt) dB/mW", model.unitStated ? "" : "| unit not stated")
        }
        for source in Database.searchSources(query) {
            print("source |", source.name, "|", source.outputs.map { "\($0.volts) V into \($0.load) Ω" }.joined(separator: ", "))
        }
        if let match = Database.source(matchingDeviceName: query) { print("device-name match |", match.name) }
        print("\(Database.headphones.count) headphones, \(Database.sources.count) sources in the database")
    }

    /// Diagnostic: `HeadphoneLimiter --status` lists output devices and how they are classified.
    @MainActor private static func printStatus() {
        let current = CoreAudioHelper.defaultOutputDevice()
        for device in CoreAudioHelper.outputDevices() {
            let volume = CoreAudioHelper.decibels(device.id).map { decibels(Double($0)) + (device.hasDecibelControl ? "" : " (est.)") } ?? "n/a"
            print(
                device.id == current ? "*" : " ",
                device.name,
                "| \(device.transportLabel)",
                "| volume \(volume)",
                "| adjustable: \(device.canSetVolume)",
                "| headphones (auto): \(device.looksLikeHeadphones)",
                device.isHeadphoneJack ? "| jack" : ""
            )
        }
        let voltage = HeadphoneJack.fullScaleVoltage().map { "\($0) V RMS full scale" } ?? "voltage unknown"
        print("Headphone jack DAC mode: \(HeadphoneJack.mode() ?? "not reported") (\(voltage))")
    }
}

/// Opening the app again while it is running (Finder, Spotlight, Launchpad) shows the
/// controls in a normal window, so they stay reachable when the menu bar icon is hidden
/// behind the notch on a crowded menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Limiter.shared.shutdown()
    }

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MenuView(limiter: .shared)))
            window.title = "Headphone Limiter"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct LimiterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var limiter = Limiter.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(limiter: limiter)
        } label: {
            Image(systemName: limiter.isLimitingCurrentOutput ? "headphones.circle.fill" : "headphones")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @ObservedObject var limiter: Limiter
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $limiter.enabled) {
                Text("Headphone Limiter").font(.headline)
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Maximum volume")
                    Spacer()
                    Text(limitText).monospacedDigit().foregroundStyle(.secondary)
                }
                .help("Decibels below the output's full volume (0 dB).")
                Slider(value: $limiter.limit, in: Limiter.limitRange, step: 1) {
                    Text("Maximum volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.wave.1")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3")
                }
                .labelsHidden()
                Toggle("Rescale the volume range", isOn: $limiter.rescale)
                    .padding(.top, 4)
                    .help("On: the volume keys run from mute up to the limit. Audio passes through this app, which needs audio recording permission. Off: volume above the limit is pulled back down.")
                if let device = limiter.currentDevice {
                    AbsoluteLevel(limiter: limiter, device: device)
                }
            }
            .disabled(!limiter.enabled)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Limit these outputs").font(.subheadline).foregroundStyle(.secondary)
                ForEach(limiter.devices) { device in
                    DeviceRow(limiter: limiter, device: device)
                }
            }
            .disabled(!limiter.enabled)

            Divider()

            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Quit Headphone Limiter") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var limitText: String {
        guard let spl = limiter.currentDevice.flatMap(limiter.limitSPL) else { return decibels(limiter.limit) }
        return "\(decibels(limiter.limit)) · ≤ \(Int(spl.rounded())) dB SPL"
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Turns the relative limit into dB SPL for the current output. The DAC's full-scale voltage
/// is read from the Mac's jack or looked up by model; the headphones' sensitivity is looked up
/// by model or typed in.
private struct AbsoluteLevel: View {
    @ObservedObject var limiter: Limiter
    let device: AudioDevice

    var body: some View {
        let sensitivity = Binding(
            get: { limiter.sensitivities[device.uid] ?? Sensitivity() },
            set: { limiter.sensitivities[device.uid] = $0 }
        )
        VStack(alignment: .leading, spacing: 6) {
            if !device.isHeadphoneJack {
                ModelSearch(
                    prompt: limiter.source(for: device)?.name ?? "Search DAC or amp model",
                    results: { Database.searchSources($0).map { ($0.name, "\($0.voltage(into: nil).formatted(.number.precision(.fractionLength(2)))) V") } },
                    pick: { limiter.sourceChoices[device.uid] = $0 }
                )
            }
            ModelSearch(
                prompt: sensitivity.wrappedValue.model ?? "Search headphone model",
                results: { Database.searchHeadphones($0).map { ($0.name, "\($0.perMilliwatt.formatted()) dB/mW · \($0.impedance.formatted()) Ω") } },
                pick: { name in
                    guard let model = Database.headphone(named: name) else { return }
                    sensitivity.wrappedValue = Sensitivity(value: model.perMilliwatt, perMilliwatt: true, impedance: model.impedance, model: name)
                }
            )
            HStack(spacing: 6) {
                Text("Sensitivity")
                TextField("e.g. 100", value: sensitivity.value, format: .number)
                    .frame(width: 60)
                Picker("Unit", selection: sensitivity.perMilliwatt) {
                    Text("dB/V").tag(false)
                    Text("dB/mW").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                if sensitivity.wrappedValue.perMilliwatt {
                    TextField("Ω", value: sensitivity.impedance, format: .number)
                        .frame(width: 44)
                    Text("Ω")
                }
                Spacer(minLength: 0)
                Image(systemName: unitUncertain ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(unitUncertain ? .orange : .secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.top, 4)
        .help(caption + "\n\n" + Database.credit)
    }

    /// True when the picked model's maker never said whether its figure is per milliwatt or per volt.
    private var unitUncertain: Bool {
        Database.headphone(named: limiter.sensitivities[device.uid]?.model).map { !$0.unitStated } ?? false
    }

    private var caption: String {
        guard let voltage = limiter.fullScaleVoltage(device) else {
            return "No dB SPL figure for \(device.name): its full-volume output isn't known. Pick the DAC or amp it uses, if it has one. Headphones with their own amplifier (most Bluetooth ones) can't be worked out this way."
        }
        let volts = voltage.formatted(.number.precision(.fractionLength(0...2)))
        var text: String
        if device.isHeadphoneJack {
            text = "The Mac's DAC reports \(HeadphoneJack.mode()?.lowercased() ?? "unknown") headphones: \(volts) V RMS at full volume."
        } else {
            text = "\(limiter.source(for: device)?.name ?? "DAC"): about \(volts) V RMS at full volume, from its rated power."
        }
        if let spl = limiter.limitSPL(device) {
            text += " The limit allows at most \(Int(spl.rounded())) dB SPL (full-scale sine); music averages lower."
        } else {
            text += " Pick the headphones or enter their sensitivity to see the limit in dB SPL."
        }
        if let model = Database.headphone(named: limiter.sensitivities[device.uid]?.model), !model.unitStated {
            text += " Caution: \(model.name)'s maker didn't state the sensitivity unit; if it is really dB/V the true level is 10–15 dB lower."
        }
        return text
    }
}

/// A search field that lists matching model names and reports the one clicked.
private struct ModelSearch: View {
    let prompt: String
    let results: (String) -> [(name: String, detail: String)]
    let pick: (String) -> Void
    @State private var query = ""

    var body: some View {
        TextField(prompt, text: $query)
        if !query.isEmpty {
            let matches = results(query)
            ForEach(matches.prefix(6), id: \.name) { match in
                Button {
                    pick(match.name)
                    query = ""
                } label: {
                    HStack {
                        Text(match.name).lineLimit(1)
                        Spacer()
                        Text(match.detail).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if matches.isEmpty {
                Text("No match; enter the figures by hand.").font(.caption).foregroundStyle(.secondary)
            } else if matches.count > 6 {
                Text("\(matches.count - 6) more; keep typing.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var limiter: Limiter
    let device: AudioDevice

    var body: some View {
        Toggle(isOn: Binding(
            get: { limiter.isLimited(device) },
            set: { limiter.setLimited($0, for: device) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(device.name).lineLimit(1)
                    if device.id == limiter.defaultDeviceID {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Current output")
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .help(tooltip)
        .disabled(!device.canSetVolume)
    }

    private var detail: String {
        guard device.canSetVolume else { return "can't be limited" }
        return limiter.volumes[device.id].map { decibels(Double($0)) } ?? "level unknown"
    }

    private var tooltip: String {
        guard device.canSetVolume else { return "\(device.transportLabel) output with no software volume control, so it can't be limited." }
        var text = "\(device.transportLabel) output. The figure is its current level relative to full volume"
        text += device.hasDecibelControl ? "." : ", estimated because the device has no decibel control."
        if limiter.rescaledUIDs.contains(device.uid) { text += " Its volume range is being rescaled." }
        return text
    }
}

func decibels(_ value: Double) -> String {
    guard value.isFinite else { return "muted" }
    let rounded = (value * 10).rounded() / 10
    let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    return "\(text.replacingOccurrences(of: "-", with: "−")) dB"
}
