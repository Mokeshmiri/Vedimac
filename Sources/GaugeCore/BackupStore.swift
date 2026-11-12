import Foundation

public struct BackupManifest: Codable, Equatable {
    public var version: Int
    public var entries: [BackupEntry]

    public init(version: Int = 1, entries: [BackupEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

/// Folder layout:
///   <directory>/manifest.json         world-readable; contains no battery identifier
///   <directory>/last-operation.json   world-readable; result of the last apply/restore
///   <directory>/Backups/*.plist       byte-for-byte copies, readable by the owner only
public struct BackupStore {
    public static let systemDirectory = URL(fileURLWithPath: "/Library/Application Support/ChargeWatch")

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
    public var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    public var lastOperationURL: URL { directory.appendingPathComponent("last-operation.json") }

    public func loadManifest() throws -> BackupManifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return BackupManifest() }
        let data = try Data(contentsOf: manifestURL)
        return try GaugeJSON.decoder().decode(BackupManifest.self, from: data)
    }

    public func saveManifest(_ manifest: BackupManifest) throws {
        try prepareDirectories()
        let data = try GaugeJSON.encoder(pretty: true).encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
    }

    public func backupURL(for entry: BackupEntry) -> URL {
        // Only the last path component is used, so an entry can never point outside the folder.
        backupsDirectory.appendingPathComponent((entry.id as NSString).lastPathComponent)
    }

    /// Stores a byte-for-byte copy, reads it back, and records it only if the checksum matches.
    public func add(_ plist: LoadedPlist, kind: BackupKind, build: String, now: Date) throws -> BackupEntry {
        do {
            try prepareDirectories()
        } catch {
            throw GaugingError.backupFailed("cannot create the backup folder: \(error.localizedDescription)")
        }

        let stamp = GaugeFormat.fileStamp(now)
        let short = String(plist.sha256.prefix(8))
        var name = "gauging-\(stamp)-\(kind.rawValue)-\(short).plist"
        var counter = 1
        while FileManager.default.fileExists(atPath: backupsDirectory.appendingPathComponent(name).path) {
            counter += 1
            name = "gauging-\(stamp)-\(kind.rawValue)-\(short)-\(counter).plist"
        }
        let url = backupsDirectory.appendingPathComponent(name)

        do {
            try plist.data.write(to: url, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw GaugingError.backupFailed(error.localizedDescription)
        }

        let (readBack, _) = try SafeFile.read(url.path)
        guard readBack == plist.data, Hashing.sha256(readBack) == plist.sha256 else {
            try? FileManager.default.removeItem(at: url)
            throw GaugingError.backupFailed("the copy does not match the original byte for byte")
        }

        // Dates are cut to whole seconds. A date with a fraction of a second does not always come
        // back identical from the JSON manifest, which made a stored entry differ from the
        // in-memory one (found by the fixture checks on the target Mac).
        var metadata = plist.metadata
        metadata.modifiedAt = metadata.modifiedAt.wholeSeconds
        let entry = BackupEntry(id: name,
                                createdAt: now.wholeSeconds,
                                kind: kind,
                                sha256: plist.sha256,
                                metadata: metadata,
                                macOSBuild: build,
                                formatName: plist.formatName,
                                keys: plist.keyStatuses,
                                packIdHash: Hashing.shortHash(plist.packIdentifier))
        do {
            var manifest = try loadManifest()
            manifest.entries.append(entry)
            try saveManifest(manifest)
        } catch {
            throw GaugingError.backupFailed("cannot record the backup: \(error.localizedDescription)")
        }
        return entry
    }

    /// Returns the backup bytes only if they still match the recorded checksum.
    public func verifiedData(for entry: BackupEntry) throws -> Data {
        let url = backupURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GaugingError.backupNotFound(entry.id)
        }
        let (data, _) = try SafeFile.read(url.path)
        guard Hashing.sha256(data) == entry.sha256 else {
            throw GaugingError.backupChecksumMismatch(entry.id)
        }
        return data
    }

    public func saveLastOperation(_ result: OperationResult) {
        guard let data = try? GaugeJSON.encoder(pretty: true).encode(result) else { return }
        try? prepareDirectories()
        try? data.write(to: lastOperationURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lastOperationURL.path)
    }

    public func loadLastOperation() -> OperationResult? {
        guard let data = try? Data(contentsOf: lastOperationURL) else { return nil }
        return try? GaugeJSON.decoder().decode(OperationResult.self, from: data)
    }

    private func prepareDirectories() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        }
        if !manager.fileExists(atPath: backupsDirectory.path) {
            try manager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
    }
}
