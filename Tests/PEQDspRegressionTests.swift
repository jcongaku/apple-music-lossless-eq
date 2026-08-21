import XCTest
import Foundation

final class PEQDspRegressionTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testProfileSanitizationUsesTypeSpecificLimitsAndBandCap() {
        let shelf = PEQBand(type: .highShelf,
                            frequency: .infinity,
                            gainDB: .nan,
                            q: 12).sanitized()
        XCTAssertEqual(shelf.frequency, 1_000)
        XCTAssertEqual(shelf.gainDB, 0)
        XCTAssertEqual(shelf.q, 0.7)

        let profile = PEQProfile(name: "Many",
                                 bands: (0..<40).map { _ in PEQBand() }).sanitized()
        XCTAssertEqual(profile.bands.count, PEQConstraints.maximumBands)
    }

    func testAutomaticHeadroomCoversPeakBoost() {
        let profile = PEQProfile(name: "Boost", bands: [
            PEQBand(type: .peak, frequency: 1_000, gainDB: 18, q: 10),
        ])
        XCTAssertEqual(PEQResponse.requiredAutomaticHeadroomDB(profile: profile,
                                                               sampleRate: sampleRate),
                       18.2,
                       accuracy: 0.01)
    }

    func testFlatProfileKeepsExactUnityHeadroom() {
        XCTAssertEqual(PEQResponse.requiredAutomaticHeadroomDB(profile: .flat,
                                                               sampleRate: sampleRate),
                       0,
                       accuracy: 0.000_001)
    }

    func testProcessorProtectsFullScaleAndKeepsStereoMatched() {
        let processor = BiquadProcessor()
        let band = PEQBand(type: .peak, frequency: 1_000, gainDB: 18, q: 10)
        processor.setSections([BiquadCoefficients(band: band, sampleRate: sampleRate)],
                              preampDB: -18.2,
                              sampleRate: sampleRate)
        processor.setActive(true)

        var cursor = 0
        var peak = 0.0
        for _ in 0..<30 {
            processor.beginRender(frameCount: 256)
            for frame in 0..<256 {
                let input = Float(0.9 * sin(2 * Double.pi * 1_000
                                            * Double(cursor + frame) / sampleRate))
                let left = processor.processSample(input, channel: 0, frameOffset: frame)
                let right = processor.processSample(input, channel: 1, frameOffset: frame)
                XCTAssertTrue(left.isFinite)
                XCTAssertEqual(left, right, accuracy: 0.000_001)
                peak = max(peak, abs(Double(left)))
            }
            processor.endRender(frameCount: 256)
            cursor += 256
        }
        XCTAssertLessThanOrEqual(peak, 1)
        XCTAssertLessThanOrEqual(peak, 0.90)
    }

    func testRapidUpdatesRemainFiniteAndUseLatestConfiguration() {
        let processor = BiquadProcessor()
        processor.setActive(true)
        for index in 0..<100 {
            let band = PEQBand(type: .peak,
                               frequency: 100 + Double(index) * 100,
                               gainDB: Double(index % 21) - 10,
                               q: 0.5 + Double(index % 10))
            processor.setSections([BiquadCoefficients(band: band, sampleRate: sampleRate)],
                                  preampDB: -12,
                                  sampleRate: sampleRate)
        }

        processor.beginRender(frameCount: 4_096)
        for frame in 0..<4_096 {
            let input = Float(0.8 * sin(2 * Double.pi * 500 * Double(frame) / sampleRate))
            let output = processor.processSample(input, channel: 0, frameOffset: frame)
            XCTAssertTrue(output.isFinite)
            XCTAssertLessThanOrEqual(abs(output), 1)
        }
        processor.endRender(frameCount: 4_096)
    }

    func testConcurrentPublishingAndRenderingStaysFinite() {
        let processor = BiquadProcessor()
        processor.setActive(true)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0..<1_000 {
                let band = PEQBand(type: .peak,
                                   frequency: 80 + Double(index % 190) * 100,
                                   gainDB: Double(index % 31) - 15,
                                   q: 0.2 + Double(index % 100) * 0.1)
                processor.setSections(
                    [BiquadCoefficients(band: band, sampleRate: self.sampleRate)],
                    preampDB: -18,
                    sampleRate: self.sampleRate)
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var sampleOffset = 0
            for _ in 0..<500 {
                processor.beginRender(frameCount: 64)
                for frame in 0..<64 {
                    let input = Float(0.75 * sin(2 * Double.pi * 997
                                                 * Double(sampleOffset + frame)
                                                 / self.sampleRate))
                    let output = processor.processSample(input,
                                                         channel: 0,
                                                         frameOffset: frame)
                    XCTAssertTrue(output.isFinite)
                    XCTAssertLessThanOrEqual(abs(output), 1)
                }
                processor.endRender(frameCount: 64)
                sampleOffset += 64
            }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }
}
