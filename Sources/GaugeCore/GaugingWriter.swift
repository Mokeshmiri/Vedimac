import Foundation

/// Everything an operation needs to know about its surroundings.
/// Tests point this at fixture copies in a temporary folder.
public struct GaugingEnvironment {
    public var plistPath: String
    public var store: BackupStore
    public var macOSBuild: String
    public var now: () -> Date
    /// Test hook, called after staging and immediately before the live file is re-checked.
    public var beforeReplace: (() -> Void)?

    public init(plistPath: String,
                store: BackupStore,
                macOSBuild: String,
                now: @escaping () -> Date = { Date() },
                beforeReplace: (() -> Void)? = nil) {
        self.plistPath = plistPath
        self.store = store
        self.macOSBuild = macOSBuild
        self.now = now
        self.beforeReplace = beforeReplace
    }
}

/// The write operations. Nothing in this file (or this library) restarts the computer.
public enum GaugingWriter {

    public static func check(env: GaugingEnvironment) throws -> CheckReport {
        let plist = try GaugingPlist.load(path: env.plistPath)
        return GaugingPlist.report(plist, build: env.macOSBuild, now: env.now())
    }

    /// Sets the managed keys that differ to their expected values.
    /// - Parameter expectedSnapshotSHA: checksum of the file the user previewed. If the live file
    ///   no longer has this checksum the operation stops before anything is written.
    public static func apply(env: GaugingEnvironment, expectedSnapshotSHA: String?) throws -> OperationResult {
        // 1. Validate nesting, pack count and value types.
        let snapshot = try GaugingPlist.load(path: env.plistPath)
        let before = GaugingPlist.report(snapshot, build: env.macOSBuild, now: env.now())

        if let expected = expectedSnapshotSHA, expected != snapshot.sha256 {
            throw GaugingError.snapshotChanged
        }

        let differing = before.differing.map { $0.key }
        if differing.isEmpty {
            return OperationResult(kind: "apply", outcome: "alreadyMatching", changedKeys: [],
                                   backup: nil, restoredBackupID: nil, before: before, after: before,
                                   finishedAt: env.now(), macOSBuild: env.macOSBuild,
                                   restartRequested: false)
        }

        // 2. Verified, timestamped, byte-for-byte backup.
        let backup = try env.store.add(snapshot, kind: .preApply, build: env.macOSBuild, now: env.now())

        // 3. Change only the keys that differ, in the same plist format, then validate the result.
        let staged = try GaugingPlist.stagedData(from: snapshot, changing: differing)
        let stagedPlist: LoadedPlist
        do {
            stagedPlist = try GaugingPlist.parse(data: staged, metadata: snapshot.metadata)
        } catch {
            throw GaugingError.stagedValidationFailed(error.localizedDescription)
        }
        guard stagedPlist.format == snapshot.format else {
            throw GaugingError.stagedValidationFailed("the plist format changed")
        }
        guard stagedPlist.packIdentifier == snapshot.packIdentifier else {
            throw GaugingError.stagedValidationFailed("the battery pack identifier changed")
        }
        for key in GaugingKey.allCases {
            guard stagedPlist.values[key] == GaugingSchema.expected(key) else {
                throw GaugingError.stagedValidationFailed("\(key.rawValue) does not have its expected value")
            }
        }
        guard GaugingPlist.equalExceptManagedKeys(snapshot.root, stagedPlist.root,
                                                  pack: snapshot.packIdentifier) else {
            throw GaugingError.stagedValidationFailed("something other than the five managed keys changed")
        }

        // 4. Re-check the live file against the snapshot, then replace it atomically.
        try SafeFile.atomicReplace(path: env.plistPath,
                                   with: staged,
                                   metadata: snapshot.metadata,
                                   expectedLiveSHA: snapshot.sha256,
                                   beforeReplace: env.beforeReplace)

        // Verify what is on disk now.
        let written = try GaugingPlist.load(path: env.plistPath)
        let after = GaugingPlist.report(written, build: env.macOSBuild, now: env.now())
        guard after.state == .fullMatch else {
            throw GaugingError.verificationFailed("not all five values match after writing")
        }

        return OperationResult(kind: "apply", outcome: "applied", changedKeys: differing,
                               backup: backup, restoredBackupID: nil, before: before, after: after,
                               finishedAt: env.now(), macOSBuild: env.macOSBuild,
                               restartRequested: false)
    }

    /// Puts a verified backup back, after saving a snapshot of the current file.
    public static func restore(env: GaugingEnvironment, backupID: String) throws -> OperationResult {
        let manifest: BackupManifest
        do {
            manifest = try env.store.loadManifest()
        } catch {
            throw GaugingError.backupNotFound(backupID)
        }
        guard let entry = manifest.entries.first(where: { $0.id == backupID }) else {
            throw GaugingError.backupNotFound(backupID)
        }

        // Verify the checksum, then make sure the backup still has a schema we understand.
        let backupData = try env.store.verifiedData(for: entry)
        let backupPlist = try GaugingPlist.parse(data: backupData, metadata: entry.metadata)

        let live = try GaugingPlist.load(path: env.plistPath)
        let before = GaugingPlist.report(live, build: env.macOSBuild, now: env.now())
        guard backupPlist.packIdentifier == live.packIdentifier else {
            throw GaugingError.packMismatch
        }

        if live.sha256 == entry.sha256 {
            return OperationResult(kind: "restore", outcome: "alreadyMatching", changedKeys: [],
                                   backup: nil, restoredBackupID: entry.id, before: before, after: before,
                                   finishedAt: env.now(), macOSBuild: env.macOSBuild,
                                   restartRequested: false)
        }

        // Snapshot of the current file before it is replaced.
        let snapshotEntry = try env.store.add(live, kind: .preRestore, build: env.macOSBuild, now: env.now())

        // The backup bytes go back unchanged. Owner, group and permissions follow the live file.
        try SafeFile.atomicReplace(path: env.plistPath,
                                   with: backupData,
                                   metadata: live.metadata,
                                   expectedLiveSHA: live.sha256,
                                   beforeReplace: env.beforeReplace)

        let written = try GaugingPlist.load(path: env.plistPath)
        guard written.sha256 == entry.sha256 else {
            throw GaugingError.verificationFailed("the restored file does not match the backup checksum")
        }
        let after = GaugingPlist.report(written, build: env.macOSBuild, now: env.now())
        let changed = GaugingKey.allCases.filter { live.values[$0] != written.values[$0] }

        return OperationResult(kind: "restore", outcome: "restored", changedKeys: changed,
                               backup: snapshotEntry, restoredBackupID: entry.id, before: before, after: after,
                               finishedAt: env.now(), macOSBuild: env.macOSBuild,
                               restartRequested: false)
    }

    /// Copies a backup made outside the app (for example by the original Terminal script) into the
    /// store, marked as the original pre-workaround backup. The file must pass schema validation.
    public static func importOriginal(env: GaugingEnvironment, sourcePath: String) throws -> BackupEntry {
        let plist = try GaugingPlist.load(path: sourcePath)
        if let manifest = try? env.store.loadManifest(),
           let existing = manifest.entries.first(where: {
               $0.kind == .importedOriginal && $0.sha256 == plist.sha256
           }) {
            return existing
        }
        return try env.store.add(plist, kind: .importedOriginal, build: env.macOSBuild, now: env.now())
    }
}
