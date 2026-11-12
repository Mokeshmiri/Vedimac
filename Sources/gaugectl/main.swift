import Foundation
import GaugeCore

// gaugectl: the only part of ChargeWatch that runs with administrator rights.
//
// When run as root it works on exactly one file (GaugingSchema.systemPlistPath) and one backup
// folder (/Library/Application Support/ChargeWatch). Paths cannot be overridden as root.
// When run as a normal user it requires --plist and --store, which is how fixtures are exercised.
//
// Commands:
//   status
//   apply [--expect-sha <sha256>] [--restart]
//   restore --backup-id <id> [--restart]
//   import-original --file <path>
//
// Output: one line of JSON (HelperResponse). The exit code is always 0 so the caller can read the
// JSON; failures are reported inside it.

func emit(_ response: HelperResponse) {
    let data = (try? GaugeJSON.encoder().encode(response)) ?? Data("{\"ok\":false}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ code: String, _ message: String) -> Never {
    emit(HelperResponse(ok: false, errorCode: code, errorMessage: message))
    exit(0)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage", "No command given. Use status, apply, restore or import-original.")
}
arguments.removeFirst()

var options: [String: String] = [:]
var flags = Set<String>()
var position = 0
while position < arguments.count {
    let argument = arguments[position]
    switch argument {
    case "--restart":
        flags.insert(argument)
    case "--expect-sha", "--backup-id", "--file", "--plist", "--store":
        guard position + 1 < arguments.count else { fail("usage", "Missing value for \(argument).") }
        options[argument] = arguments[position + 1]
        position += 1
    default:
        fail("usage", "Unknown argument \(argument).")
    }
    position += 1
}

let isRoot = geteuid() == 0
let plistPath: String
let store: BackupStore

if isRoot {
    guard options["--plist"] == nil, options["--store"] == nil else {
        fail("usage", "--plist and --store are not accepted when running as root.")
    }
    plistPath = GaugingSchema.systemPlistPath
    store = BackupStore(directory: BackupStore.systemDirectory)
} else {
    guard let fixturePlist = options["--plist"], let fixtureStore = options["--store"] else {
        fail("needsAdministrator",
             "Administrator rights are required for the system file. Without them, pass --plist and --store to work on fixture files.")
    }
    guard fixturePlist != GaugingSchema.systemPlistPath else {
        fail("needsAdministrator", "The system file can only be used with administrator rights.")
    }
    plistPath = fixturePlist
    store = BackupStore(directory: URL(fileURLWithPath: fixtureStore, isDirectory: true))
}

let env = GaugingEnvironment(plistPath: plistPath, store: store, macOSBuild: SystemBuild.current())
// A restart is only ever performed as root, on the real system, after a successful operation.
let restartRequested = flags.contains("--restart") && isRoot

func restartNow() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
    process.arguments = ["-r", "now"]
    try? process.run()
}

do {
    switch command {
    case "status":
        emit(HelperResponse(ok: true, report: try GaugingWriter.check(env: env)))

    case "apply":
        var result = try GaugingWriter.apply(env: env, expectedSnapshotSHA: options["--expect-sha"])
        result.restartRequested = restartRequested
        store.saveLastOperation(result)
        emit(HelperResponse(ok: true, report: result.after, operation: result))
        if restartRequested { restartNow() }

    case "restore":
        guard let backupID = options["--backup-id"] else { fail("usage", "restore needs --backup-id.") }
        var result = try GaugingWriter.restore(env: env, backupID: backupID)
        result.restartRequested = restartRequested
        store.saveLastOperation(result)
        emit(HelperResponse(ok: true, report: result.after, operation: result))
        if restartRequested { restartNow() }

    case "import-original":
        guard let file = options["--file"] else { fail("usage", "import-original needs --file.") }
        let entry = try GaugingWriter.importOriginal(env: env, sourcePath: file)
        emit(HelperResponse(ok: true, backup: entry))

    default:
        fail("usage", "Unknown command \(command).")
    }
} catch let error as GaugingError {
    fail(error.code, error.localizedDescription)
} catch {
    fail("unexpected", error.localizedDescription)
}
