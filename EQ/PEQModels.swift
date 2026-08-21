import Foundation

enum PEQConstraints {
    static let maximumBands = 32
    static let frequencyRange = 20.0...20_000.0
    static let gainRange = -20.0...20.0
    static let preampRange = -24.0...12.0
    static let peakQRange = 0.1...12.0
    // AutoEq shelves intentionally stay below the resonant/overshooting region.
    static let shelfQRange = 0.4...0.7

    static func qRange(for type: PEQFilterType) -> ClosedRange<Double> {
        type == .peak ? peakQRange : shelfQRange
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>,
                      fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Filter vocabulary

/// The parametric filter shapes Choritsu supports. The raw values mirror
/// AutoEQ's `ParametricEQ.txt` tokens so profiles round-trip cleanly.
enum PEQFilterType: String, Codable, CaseIterable, Identifiable {
    case peak       // AutoEQ: PK
    case lowShelf   // AutoEQ: LSC / LS
    case highShelf  // AutoEQ: HSC / HS

    var id: String { rawValue }

    /// The token written into an AutoEQ-style export.
    var autoEQToken: String {
        switch self {
        case .peak: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        }
    }

    var displayName: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }
}

// MARK: - Band

/// A single parametric EQ band: one biquad's worth of parameters.
struct PEQBand: Identifiable, Codable, Equatable {
    var id: UUID
    var isEnabled: Bool
    var type: PEQFilterType
    /// Centre / corner frequency in Hz.
    var frequency: Double
    var gainDB: Double
    /// Quality factor. AutoEQ shelves default to ~0.707.
    var q: Double

    init(id: UUID = UUID(),
         isEnabled: Bool = true,
         type: PEQFilterType = .peak,
         frequency: Double = 1000,
         gainDB: Double = 0,
         q: Double = 0.707) {
        self.id = id
        self.isEnabled = isEnabled
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }

    func sanitized() -> PEQBand {
        var result = self
        result.frequency = PEQConstraints.clamp(frequency,
                                                to: PEQConstraints.frequencyRange,
                                                fallback: 1_000)
        result.gainDB = PEQConstraints.clamp(gainDB,
                                             to: PEQConstraints.gainRange,
                                             fallback: 0)
        result.q = PEQConstraints.clamp(q,
                                        to: PEQConstraints.qRange(for: type),
                                        fallback: type == .peak ? 1 : 0.7)
        return result
    }
}

// MARK: - Profile

/// A named set of bands plus a preamp — typically one per headphone.
/// AutoEQ presets are mono curves applied identically to both channels.
struct PEQProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Global gain applied before the bands, in dB. AutoEQ ships this negative
    /// to leave headroom for the boosts and avoid clipping.
    var preampDB: Double
    var bands: [PEQBand]

    init(id: UUID = UUID(),
         name: String,
         preampDB: Double = 0,
         bands: [PEQBand] = []) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
    }

    static let flat = PEQProfile(name: "Flat")

    func sanitized() -> PEQProfile {
        var result = self
        result.preampDB = PEQConstraints.clamp(preampDB,
                                               to: PEQConstraints.preampRange,
                                               fallback: 0)
        result.bands = bands.prefix(PEQConstraints.maximumBands).map { $0.sanitized() }
        return result
    }
}
