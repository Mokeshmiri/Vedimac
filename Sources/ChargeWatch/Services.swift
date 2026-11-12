import Foundation
import GaugeCore

// MARK: - Privileged helper

enum HelperError: Error, LocalizedError {
    case cancelled
    case helperMissing
    case failed(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Authentication was cancelled."
        case .helperMissing:
            return "The helper tool (gaugectl) was not found inside the app. Rebuild the app with Scripts/build-app.sh."
        case .failed(let why):
            return "The helper could not be run: \(why)"
        case .badOutput(let text):
            return "The helper returned something unexpected: \(text)"
        }
    }
}

/// Runs the bundled `gaugectl` tool as root through the standard macOS administrator dialog.
///
/// macOS itself asks for the password (`do shell script … with administrator privileges`).
/// The password never passes through this app, its logs or any script.
enum PrivilegedHelper {

    static func run(_ arguments: [String], prompt: String) throws -> HelperResponse {
        guard let helper = AppPaths.helperURL else { throw HelperError.helperMissing }

        // The command line is assembled inside AppleScript with `quoted form of`, so no argument
        // can be interpreted by the shell.
        let safePrompt = prompt
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "'")
        let script = [
            "on run argv",
            "set cmd to \"\"",
            "repeat with a in argv",
            "set cmd to cmd & quoted form of (a as text) & \" \"",
            "end repeat",
            "do shell script cmd with prompt \"\(safePrompt)\" with administrator privileges",
            "end run",
        ]
        var osaArguments: [String] = []
        for line in script {
            osaArguments.append("-e")
            osaArguments.append(line)
        }
        osaArguments.append(helper.path)
        osaArguments.append(contentsOf: arguments)

        let output = Shell.run("/usr/bin/osascript", osaArguments, timeout: 600)
        if output.status != 0 {
            if output.err.contains("-128") || output.err.localizedCaseInsensitiveContains("canceled") {
                throw HelperError.cancelled
            }
            throw HelperError.failed(output.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let text = output.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"), let data = String(text[start...]).data(using: .utf8),
              let response = try? GaugeJSON.decoder().decode(HelperResponse.self, from: data) else {
            throw HelperError.badOutput(String(text.prefix(300)))
        }
        return response
    }
}

// MARK: - powerd messages

struct PowerdSnapshot {
    var lines: [String] = []
    var status: String = "Not loaded yet."
    var loadedAt: Date?
    var window: String = "boot"
}

/// Reads powerd's battery-gauging messages from the unified log.
/// These are diagnostic messages only. They do not prove that a gauging charge happened.
enum PowerdLog {
    static let predicate = "process == \"powerd\" AND (eventMessage CONTAINS[c] \"gauging\" "
        + "OR eventMessage CONTAINS[c] \"BatteryGaugingMitigation\")"

    static let command = "/usr/bin/log show --last <window> --style compact --info --predicate '…'"

    static func fetch(window: String = "boot") -> PowerdSnapshot {
        let output = Shell.run("/usr/bin/log",
                               ["show", "--last", window, "--style", "compact", "--info",
                                "--predicate", predicate],
                               timeout: 90)
        var snapshot = PowerdSnapshot(loadedAt: Date(), window: window)
        guard output.status == 0 else {
            let reason = output.err.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.status = "The unified log could not be read"
                + (reason.isEmpty ? "." : ": \(reason.prefix(200))")
            return snapshot
        }
        let lines = output.out
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("Timestamp") && !$0.hasPrefix("Filtering the log data") }
        snapshot.lines = Array(lines.suffix(200))
        let scope = window == "boot" ? "since the last boot" : "in the last \(window)"
        snapshot.status = lines.isEmpty
            ? "No battery-gauging messages from powerd \(scope)."
            : "\(lines.count) message\(lines.count == 1 ? "" : "s") from powerd \(scope)."
        return snapshot
    }
}

// MARK: - History

/// Battery samples (one JSON object per line) and diagnostic events, stored locally.
final class HistoryStore {
    static let maxSamples = 60_000   // about six weeks at one sample per minute

    private let encoder = GaugeJSON.encoder()
    private let decoder = GaugeJSON.decoder()

    func loadSamples() -> [Sample] {
        guard let text = try? String(contentsOf: AppPaths.historyURL, encoding: .utf8) else { return [] }
        var samples: [Sample] = []
        for line in text.split(separator: "\n") {
            if let data = line.data(using: .utf8), let sample = try? decoder.decode(Sample.self, from: data) {
                samples.append(sample)
            }
        }
        if samples.count > HistoryStore.maxSamples {
            samples = Array(samples.suffix(HistoryStore.maxSamples * 3 / 4))
            rewrite(samples)
        }
        return samples
    }

    func append(_ sample: Sample) {
        guard var data = try? encoder.encode(sample) else { return }
        data.append(0x0A)
        let url = AppPaths.historyURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func rewrite(_ samples: [Sample]) {
        var data = Data()
        for sample in samples {
            if let line = try? encoder.encode(sample) {
                data.append(line)
                data.append(0x0A)
            }
        }
        try? data.write(to: AppPaths.historyURL, options: [.atomic])
    }

    func loadEvents() -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: AppPaths.eventsURL),
              let events = try? decoder.decode([DiagnosticEvent].self, from: data) else { return [] }
        return events
    }

    func saveEvents(_ events: [DiagnosticEvent]) {
        guard let data = try? GaugeJSON.encoder(pretty: true).encode(events) else { return }
        try? data.write(to: AppPaths.eventsURL, options: [.atomic])
    }

    func loadState() -> PersistedState {
        guard let data = try? Data(contentsOf: AppPaths.stateURL),
              let state = try? decoder.decode(PersistedState.self, from: data) else { return PersistedState() }
        return state
    }

    func saveState(_ state: PersistedState) {
        guard let data = try? GaugeJSON.encoder(pretty: true).encode(state) else { return }
        try? data.write(to: AppPaths.stateURL, options: [.atomic])
    }
}
