import Foundation
import AppKit

/// Checks GitHub Releases for a newer Choritsu build.
///
/// The app is distributed outside the App Store and is not notarized, so it
/// cannot replace itself in place — an unsigned in-place swap would land a
/// quarantined bundle that macOS refuses to launch. This checker therefore only
/// reports that a newer release exists and opens its page; the user still does
/// the drag-install.
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    static let shared = UpdateChecker()

    @Published private(set) var state: State = .idle

    /// Public, unauthenticated endpoint. `releases/latest` already excludes
    /// drafts and prereleases, so a tagged beta never reaches users here.
    private let feedURL = URL(string: "https://api.github.com/repos/jcongaku/apple-music-lossless-eq/releases/latest")!
    private let launchDelay: TimeInterval = 5
    private let session: URLSession
    private var hasCheckedAtLaunch = false

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.httpAdditionalHeaders = ["Accept": "application/vnd.github+json"]
            self.session = URLSession(configuration: config)
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Silent check shortly after launch. A failure here stays invisible: a
    /// menu-bar app that nags about its own network trouble is worse than one
    /// that quietly tries again next launch.
    func checkAtLaunch() {
        guard !hasCheckedAtLaunch else { return }
        hasCheckedAtLaunch = true
        DispatchQueue.main.asyncAfter(deadline: .now() + launchDelay) { [weak self] in
            self?.check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) {
        if case .checking = state { return }
        state = .checking

        let task = session.dataTask(with: feedURL) { [weak self] data, response, error in
            guard let self else { return }

            let result = Self.interpret(data: data, response: response, error: error,
                                        currentVersion: self.currentVersion)

            DispatchQueue.main.async {
                switch result {
                case .failed where !userInitiated:
                    // Silent launch check: leave the menu as it was.
                    self.state = .idle
                default:
                    self.state = result
                }
            }
        }
        task.resume()
    }

    func openReleasePage() {
        guard case let .available(_, url) = state else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Response handling

    static func interpret(data: Data?, response: URLResponse?, error: Error?,
                          currentVersion: String) -> State {
        if let error {
            return .failed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failed("GitHub returned HTTP \(http.statusCode)")
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("Could not read the release feed")
        }

        guard let tag = json["tag_name"] as? String else {
            return .failed("Release feed had no tag")
        }

        let latest = normalizeVersion(tag)
        guard compareVersions(latest, currentVersion) == .orderedDescending else {
            return .upToDate
        }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/jcongaku/apple-music-lossless-eq/releases/latest")!
        return .available(version: latest, url: page)
    }

    /// `v2.2.1` and `2.2.1` are the same release; tags have used both forms.
    static func normalizeVersion(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        return value
    }

    /// Numeric component-wise comparison. Missing components count as zero, so
    /// `2.2` and `2.2.0` are equal and `2.2.10` sorts above `2.2.9`.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)

        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        // Stop at the first non-numeric component so a suffix such as
        // "2.3.0-beta.1" compares as 2.3.0 rather than failing outright.
        var result: [Int] = []
        for part in version.split(separator: ".") {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            result.append(value)
            if digits.count != part.count { break }
        }
        return result
    }
}
