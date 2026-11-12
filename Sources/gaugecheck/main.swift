import Foundation
import GaugeCore

// gaugecheck: fixture checks for the plist logic, as a plain program (no XCTest needed).
//
//   swift run gaugecheck                 uses Tests/Fixtures in the current folder
//   swift run gaugecheck <fixtures-dir>
//
// It only ever works on copies of the fixture files inside a temporary folder.
// It never reads the system plist, and GaugeCore contains no restart code.

// MARK: - Tiny harness

var checkCount = 0
var failureCount = 0

func fail(_ message: String, line: UInt) {
    failureCount += 1
    print("    FAIL (line \(line)): \(message)")
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String, line: UInt = #line) {
    checkCount += 1
    do {
        if try condition() == false { fail(message, line: line) }
    } catch {
        fail("\(message) [threw: \(error.localizedDescription)]", line: line)
    }
}

/// Passes only if `body` throws a GaugingError with the given code.
func expectError(_ code: String, _ message: String, line: UInt = #line, _ body: () throws -> Void) {
    checkCount += 1
    do {
        try body()
        fail("\(message): expected error '\(code)', but nothing was thrown", line: line)
    } catch let error as GaugingError {
        if error.code != code {
            fail("\(message): expected error '\(code)', got '\(error.code)'", line: line)
        }
    } catch {
        fail("\(message): expected error '\(code)', got \(error.localizedDescription)", line: line)
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    let failuresBefore = failureCount
    do {
        try body()
    } catch {
        failureCount += 1
        print("    FAIL: unexpected error: \(error.localizedDescription)")
    }
    print((failureCount == failuresBefore ? "PASS  " : "FAIL  ") + name)
}

// MARK: - Setup

guard geteuid() != 0 else {
    print("gaugecheck must not be run as root.")
    exit(2)
}

let fixturesPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures"
let fixturesDirectory = URL(fileURLWithPath: fixturesPath, isDirectory: true)
guard FileManager.default.fileExists(atPath: fixturesDirectory.appendingPathComponent("original.binary.plist").path) else {
    print("Fixtures not found in \(fixturesDirectory.path). Run this from the project folder, or pass the fixtures folder.")
    exit(2)
}

let workDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("VedimacChecks-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

func fixtureBytes(_ name: String) throws -> Data {
    try Data(contentsOf: fixturesDirectory.appendingPathComponent(name))
}

/// Copies a fixture into the temporary folder and returns the path of the copy.
func workingCopy(_ name: String, mode: Int = 0o600) throws -> String {
    let destination = workDirectory.appendingPathComponent("live-" + UUID().uuidString + ".plist")
    try fixtureBytes(name).write(to: destination)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
    precondition(destination.path != GaugingSchema.systemPlistPath)
    return destination.path
}

/// Each call gets its own empty backup store.
func environment(_ path: String, beforeReplace: (() -> Void)? = nil) -> GaugingEnvironment {
    let storeDirectory = workDirectory.appendingPathComponent("store-" + UUID().uuidString, isDirectory: true)
    return GaugingEnvironment(plistPath: path,
                              store: BackupStore(directory: storeDirectory),
                              macOSBuild: "TESTBUILD1",
                              beforeReplace: beforeReplace)
}

func bytes(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

func isBinary(_ data: Data) -> Bool { data.starts(with: Data("bplist00".utf8)) }
func isXML(_ data: Data) -> Bool { data.starts(with: Data("<?xml".utf8)) }

let formats = ["binary", "xml"]

print("Vedimac fixture checks")
print("Fixtures: \(fixturesDirectory.path)")
print("Working copies: \(workDirectory.path)")
print("")

// MARK: - Reading the three states

test("original state reads as a full mismatch (binary and XML)") {
    for format in formats {
        let report = try GaugingWriter.check(env: environment(try workingCopy("original.\(format).plist")))
        expect(report.state == .fullMismatch, "\(format): state")
        expect(report.differing.count == 5, "\(format): five values differ")
        expect(report.formatName == format, "\(format): format name")
    }
}

test("all five applied reads as a full match (binary and XML)") {
    for format in formats {
        let report = try GaugingWriter.check(env: environment(try workingCopy("applied.\(format).plist")))
        expect(report.state == .fullMatch, "\(format): state")
        expect(report.differing.isEmpty, "\(format): nothing differs")
    }
}

test("post-update state reads as a partial rewrite of lastDOD0Update only") {
    for format in formats {
        let report = try GaugingWriter.check(env: environment(try workingCopy("post-update.\(format).plist")))
        expect(report.state == .partialRewrite, "\(format): state")
        expect(report.differing.map { $0.key } == [GaugingKey.lastDOD0Update], "\(format): only lastDOD0Update differs")
        let request = report.keys.first { $0.key == .lastFullChargeReq }
        expect(request?.current == GaugingValue.bool(false), "\(format): lastFullChargeReq stayed false")
    }
}

test("a report never contains the battery pack identifier") {
    let report = try GaugingWriter.check(env: environment(try workingCopy("original.binary.plist")))
    let json = String(decoding: try GaugeJSON.encoder().encode(report), as: UTF8.self)
    expect(!json.contains("FIXTUREPACK"), "identifier absent from JSON")
    expect(report.packIdHash.count == 8, "hash is 8 characters")
}

// MARK: - Apply

test("apply on the original changes exactly five keys and preserves everything else") {
    for format in formats {
        let path = try workingCopy("original.\(format).plist", mode: 0o640)
        let originalBytes = try bytes(path)
        let original = try GaugingPlist.load(path: path)
        let env = environment(path)

        let result = try GaugingWriter.apply(env: env, expectedSnapshotSHA: original.sha256)
        expect(result.outcome == "applied", "\(format): outcome")
        expect(Set(result.changedKeys) == Set(GaugingKey.allCases), "\(format): all five changed")
        expect(result.after.state == .fullMatch, "\(format): full match afterwards")

        let written = try GaugingPlist.load(path: path)
        expect(written.format == original.format, "\(format): plist format preserved")
        expect(isBinary(written.data) == (format == "binary"), "\(format): binary header")
        expect(isXML(written.data) == (format == "xml"), "\(format): XML header")
        expect(written.metadata.mode == 0o640, "\(format): permissions preserved")
        expect(written.metadata.uid == original.metadata.uid, "\(format): owner preserved")
        expect(written.metadata.gid == original.metadata.gid, "\(format): group preserved")
        expect(written.packIdentifier == original.packIdentifier, "\(format): pack identifier unchanged")
        expect(GaugingPlist.equalExceptManagedKeys(original.root, written.root, pack: original.packIdentifier),
               "\(format): nothing but the five keys changed")
        for key in GaugingKey.allCases {
            expect(written.values[key] == GaugingSchema.expected(key), "\(format): \(key.rawValue) has its expected value")
        }

        // Verified byte-for-byte backup with checksum, metadata and build.
        if let backup = result.backup {
            expect(backup.kind == .preApply, "\(format): backup kind")
            expect(backup.sha256 == Hashing.sha256(originalBytes), "\(format): backup checksum")
            expect(backup.macOSBuild == "TESTBUILD1", "\(format): backup build")
            expect(backup.metadata.mode == 0o640, "\(format): backup metadata")
            expect(try env.store.verifiedData(for: backup) == originalBytes, "\(format): backup is byte for byte")
            expect(try env.store.loadManifest().entries.contains(backup), "\(format): backup recorded, identical after reloading")
        } else {
            fail("\(format): no backup was made", line: #line)
        }
    }
}

test("apply on the post-update state changes only the rewritten key") {
    for format in formats {
        let path = try workingCopy("post-update.\(format).plist")
        let result = try GaugingWriter.apply(env: environment(path), expectedSnapshotSHA: nil)
        expect(result.changedKeys == [GaugingKey.lastDOD0Update], "\(format): one key changed")
        expect(result.before.state == .partialRewrite, "\(format): before")
        expect(result.after.state == .fullMatch, "\(format): after")

        let applied = try GaugingPlist.load(path: try workingCopy("applied.\(format).plist"))
        let written = try GaugingPlist.load(path: path)
        expect(GaugingPlist.deepEqual(applied.root, written.root), "\(format): equals the fully applied fixture")
    }
}

test("apply when everything matches skips the write and the backup") {
    for format in formats {
        let path = try workingCopy("applied.\(format).plist")
        let beforeBytes = try bytes(path)
        let beforeInode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        let env = environment(path)

        let result = try GaugingWriter.apply(env: env, expectedSnapshotSHA: nil)
        expect(result.outcome == "alreadyMatching", "\(format): outcome")
        expect(result.wroteFile == false, "\(format): nothing written")
        expect(result.backup == nil, "\(format): no backup")
        expect(try bytes(path) == beforeBytes, "\(format): bytes unchanged")
        let afterInode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        expect(beforeInode != nil && beforeInode == afterInode, "\(format): file was not replaced")
        expect(try env.store.loadManifest().entries.isEmpty, "\(format): no backup recorded")
    }
}

test("apply stops when the previewed snapshot is stale") {
    let path = try workingCopy("post-update.binary.plist")
    let beforeBytes = try bytes(path)
    let env = environment(path)
    expectError("snapshotChanged", "stale checksum") {
        _ = try GaugingWriter.apply(env: env, expectedSnapshotSHA: "0000")
    }
    expect(try bytes(path) == beforeBytes, "file untouched")
    expect(try env.store.loadManifest().entries.isEmpty, "no backup made")
}

// MARK: - Concurrent change

test("a concurrent change during apply aborts and leaves the new live file alone") {
    for format in formats {
        let path = try workingCopy("post-update.\(format).plist")
        // Simulates powerd rewriting the file after staging, just before the replacement.
        let concurrentBytes = try fixtureBytes("original.\(format).plist")
        let env = environment(path) {
            _ = try? concurrentBytes.write(to: URL(fileURLWithPath: path))
        }
        expectError("concurrentModification", "\(format): concurrent write") {
            _ = try GaugingWriter.apply(env: env, expectedSnapshotSHA: nil)
        }
        expect(try bytes(path) == concurrentBytes, "\(format): the concurrent write survives")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
            .filter { $0.hasSuffix(".tmp") }
        expect(leftovers.isEmpty, "\(format): no staging file left behind")
    }
}

// MARK: - Invalid schema

test("invalid schemas stop before any write") {
    let cases: [(String, String)] = [
        ("invalid-two-packs.xml.plist", "ambiguousPack"),
        ("invalid-pack-count.binary.plist", "ambiguousPack"),
        ("invalid-missing-key.binary.plist", "schema"),
        ("invalid-date-as-string.xml.plist", "schema"),
        ("invalid-bool-as-integer.binary.plist", "schema"),
        ("invalid-no-root-key.xml.plist", "schema"),
        ("invalid-not-a-plist.plist", "notAPropertyList"),
    ]
    for (name, code) in cases {
        let path = try workingCopy(name)
        let beforeBytes = try bytes(path)
        let env = environment(path)
        expectError(code, "\(name): check") { _ = try GaugingWriter.check(env: env) }
        expectError(code, "\(name): apply") { _ = try GaugingWriter.apply(env: env, expectedSnapshotSHA: nil) }
        expect(try bytes(path) == beforeBytes, "\(name): file untouched")
        expect(try env.store.loadManifest().entries.isEmpty, "\(name): no backup made")
    }
}

test("a symbolic link is rejected") {
    let target = try workingCopy("post-update.binary.plist")
    let link = workDirectory.appendingPathComponent("link-" + UUID().uuidString + ".plist").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    let beforeBytes = try bytes(target)
    let env = environment(link)
    expectError("symlink", "check through a symlink") { _ = try GaugingWriter.check(env: env) }
    expectError("symlink", "apply through a symlink") { _ = try GaugingWriter.apply(env: env, expectedSnapshotSHA: nil) }
    expect(try bytes(target) == beforeBytes, "target untouched")
}

test("a missing file is reported as unreadable") {
    let path = workDirectory.appendingPathComponent("absent.plist").path
    let env = environment(path)
    expectError("unreadable", "missing file") { _ = try GaugingWriter.check(env: env) }
}

// MARK: - Restore

test("restoring a verified backup returns the original bytes") {
    for format in formats {
        let path = try workingCopy("original.\(format).plist")
        let originalBytes = try bytes(path)
        let env = environment(path)

        let applied = try GaugingWriter.apply(env: env, expectedSnapshotSHA: nil)
        guard let backup = applied.backup else {
            fail("\(format): apply made no backup", line: #line)
            continue
        }
        let appliedBytes = try bytes(path)

        let restored = try GaugingWriter.restore(env: env, backupID: backup.id)
        expect(restored.outcome == "restored", "\(format): outcome")
        expect(try bytes(path) == originalBytes, "\(format): restore is byte for byte")
        expect(restored.after.state == .fullMismatch, "\(format): original state is back")
        expect(Set(restored.changedKeys) == Set(GaugingKey.allCases), "\(format): five values changed back")

        // The file that was replaced is itself kept as a snapshot.
        if let snapshot = restored.backup {
            expect(snapshot.kind == .preRestore, "\(format): snapshot kind")
            expect(try env.store.verifiedData(for: snapshot) == appliedBytes, "\(format): snapshot holds the replaced file")
        } else {
            fail("\(format): no pre-restore snapshot", line: #line)
        }
        expect(try env.store.loadManifest().entries.contains(backup), "\(format): earlier backup still available, identical after reloading")
        expect(try env.store.loadManifest().entries.count == 2, "\(format): two backups recorded")
    }
}

test("restore refuses a backup that fails its checksum") {
    let path = try workingCopy("original.binary.plist")
    let env = environment(path)
    guard let backup = try GaugingWriter.apply(env: env, expectedSnapshotSHA: nil).backup else {
        fail("apply made no backup", line: #line)
        return
    }
    let liveBytes = try bytes(path)
    try Data("damaged".utf8).write(to: env.store.backupURL(for: backup))

    expectError("backupChecksumMismatch", "damaged backup") {
        _ = try GaugingWriter.restore(env: env, backupID: backup.id)
    }
    expect(try bytes(path) == liveBytes, "live file untouched")
}

test("restore stops on a backup with an incompatible schema") {
    let path = try workingCopy("applied.binary.plist")
    let env = environment(path)
    let liveBytes = try bytes(path)
    let live = try GaugingPlist.load(path: path)

    // A backup whose checksum is valid but whose schema is not supported.
    let invalidBytes = try fixtureBytes("invalid-missing-key.binary.plist")
    let entry = BackupEntry(id: "incompatible.plist", createdAt: Date(), kind: .preApply,
                            sha256: Hashing.sha256(invalidBytes), metadata: live.metadata,
                            macOSBuild: "OLDERBUILD", formatName: "binary", keys: [],
                            packIdHash: "00000000")
    try env.store.saveManifest(BackupManifest(entries: [entry]))
    try invalidBytes.write(to: env.store.backupURL(for: entry))

    expectError("schema", "incompatible backup") {
        _ = try GaugingWriter.restore(env: env, backupID: entry.id)
    }
    expect(try bytes(path) == liveBytes, "live file untouched")
}

test("restore of an unknown backup fails") {
    let path = try workingCopy("applied.xml.plist")
    let env = environment(path)
    expectError("backupNotFound", "unknown id") {
        _ = try GaugingWriter.restore(env: env, backupID: "nope.plist")
    }
}

test("a concurrent change during restore aborts") {
    let path = try workingCopy("original.xml.plist")
    let firstEnv = environment(path)
    guard let backup = try GaugingWriter.apply(env: firstEnv, expectedSnapshotSHA: nil).backup else {
        fail("apply made no backup", line: #line)
        return
    }
    let concurrentBytes = try fixtureBytes("post-update.xml.plist")
    // Same backup store, plus a hook that rewrites the file just before the replacement.
    var env = firstEnv
    env.beforeReplace = {
        _ = try? concurrentBytes.write(to: URL(fileURLWithPath: path))
    }
    expectError("concurrentModification", "concurrent write during restore") {
        _ = try GaugingWriter.restore(env: env, backupID: backup.id)
    }
    expect(try bytes(path) == concurrentBytes, "the concurrent write survives")
}

// MARK: - Importing the original backup

test("importing the original backup validates, marks and de-duplicates it") {
    let path = try workingCopy("applied.binary.plist")
    let env = environment(path)
    let original = try workingCopy("original.binary.plist")

    let first = try GaugingWriter.importOriginal(env: env, sourcePath: original)
    let second = try GaugingWriter.importOriginal(env: env, sourcePath: original)
    expect(first.kind == .importedOriginal, "marked as the original")
    expect(first == second, "second import returns the same entry")
    expect(try env.store.loadManifest().entries.count == 1, "stored once")

    let invalid = try workingCopy("invalid-two-packs.xml.plist")
    expectError("ambiguousPack", "invalid file is refused") {
        _ = try GaugingWriter.importOriginal(env: env, sourcePath: invalid)
    }

    // The imported original can be restored like any other backup.
    let restored = try GaugingWriter.restore(env: env, backupID: first.id)
    expect(try bytes(path) == (try bytes(original)), "restored to the original bytes")
    expect(restored.after.state == .fullMismatch, "original state is back")
}

// MARK: - Stored dates

test("backup dates survive saving and reloading exactly (regression)") {
    // Fractions of a second used to change slightly in the JSON manifest.
    for fraction in [0.0, 0.1, 0.123456, 0.333333333, 0.5, 0.987654321] {
        let moment = Date(timeIntervalSince1970: 1_794_482_144 + fraction).wholeSeconds
        let data = try GaugeJSON.encoder().encode([moment])
        let back = try GaugeJSON.decoder().decode([Date].self, from: data)
        expect(back == [moment], "fraction \(fraction) round-trips")
    }
    for _ in 0..<20 {
        let path = try workingCopy("original.binary.plist")
        let env = environment(path)
        let entry = try env.store.add(try GaugingPlist.load(path: path), kind: .preApply,
                                      build: "TESTBUILD1", now: Date())
        expect(try env.store.loadManifest().entries == [entry], "entry identical after reloading")
    }
}

// MARK: - Type strictness

test("a boolean is never treated as equal to the integer 1") {
    let a: NSDictionary = ["flag": NSNumber(value: true)]
    let b: NSDictionary = ["flag": NSNumber(value: 1)]
    expect(GaugingPlist.deepEqual(a, b) == false, "true is not 1")
    expect(GaugingPlist.deepEqual(a, a), "a value equals itself")
}

test("the expected date is 2030-01-01T00:00:00Z") {
    expect(GaugeFormat.iso(GaugingSchema.expectedDate) == "2030-01-01T00:00:00Z", "ISO text")
    expect(GaugingSchema.expected(.lastFullChargeReq) == GaugingValue.bool(false), "request is false")
}

// MARK: - Summary

try? FileManager.default.removeItem(at: workDirectory)

print("")
if failureCount == 0 {
    print("ALL PASSED: \(checkCount) checks, 0 failures.")
    exit(0)
} else {
    print("FAILED: \(failureCount) of \(checkCount) checks failed.")
    exit(1)
}
