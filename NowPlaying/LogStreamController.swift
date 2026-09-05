import Foundation

final class LogStreamController {
    private var process: Process?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "logstream.controller")
    private var recentLines: [String] = []
    private let maxRecentLines = 200
    private var lastFrameCount: Int?
    private var lastFrameTimestamp: Date?
    private var lastDurationSeconds: Double?
    private var lastDurationTimestamp: Date?

    var onSampleRate: ((Double, String?) -> Void)?
    var onStatus: ((String) -> Void)?

    var predicate: String = "(process == \"Music\" OR subsystem CONTAINS[c] \"com.apple.Music\" OR subsystem CONTAINS[c] \"com.apple.mediaremoted\") AND (eventMessage CONTAINS[c] \"sample\" OR eventMessage CONTAINS[c] \"lossless\" OR eventMessage CONTAINS[c] \"hi-res\" OR eventMessage CONTAINS[c] \"kHz\" OR eventMessage CONTAINS[c] \"Hz\" OR eventMessage CONTAINS[c] \"audio\" OR eventMessage CONTAINS[c] \"format\")"
    var logLevel: String = "debug"

    func start() {
        stop()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            "--style", "json",
            "--level", logLevel,
            "--predicate", predicate
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outputHandle = outPipe.fileHandleForReading
        errorHandle = errPipe.fileHandleForReading

        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.queue.async {
                self?.buffer.append(data)
                self?.drainBuffer()
            }
        }

        errorHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                self?.onStatus?(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        do {
            try proc.run()
            process = proc
            onStatus?("Log stream started")
        } catch {
            onStatus?("Failed to start log stream: \(error.localizedDescription)")
        }
    }

    func stop() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
        buffer.removeAll()

        if let process {
            process.terminate()
            self.process = nil
        }
    }

    private func drainBuffer() {
        while let range = buffer.firstRange(of: Data([0x0A])) { // newline
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else {
                continue
            }

            appendRecent(line)
            handleLogLine(line)
        }
    }

    func handleLogLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            _ = processMessage(line)
            return
        }

        let message = (json["eventMessage"] as? String)
            ?? (json["message"] as? String)
            ?? (json["formattedMessage"] as? String)

        if let message, processMessage(message) {
            return
        }

        if let rate = SampleRateParser.extractSampleRate(from: json) {
            onSampleRate?(rate, message ?? "JSON sampleRate")
            return
        }

        // Other JSON fields are metadata, not audio-format messages.
    }

    @discardableResult
    private func processMessage(_ message: String) -> Bool {
        if let rate = SampleRateParser.extractSampleRate(from: message) {
            onSampleRate?(rate, message)
            return true
        }

        if let rate = deriveSampleRate(from: message) {
            onSampleRate?(rate, "Derived from frames/duration: \(message)")
            return true
        }

        return false
    }

    private func deriveSampleRate(from message: String) -> Double? {
        let now = Date()

        if let frames = SampleRateParser.extractFrameCount(from: message) {
            lastFrameCount = frames
            lastFrameTimestamp = now
        }

        if let duration = SampleRateParser.extractDuration(from: message) {
            lastDurationSeconds = duration
            lastDurationTimestamp = now
        }

        guard let frames = lastFrameCount,
              let duration = lastDurationSeconds,
              duration > 0 else {
            return nil
        }

        let maxAge: TimeInterval = 5.0
        if let frameTime = lastFrameTimestamp,
           now.timeIntervalSince(frameTime) > maxAge {
            return nil
        }
        if let durationTime = lastDurationTimestamp,
           now.timeIntervalSince(durationTime) > maxAge {
            return nil
        }

        let minFrames = 1000
        let minDuration: Double = 0.05
        let maxDuration: Double = 5.0

        guard frames >= minFrames,
              duration >= minDuration,
              duration <= maxDuration else {
            return nil
        }

        let estimated = Double(frames) / duration
        return estimated
    }

    private func appendRecent(_ line: String) {
        recentLines.append(line)
        if recentLines.count > maxRecentLines {
            recentLines.removeFirst(recentLines.count - maxRecentLines)
        }
    }

    func dumpRecentLines() {
        queue.async { [recentLines] in
            print("MediaRemote LogStream: Recent \(recentLines.count) lines")
            for line in recentLines {
                print(line)
            }
        }
    }
}

private enum SampleRateParser {
    private static let sampleRatePattern = try! NSRegularExpression(
        pattern: "(?i)(?:sample\\s*rate|samplerate)\\s*[:=]\\s*([0-9]+(?:\\.[0-9]+)?)",
        options: []
    )

    private static let khzPattern = try! NSRegularExpression(
        pattern: "(?i)([0-9]+(?:\\.[0-9]+)?)\\s*kHz",
        options: []
    )

    private static let hzPattern = try! NSRegularExpression(
        pattern: "(?i)([0-9]{4,6})\\s*Hz",
        options: []
    )

    private static let framesPattern = try! NSRegularExpression(
        pattern: "(?i)([0-9]{3,7})\\s*frames",
        options: []
    )

    private static let durationPattern = try! NSRegularExpression(
        pattern: "(?i)duration\\s*:?\\s*([0-9]+(?:\\.[0-9]+)?)",
        options: []
    )

    static func extractSampleRate(from message: String) -> Double? {
        if let value = firstMatch(message, regex: sampleRatePattern) {
            return normalize(value, unit: nil)
        }

        if let value = firstMatch(message, regex: khzPattern) {
            return normalize(value, unit: "kHz")
        }

        if let value = firstMatch(message, regex: hzPattern) {
            return normalize(value, unit: "Hz")
        }

        return nil
    }

    static func extractFrameCount(from message: String) -> Int? {
        guard let value = firstMatch(message, regex: framesPattern) else {
            return nil
        }
        return Int(value)
    }

    static func extractDuration(from message: String) -> Double? {
        return firstMatch(message, regex: durationPattern)
    }

    static func extractSampleRate(from json: [String: Any]) -> Double? {
        for (key, value) in json {
            if ["samplerate", "msamplerate"].contains(key.lowercased()),
               let numeric = numericValue(value) {
                return normalize(numeric, unit: nil)
            }
        }

        for value in json.values {
            if let nested = extractSampleRate(from: value) {
                return nested
            }
        }

        return nil
    }

    private static func extractSampleRate(from value: Any) -> Double? {
        if let dict = value as? [String: Any] {
            return extractSampleRate(from: dict)
        }

        if let array = value as? [Any] {
            for item in array {
                if let nested = extractSampleRate(from: item) {
                    return nested
                }
            }
        }

        // Numeric leaves are evidence only under an explicit sample-rate key.
        return nil
    }

    private static func firstMatch(_ text: String, regex: NSRegularExpression) -> Double? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Double(text[capture])
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        if let doubleValue = value as? Double {
            return doubleValue
        }

        if let string = value as? String, let doubleValue = Double(string) {
            return doubleValue
        }

        return nil
    }

    private static func normalize(_ value: Double, unit: String?) -> Double? {
        if value <= 0 { return nil }

        if let unit, unit.lowercased() == "khz" {
            return value * 1000.0
        }

        if let unit, unit.lowercased() == "hz" {
            return value
        }

        if value < 1000 {
            return value * 1000.0
        }

        return value
    }

    static func snapToCommonSampleRate(_ value: Double) -> Double? {
        let candidates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
        let nearest = candidates.min(by: { abs($0 - value) < abs($1 - value) })
        guard let nearest else { return value }
        if abs(nearest - value) <= 250 {
            return nearest
        }
        return nil
    }
}
