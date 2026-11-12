import Foundation

/// The five values the workaround manages.
public enum GaugingKey: String, CaseIterable, Codable, Sendable {
    case lastDOD0Update
    case lastQMaxUpdate
    case lastQualQMaxDate
    case lastFullChargeDate
    case lastFullChargeReq

    /// True for the three keys stored inside `batteryPackData.<pack>`.
    public var isPackLevel: Bool {
        switch self {
        case .lastDOD0Update, .lastQMaxUpdate, .lastQualQMaxDate: return true
        case .lastFullChargeDate, .lastFullChargeReq: return false
        }
    }

    /// Location relative to `batteryGaugingMitigationInfo`.
    public var location: String {
        isPackLevel ? "batteryPackData.<pack>" : "batteryGaugingMitigationInfo"
    }
}

/// A typed plist value. Types matter: a date must stay a date and a boolean a boolean.
public enum GaugingValue: Equatable, Codable, Sendable {
    case date(Date)
    case bool(Bool)

    public var display: String {
        switch self {
        case .date(let d): return GaugeFormat.iso(d)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    public var typeName: String {
        switch self {
        case .date: return "Date"
        case .bool: return "Boolean"
        }
    }
}

public enum GaugingSchema {
    /// The only file the root helper will ever read or write.
    public static let systemPlistPath =
        "/private/var/root/Library/Preferences/com.apple.powerd.batterygauging.plist"

    public static let rootKey = "batteryGaugingMitigationInfo"
    public static let packDataKey = "batteryPackData"
    public static let packCountKey = "batteryPackCount"

    /// 2030-01-01T00:00:00Z
    public static let expectedDate = Date(timeIntervalSince1970: 1_893_456_000)

    public static func expected(_ key: GaugingKey) -> GaugingValue {
        switch key {
        case .lastFullChargeReq: return .bool(false)
        default: return .date(expectedDate)
        }
    }
}

public enum MatchState: String, Codable, Sendable {
    /// All five values equal the expected values.
    case fullMatch
    /// Some, but not all, values equal the expected values.
    case partialRewrite
    /// None of the five values equal the expected values.
    case fullMismatch
}

public struct KeyStatus: Codable, Equatable, Identifiable, Sendable {
    public var key: GaugingKey
    public var location: String
    public var current: GaugingValue
    public var expected: GaugingValue
    public var matches: Bool
    public var id: String { key.rawValue }

    public init(key: GaugingKey, current: GaugingValue) {
        self.key = key
        self.location = key.location
        self.current = current
        self.expected = GaugingSchema.expected(key)
        self.matches = current == self.expected
    }
}

public struct FileMetadata: Codable, Equatable, Sendable {
    public var uid: UInt32
    public var gid: UInt32
    /// Permission bits only (for example 0o600).
    public var mode: UInt16
    public var size: Int64
    public var modifiedAt: Date

    public init(uid: UInt32, gid: UInt32, mode: UInt16, size: Int64, modifiedAt: Date) {
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var modeString: String { String(mode, radix: 8) }
}

/// Result of reading and validating the plist. Contains no battery identifier:
/// the pack identifier is reduced to a short hash.
public struct CheckReport: Codable, Equatable, Sendable {
    public var state: MatchState
    public var keys: [KeyStatus]
    public var sha256: String
    public var formatName: String
    public var packIdHash: String
    public var metadata: FileMetadata
    public var checkedAt: Date
    public var macOSBuild: String

    public var differing: [KeyStatus] { keys.filter { !$0.matches } }
}

public enum BackupKind: String, Codable, Sendable {
    case preApply
    case preRestore
    case importedOriginal
}

public struct BackupEntry: Codable, Equatable, Identifiable, Sendable {
    /// File name inside the Backups folder.
    public var id: String
    public var createdAt: Date
    public var kind: BackupKind
    public var sha256: String
    public var metadata: FileMetadata
    public var macOSBuild: String
    public var formatName: String
    public var keys: [KeyStatus]
    public var packIdHash: String

    public init(id: String, createdAt: Date, kind: BackupKind, sha256: String,
                metadata: FileMetadata, macOSBuild: String, formatName: String,
                keys: [KeyStatus], packIdHash: String) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.sha256 = sha256
        self.metadata = metadata
        self.macOSBuild = macOSBuild
        self.formatName = formatName
        self.keys = keys
        self.packIdHash = packIdHash
    }
}

public struct OperationResult: Codable, Equatable, Sendable {
    /// "apply" or "restore"
    public var kind: String
    /// "applied", "restored" or "alreadyMatching" (nothing written)
    public var outcome: String
    public var changedKeys: [GaugingKey]
    public var backup: BackupEntry?
    public var restoredBackupID: String?
    public var before: CheckReport
    public var after: CheckReport
    public var finishedAt: Date
    public var macOSBuild: String
    public var restartRequested: Bool

    public var wroteFile: Bool { outcome != "alreadyMatching" }
}

/// What the helper prints, as one line of JSON.
public struct HelperResponse: Codable, Sendable {
    public var ok: Bool
    public var errorCode: String?
    public var errorMessage: String?
    public var report: CheckReport?
    public var operation: OperationResult?
    public var backup: BackupEntry?

    public init(ok: Bool, errorCode: String? = nil, errorMessage: String? = nil,
                report: CheckReport? = nil, operation: OperationResult? = nil,
                backup: BackupEntry? = nil) {
        self.ok = ok
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.report = report
        self.operation = operation
        self.backup = backup
    }
}

public enum GaugingError: Error, LocalizedError, Equatable {
    case symlink(String)
    case notRegularFile(String)
    case unreadable(String)
    case notAPropertyList(String)
    case unsupportedFormat
    case schema(String)
    case ambiguousPack(String)
    case snapshotChanged
    case concurrentModification
    case backupFailed(String)
    case backupChecksumMismatch(String)
    case backupNotFound(String)
    case packMismatch
    case stagedValidationFailed(String)
    case writeFailed(String)
    case verificationFailed(String)

    public var code: String {
        switch self {
        case .symlink: return "symlink"
        case .notRegularFile: return "notRegularFile"
        case .unreadable: return "unreadable"
        case .notAPropertyList: return "notAPropertyList"
        case .unsupportedFormat: return "unsupportedFormat"
        case .schema: return "schema"
        case .ambiguousPack: return "ambiguousPack"
        case .snapshotChanged: return "snapshotChanged"
        case .concurrentModification: return "concurrentModification"
        case .backupFailed: return "backupFailed"
        case .backupChecksumMismatch: return "backupChecksumMismatch"
        case .backupNotFound: return "backupNotFound"
        case .packMismatch: return "packMismatch"
        case .stagedValidationFailed: return "stagedValidationFailed"
        case .writeFailed: return "writeFailed"
        case .verificationFailed: return "verificationFailed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .symlink(let p):
            return "\(p) is a symbolic link. Stopped without reading or writing."
        case .notRegularFile(let p):
            return "\(p) is not a regular file. Stopped."
        case .unreadable(let why):
            return "The file could not be read: \(why)"
        case .notAPropertyList(let why):
            return "The file is not a valid property list: \(why)"
        case .unsupportedFormat:
            return "The property list is neither binary nor XML. Stopped."
        case .schema(let why):
            return "Unsupported schema: \(why). Nothing was changed."
        case .ambiguousPack(let why):
            return "Cannot select a battery pack unambiguously: \(why). Nothing was changed."
        case .snapshotChanged:
            return "The file changed after you previewed it. Run the check again to see the current values."
        case .concurrentModification:
            return "The file was modified while the change was being staged (powerd may have written to it). The live file was left as it is."
        case .backupFailed(let why):
            return "The backup could not be created or verified: \(why). Nothing was changed."
        case .backupChecksumMismatch(let id):
            return "Backup \(id) does not match its recorded checksum. It will not be restored."
        case .backupNotFound(let id):
            return "Backup \(id) was not found."
        case .packMismatch:
            return "The backup belongs to a different battery pack identifier than the live file. Stopped."
        case .stagedValidationFailed(let why):
            return "The staged file failed validation: \(why). The live file was left as it is."
        case .writeFailed(let why):
            return "Writing failed: \(why)"
        case .verificationFailed(let why):
            return "The file was replaced but verification failed: \(why)"
        }
    }
}
