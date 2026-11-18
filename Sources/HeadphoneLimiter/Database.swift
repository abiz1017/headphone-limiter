import Foundation

/// A headphone's published electrical specs.
struct HeadphoneModel: Identifiable {
    let name: String
    let impedance: Double
    /// dB SPL at 1 mW.
    let perMilliwatt: Double
    /// False when the maker printed a bare "dB" figure; it may really be dB/V, 10–15 dB off.
    let unitStated: Bool
    var id: String { name }
}

/// A DAC or amplifier's full-scale output, derived from the maker's power ratings.
struct SourceModel: Identifiable {
    let name: String
    /// Volts RMS at the rated loads, ascending by load.
    let outputs: [(load: Double, volts: Double)]
    var id: String { name }

    /// Full-scale volts RMS into headphones of the given impedance (32 ohms when unknown),
    /// taken from the nearest rated load.
    func voltage(into impedance: Double?) -> Double {
        let target = log(max(impedance ?? 32, 1))
        return outputs.min { abs(log($0.load) - target) < abs(log($1.load) - target) }?.volts ?? 0
    }
}

/// Bundled model specs. Data: The Phone Path (thephonepath.com), CC BY 4.0.
enum Database {
    static let credit = "Model data: The Phone Path (thephonepath.com), CC BY 4.0. Makers' claims, not measurements."

    static let headphones: [HeadphoneModel] = rows(DatabaseData.headphones).compactMap { fields in
        guard fields.count == 4, let impedance = Double(fields[1]), let sensitivity = Double(fields[2]) else { return nil }
        return HeadphoneModel(name: fields[0], impedance: impedance, perMilliwatt: sensitivity, unitStated: fields[3] == "1")
    }

    static let sources: [SourceModel] = rows(DatabaseData.sources).compactMap { fields in
        guard fields.count == 5 else { return nil }
        let outputs = zip([32.0, 150, 300, 600], fields.dropFirst()).compactMap { load, volts in
            Double(volts).map { (load: load, volts: $0) }
        }
        return outputs.isEmpty ? nil : SourceModel(name: fields[0], outputs: outputs)
    }

    static func headphone(named name: String?) -> HeadphoneModel? {
        name.flatMap { name in headphones.first { $0.name == name } }
    }

    static func source(named name: String?) -> SourceModel? {
        name.flatMap { name in sources.first { $0.name == name } }
    }

    static func searchHeadphones(_ query: String) -> [HeadphoneModel] {
        search(query, in: headphones, name: \.name)
    }

    static func searchSources(_ query: String) -> [SourceModel] {
        search(query, in: sources, name: \.name)
    }

    /// Guesses the DAC from an audio device's name, e.g. Bluetooth "FiiO BTR5" -> "FiiO BTR5 2021".
    static func source(matchingDeviceName deviceName: String) -> SourceModel? {
        let wanted = compact(deviceName)
        guard wanted.count >= 6 else { return nil }
        return sources
            .filter { compact($0.name).contains(wanted) || wanted.contains(compact($0.name)) }
            .min { $0.name.count < $1.name.count }
    }

    /// Every word of the query must appear in the name; punctuation and spacing are ignored.
    private static func search<T>(_ query: String, in items: [T], name: KeyPath<T, String>) -> [T] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { compact(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return items.filter { item in
            let candidate = compact(item[keyPath: name])
            return words.allSatisfy(candidate.contains)
        }
    }

    private static func compact(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func rows(_ table: String) -> [[String]] {
        table.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }
}
