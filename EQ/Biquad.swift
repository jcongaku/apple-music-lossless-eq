import Foundation

/// Normalised biquad coefficients (a0 folded to 1), derived from a `PEQBand`
/// using the Robert Bristow-Johnson Audio EQ Cookbook formulas — the same math
/// Equalizer APO, PipeWire and most players use, so imported AutoEQ presets
/// sound the way their authors intended.
///
/// These are used two ways: to draw the response curve in the UI (via
/// `magnitude`), and directly by the real-time biquad processor. Coefficients
/// are sample-rate dependent, so they must be recomputed whenever the output
/// device's rate changes.
struct BiquadCoefficients: Equatable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    /// A pass-through (unity) biquad.
    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    init(band: PEQBand, sampleRate: Double) {
        guard sampleRate.isFinite, band.frequency.isFinite,
              band.gainDB.isFinite, band.q.isFinite,
              sampleRate > 0, band.frequency > 0, band.q > 0,
              band.frequency < sampleRate / 2 else {
            self = .identity
            return
        }

        let a = pow(10.0, band.gainDB / 40.0)            // amplitude, sqrt of linear gain
        let w0 = 2.0 * Double.pi * band.frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * band.q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        var a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch band.type {
        case .peak:
            b0 = 1 + alpha * a
            b1 = -2 * cosW0
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW0
            a2 = 1 - alpha / a

        case .lowShelf:
            let sq = 2 * sqrt(a) * alpha
            b0 =      a * ((a + 1) - (a - 1) * cosW0 + sq)
            b1 =  2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 =      a * ((a + 1) - (a - 1) * cosW0 - sq)
            a0 =          (a + 1) + (a - 1) * cosW0 + sq
            a1 =     -2 * ((a - 1) + (a + 1) * cosW0)
            a2 =          (a + 1) + (a - 1) * cosW0 - sq

        case .highShelf:
            let sq = 2 * sqrt(a) * alpha
            b0 =      a * ((a + 1) + (a - 1) * cosW0 + sq)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 =      a * ((a + 1) + (a - 1) * cosW0 - sq)
            a0 =          (a + 1) - (a - 1) * cosW0 + sq
            a1 =      2 * ((a - 1) - (a + 1) * cosW0)
            a2 =          (a + 1) - (a - 1) * cosW0 - sq
        }

        let normalized = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        guard normalized.allSatisfy(\.isFinite) else {
            self = .identity
            return
        }
        self.b0 = normalized[0]
        self.b1 = normalized[1]
        self.b2 = normalized[2]
        self.a1 = normalized[3]
        self.a2 = normalized[4]
    }

    /// Linear magnitude of the transfer function evaluated on the unit circle
    /// at `frequency`. Used to plot the response curve.
    func magnitude(atFrequency frequency: Double, sampleRate: Double) -> Double {
        guard frequency.isFinite, sampleRate.isFinite, frequency >= 0, sampleRate > 0 else {
            return 1
        }
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2 * w), sin2W = sin(2 * w)

        let numRe = b0 + b1 * cosW + b2 * cos2W
        let numIm = -(b1 * sinW + b2 * sin2W)
        let denRe = 1 + a1 * cosW + a2 * cos2W
        let denIm = -(a1 * sinW + a2 * sin2W)

        let numMag = (numRe * numRe + numIm * numIm).squareRoot()
        let denMag = (denRe * denRe + denIm * denIm).squareRoot()
        return denMag == 0 ? 0 : numMag / denMag
    }
}

/// Computes the combined frequency response of a whole profile, for the UI graph.
enum PEQResponse {
    struct Point: Equatable {
        let frequency: Double
        let db: Double
    }

    /// Combined magnitude in dB at one frequency, including the preamp and all
    /// enabled bands.
    static func magnitudeDB(profile: PEQProfile,
                            frequency: Double,
                            sampleRate: Double,
                            excluding excludedBandID: PEQBand.ID? = nil) -> Double {
        var db = profile.preampDB
        for band in profile.bands where band.isEnabled && band.id != excludedBandID {
            let coefficients = BiquadCoefficients(band: band, sampleRate: sampleRate)
            let magnitude = coefficients.magnitude(atFrequency: frequency, sampleRate: sampleRate)
            if magnitude > 0 {
                db += 20.0 * log10(magnitude)
            }
        }
        return db
    }

    /// The point on an individual band's response used by the graph handle.
    ///
    /// A bell filter's natural control point is its centre/apex. Shelves are
    /// different: at `frequency` the RBJ response is halfway between the two
    /// plateaus, so placing a gain handle there makes it float away from the
    /// visible shelf. Walk toward the affected edge and use the first point
    /// that reaches 90% of the requested shelf gain. This is the visual
    /// shoulder of the plateau and continues to move naturally with frequency
    /// and Q.
    static func controlFrequency(for band: PEQBand,
                                 sampleRate: Double,
                                 fMin: Double = 20,
                                 fMax: Double = 20_000) -> Double {
        let upperBound = min(fMax, sampleRate / 2 - 1)
        let centre = min(max(band.frequency, fMin), upperBound)
        guard band.type != .peak,
              abs(band.gainDB) >= 0.05,
              upperBound > fMin else {
            return centre
        }

        let edge = band.type == .lowShelf ? fMin : upperBound
        let logCentre = log10(centre)
        let logEdge = log10(edge)
        let coefficients = BiquadCoefficients(band: band, sampleRate: sampleRate)

        // Log-space keeps the shoulder search visually uniform across octaves.
        for step in 1...96 {
            let t = Double(step) / 96
            let frequency = pow(10, logCentre + (logEdge - logCentre) * t)
            let magnitude = coefficients.magnitude(atFrequency: frequency,
                                                   sampleRate: sampleRate)
            guard magnitude > 0 else { continue }
            let responseDB = 20 * log10(magnitude)
            let progress = responseDB / band.gainDB
            if progress >= 0.9 {
                return frequency
            }
        }

        return edge
    }

    /// A log-spaced response curve over `[fMin, fMax]` for plotting.
    ///
    /// On top of the evenly log-spaced grid, each enabled band's control point,
    /// centre frequency, and -3 dB skirts are injected into the sample set. A high-Q
    /// peak is narrow enough to fall *between* grid points, which renders its
    /// apex too short and quantises the tip's width to the grid spacing — so the
    /// peak would stop looking sharper as Q climbs past ~1. Sampling each peak at
    /// its centre guarantees the apex and width are drawn faithfully at any Q.
    static func curve(profile: PEQProfile,
                      sampleRate: Double,
                      fMin: Double = 20,
                      fMax: Double = 20_000,
                      points: Int = 480) -> [Point] {
        guard points > 1, fMin > 0, fMax > fMin else { return [] }
        let logMin = log10(fMin)
        let logMax = log10(fMax)
        let nyquist = sampleRate / 2

        var frequencies = (0..<points).map { index in
            pow(10.0, logMin + Double(index) / Double(points - 1) * (logMax - logMin))
        }

        for band in profile.bands where band.isEnabled {
            let fc = band.frequency
            guard fc > fMin, fc < fMax else { continue }
            frequencies.append(controlFrequency(for: band,
                                                sampleRate: sampleRate,
                                                fMin: fMin,
                                                fMax: fMax))
            let halfBandwidth = fc / max(band.q, 0.1) / 2     // ≈ half the -3 dB width
            for offset in [-2.0, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 2] {
                let f = fc + offset * halfBandwidth
                if f > fMin, f < fMax { frequencies.append(f) }
            }
        }

        frequencies.sort()

        return frequencies.map { frequency in
            let f = min(frequency, nyquist - 1)
            return Point(frequency: f,
                         db: magnitudeDB(profile: profile,
                                         frequency: f,
                                         sampleRate: sampleRate))
        }
    }

    /// Conservative attenuation needed to keep the steady-state response below
    /// full scale. The final processor clamp remains as a last-resort guard for
    /// transients, but normal PEQ boosts should be handled here without clipping.
    static func requiredAutomaticHeadroomDB(profile: PEQProfile,
                                            sampleRate: Double,
                                            marginDB: Double = 0.2) -> Double {
        let validated = profile.sanitized()
        let response = curve(profile: validated,
                             sampleRate: sampleRate,
                             points: 4_096)
        let maximum = response.map(\.db).filter(\.isFinite).max() ?? validated.preampDB
        let overload = max(0, maximum)
        // Preserve exact unity for a genuinely flat/non-boosting profile. The
        // safety margin is useful only after attenuation is already required;
        // applying it unconditionally would make Flat 0.2 dB quieter.
        return overload > 0 ? overload + max(0, marginDB) : 0
    }
}
