import Foundation
import CryptoKit
import Darwin

extension Date {
    /// The same moment without its fraction of a second. Survives a JSON round trip exactly.
    public var wholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}

public enum GaugeFormat {
    /// ISO 8601 in UTC, e.g. 2030-01-01T00:00:00Z. Fractional seconds are shown only when present.
    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let seconds = date.timeIntervalSince1970
        if seconds.rounded(.down) == seconds {
            formatter.formatOptions = [.withInternetDateTime]
        } else {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        return formatter.string(from: date)
    }

    /// Compact UTC stamp for file names, e.g. 20261111T103000Z.
    public static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}

public enum GaugeJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

public enum Hashing {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Short, non-reversible label for a battery pack identifier.
    public static func shortHash(_ text: String) -> String {
        String(sha256(Data(text.utf8)).prefix(8))
    }
}

public enum SystemBuild {
    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// macOS build string such as "26B131".
    public static func current() -> String {
        sysctlString("kern.osversion") ?? "unknown"
    }
}

/// File access that refuses symbolic links and anything that is not a regular file.
public enum SafeFile {
    public static func errnoText() -> String {
        String(cString: strerror(errno))
    }

    public static func read(_ path: String) throws -> (Data, FileMetadata) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ELOOP { throw GaugingError.symlink(path) }
            throw GaugingError.unreadable(errnoText())
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw GaugingError.unreadable(errnoText()) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw GaugingError.notRegularFile(path) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw GaugingError.unreadable(errnoText())
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }

        let metadata = FileMetadata(
            uid: info.st_uid,
            gid: info.st_gid,
            mode: UInt16(info.st_mode & 0o7777),
            size: Int64(info.st_size),
            modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        )
        return (data, metadata)
    }

    /// Copies extended attributes. Best effort: a failure here is not fatal.
    public static func copyExtendedAttributes(from source: String, to destination: String) {
        let size = listxattr(source, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        let got = listxattr(source, &names, size, XATTR_NOFOLLOW)
        guard got > 0 else { return }

        var start = 0
        for index in 0..<got where names[index] == 0 {
            let name = String(cString: Array(names[start...index]))
            start = index + 1
            let valueSize = getxattr(source, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard valueSize >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: max(valueSize, 1))
            let valueGot = getxattr(source, name, &value, valueSize, 0, XATTR_NOFOLLOW)
            guard valueGot >= 0 else { continue }
            _ = setxattr(destination, name, value, valueGot, 0, XATTR_NOFOLLOW)
        }
    }

    /// Writes `data` to a new temporary file next to `path`, checks that the live file still has
    /// `expectedLiveSHA`, then renames the temporary file over it (atomic on the same volume).
    public static func atomicReplace(path: String,
                                     with data: Data,
                                     metadata: FileMetadata,
                                     expectedLiveSHA: String,
                                     beforeReplace: (() -> Void)? = nil) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temporary = directory + "/." + name + ".chargewatch-" + UUID().uuidString + ".tmp"

        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GaugingError.writeFailed("cannot create staging file: \(errnoText())") }

        var committed = false
        defer { if !committed { unlink(temporary) } }

        do {
            defer { close(fd) }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw GaugingError.writeFailed("write: \(errnoText())")
                    }
                    offset += written
                }
            }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw GaugingError.writeFailed("fstat: \(errnoText())") }
            if info.st_uid != metadata.uid || info.st_gid != metadata.gid {
                guard fchown(fd, metadata.uid, metadata.gid) == 0 else {
                    throw GaugingError.writeFailed("cannot preserve owner/group: \(errnoText())")
                }
            }
            guard fchmod(fd, mode_t(metadata.mode)) == 0 else {
                throw GaugingError.writeFailed("cannot preserve permissions: \(errnoText())")
            }
            guard fsync(fd) == 0 else { throw GaugingError.writeFailed("fsync: \(errnoText())") }
        }

        copyExtendedAttributes(from: path, to: temporary)

        // The staged file on disk must be exactly what we intended to write.
        let (stagedOnDisk, _) = try read(temporary)
        guard stagedOnDisk == data else {
            throw GaugingError.stagedValidationFailed("staged bytes differ from the intended bytes")
        }

        beforeReplace?()

        // powerd can write to the file at any time: confirm it is still the snapshot we validated.
        let (live, _) = try read(path)
        guard Hashing.sha256(live) == expectedLiveSHA else {
            throw GaugingError.concurrentModification
        }

        guard rename(temporary, path) == 0 else {
            throw GaugingError.writeFailed("rename: \(errnoText())")
        }
        committed = true

        let directoryFD = open(directory, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            close(directoryFD)
        }
    }
}
