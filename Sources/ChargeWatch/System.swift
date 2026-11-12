import Foundation
import GaugeCore

/// Runs a command and captures its output. Never used for anything that needs a password.
enum Shell {
    struct Output {
        let status: Int32
        let out: String
        let err: String
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Output(status: -1, out: "", err: error.localizedDescription)
        }

        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            box.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        group.wait()
        killer.cancel()

        return Output(status: process.terminationStatus,
                      out: String(decoding: box.out, as: UTF8.self),
                      err: String(decoding: box.err, as: UTF8.self))
    }

    private final class OutputBox: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}

enum SystemInfo {
    static var build: String { SystemBuild.current() }

    static var version: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var model: String { SystemBuild.sysctlString("hw.model") ?? "unknown" }

    static var bootTime: Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }
}

/// Condition and Maximum Capacity as shown in System Information (`system_profiler SPPowerDataType`).
/// The battery entry in the registry does not include either on recent macOS versions.
struct SystemReportBattery {
    var condition: String?
    var maximumCapacityPercent: Int?

    /// Takes a couple of seconds, so it is run in the background every ten minutes.
    static func read() -> SystemReportBattery {
        let output = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 30)
        guard output.status == 0 else { return SystemReportBattery() }
        return parse(output.out)
    }

    /// Parses lines such as "Condition: Normal" and "Maximum Capacity: 95%".
    static func parse(_ text: String) -> SystemReportBattery {
        var result = SystemReportBattery()
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if label == "condition", result.condition == nil {
                result.condition = value
            } else if label == "maximum capacity", result.maximumCapacityPercent == nil {
                result.maximumCapacityPercent = Int(value.replacingOccurrences(of: "%", with: "")
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return result
    }
}

enum AppPaths {
    /// ~/Library/Application Support/ChargeWatch. Everything the app records stays here.
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("ChargeWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var stateURL: URL { dataDirectory.appendingPathComponent("state.json") }
    static var historyURL: URL { dataDirectory.appendingPathComponent("history.jsonl") }
    static var eventsURL: URL { dataDirectory.appendingPathComponent("events.json") }

    /// The helper sits inside the app bundle; when run with `swift run` it sits next to the executable.
    static var helperURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gaugectl"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("gaugectl"),
        ]
        for case let url? in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }
}

/// Removes personal details from text that leaves the Mac.
enum Redactor {
    static func redact(_ text: String) -> String {
        var result = text
        let home = NSHomeDirectory()
        if home.count > 1 { result = result.replacingOccurrences(of: home, with: "~") }
        result = replace(result, pattern: "/Users/[^/\\s\"']+", with: "/Users/<user>")
        let user = NSUserName()
        if user.count >= 3 { result = result.replacingOccurrences(of: user, with: "<user>") }
        // Serial-like tokens: long runs of capitals and digits.
        result = replace(result, pattern: "\\b[A-Z0-9]{12,}\\b", with: "<redacted-id>")
        return result
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
