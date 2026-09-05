import XCTest

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparisonOrdersNumericallyNotLexically() {
        XCTAssertEqual(UpdateChecker.compareVersions("2.2.10", "2.2.9"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersions("2.10.0", "2.9.0"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersions("10.0.0", "9.9.9"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersions("2.2.1", "2.2.1"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersions("2.2.0", "2.2.1"), .orderedAscending)
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertEqual(UpdateChecker.compareVersions("2.2", "2.2.0"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersions("2", "2.0.0"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersions("2.2.1", "2.2"), .orderedDescending)
    }

    func testTagPrefixIsStripped() {
        XCTAssertEqual(UpdateChecker.normalizeVersion("v2.2.1"), "2.2.1")
        XCTAssertEqual(UpdateChecker.normalizeVersion("V2.2.1"), "2.2.1")
        XCTAssertEqual(UpdateChecker.normalizeVersion(" v2.2.1\n"), "2.2.1")
        XCTAssertEqual(UpdateChecker.normalizeVersion("2.2.1"), "2.2.1")
    }

    func testSuffixedVersionsCompareOnTheirNumericPrefix() {
        XCTAssertEqual(UpdateChecker.compareVersions("2.3.0-beta.1", "2.3.0"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersions("2.3.0-beta.1", "2.2.1"), .orderedDescending)
    }

    func testNewerTagIsOfferedWithItsReleasePage() {
        let payload = #"{"tag_name":"v2.3.0","html_url":"https://example.com/r/2.3.0"}"#
        let state = interpret(payload, current: "2.2.1")
        XCTAssertEqual(state, .available(version: "2.3.0",
                                         url: URL(string: "https://example.com/r/2.3.0")!))
    }

    func testSameOrOlderTagReportsUpToDate() {
        XCTAssertEqual(interpret(#"{"tag_name":"v2.2.1"}"#, current: "2.2.1"), .upToDate)
        XCTAssertEqual(interpret(#"{"tag_name":"v2.2.0"}"#, current: "2.2.1"), .upToDate)
        XCTAssertEqual(interpret(#"{"tag_name":"v1.0.0"}"#, current: "2.2.1"), .upToDate)
    }

    func testDevelopmentBuildAheadOfLatestReleaseIsNotOfferedAnUpdate() {
        XCTAssertEqual(interpret(#"{"tag_name":"v2.2.1"}"#, current: "2.3.0"), .upToDate)
    }

    func testMissingReleasePageFallsBackToTheReleasesURL() {
        guard case let .available(version, url) = interpret(#"{"tag_name":"v2.3.0"}"#, current: "2.2.1") else {
            return XCTFail("expected an available update")
        }
        XCTAssertEqual(version, "2.3.0")
        XCTAssertEqual(url.host, "github.com")
    }

    func testMalformedFeedsFailInsteadOfOfferingAnUpdate() {
        XCTAssertEqual(interpret("not json", current: "2.2.1"), .failed("Could not read the release feed"))
        XCTAssertEqual(interpret(#"{"name":"2.3.0"}"#, current: "2.2.1"), .failed("Release feed had no tag"))
    }

    func testHTTPErrorsAreReportedNotSilentlyTreatedAsUpToDate() {
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                                       statusCode: 403, httpVersion: nil, headerFields: nil)!
        let state = UpdateChecker.interpret(data: Data(), response: response, error: nil,
                                            currentVersion: "2.2.1")
        XCTAssertEqual(state, .failed("GitHub returned HTTP 403"))
    }

    func testTransportErrorsAreReported() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSLocalizedDescriptionKey: "offline"])
        let state = UpdateChecker.interpret(data: nil, response: nil, error: error,
                                            currentVersion: "2.2.1")
        XCTAssertEqual(state, .failed("offline"))
    }

    private func interpret(_ body: String, current: String) -> UpdateChecker.State {
        let url = URL(string: "https://api.github.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return UpdateChecker.interpret(data: Data(body.utf8), response: response, error: nil,
                                       currentVersion: current)
    }
}
