import Foundation

/// A validated, parsed copy of the gauging plist.
public struct LoadedPlist {
    public let data: Data
    public let sha256: String
    public let format: PropertyListSerialization.PropertyListFormat
    public let root: NSDictionary
    public let metadata: FileMetadata
    public let packIdentifier: String
    public let values: [GaugingKey: GaugingValue]

    public var formatName: String { format == .binary ? "binary" : "xml" }

    public var keyStatuses: [KeyStatus] {
        GaugingKey.allCases.compactMap { key in
            values[key].map { KeyStatus(key: key, current: $0) }
        }
    }
}

public enum GaugingPlist {

    // MARK: Loading and validation

    public static func load(path: String) throws -> LoadedPlist {
        let (data, metadata) = try SafeFile.read(path)
        return try parse(data: data, metadata: metadata)
    }

    /// Validates the exact nesting, the pack count and the type of each managed value.
    public static func parse(data: Data, metadata: FileMetadata) throws -> LoadedPlist {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw GaugingError.notAPropertyList(error.localizedDescription)
        }
        guard format == .binary || format == .xml else { throw GaugingError.unsupportedFormat }

        guard let root = object as? NSDictionary else {
            throw GaugingError.schema("the root object is not a dictionary")
        }
        guard let info = root[GaugingSchema.rootKey] as? NSDictionary else {
            throw GaugingError.schema("\(GaugingSchema.rootKey) is missing or is not a dictionary")
        }
        guard let packs = info[GaugingSchema.packDataKey] as? NSDictionary else {
            throw GaugingError.schema("\(GaugingSchema.packDataKey) is missing or is not a dictionary")
        }

        // batteryPackCount: looked up inside batteryGaugingMitigationInfo first, then at the root.
        guard let rawCount = info[GaugingSchema.packCountKey] ?? root[GaugingSchema.packCountKey] else {
            throw GaugingError.schema("\(GaugingSchema.packCountKey) is missing")
        }
        guard let count = integer(rawCount) else {
            throw GaugingError.schema("\(GaugingSchema.packCountKey) is not an integer")
        }
        guard count == 1 else {
            throw GaugingError.ambiguousPack("\(GaugingSchema.packCountKey) is \(count), expected 1")
        }
        guard packs.count == 1 else {
            throw GaugingError.ambiguousPack("\(GaugingSchema.packDataKey) has \(packs.count) entries, expected exactly 1")
        }
        guard let packIdentifier = packs.allKeys.first as? String, !packIdentifier.isEmpty else {
            throw GaugingError.schema("the battery pack identifier is not a string")
        }
        guard let pack = packs[packIdentifier] as? NSDictionary else {
            throw GaugingError.schema("the battery pack entry is not a dictionary")
        }

        var values: [GaugingKey: GaugingValue] = [:]
        for key in GaugingKey.allCases {
            let container = key.isPackLevel ? pack : info
            guard let raw = container[key.rawValue] else {
                throw GaugingError.schema("\(key.rawValue) is missing from \(key.location)")
            }
            switch GaugingSchema.expected(key) {
            case .date:
                guard let date = raw as? Date else {
                    throw GaugingError.schema("\(key.rawValue) is not a date")
                }
                values[key] = .date(date)
            case .bool:
                guard isBoolean(raw), let number = raw as? NSNumber else {
                    throw GaugingError.schema("\(key.rawValue) is not a boolean")
                }
                values[key] = .bool(number.boolValue)
            }
        }

        return LoadedPlist(data: data,
                           sha256: Hashing.sha256(data),
                           format: format,
                           root: root,
                           metadata: metadata,
                           packIdentifier: packIdentifier,
                           values: values)
    }

    public static func report(_ plist: LoadedPlist, build: String, now: Date) -> CheckReport {
        let keys = plist.keyStatuses
        let matching = keys.filter { $0.matches }.count
        let state: MatchState
        if matching == keys.count {
            state = .fullMatch
        } else if matching == 0 {
            state = .fullMismatch
        } else {
            state = .partialRewrite
        }
        return CheckReport(state: state,
                           keys: keys,
                           sha256: plist.sha256,
                           formatName: plist.formatName,
                           packIdHash: Hashing.shortHash(plist.packIdentifier),
                           metadata: plist.metadata,
                           checkedAt: now,
                           macOSBuild: build)
    }

    // MARK: Staging

    /// Returns new plist bytes, in the same format, where only `keys` are set to their expected values.
    public static func stagedData(from plist: LoadedPlist, changing keys: [GaugingKey]) throws -> Data {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: plist.data,
                                                                options: [.mutableContainers],
                                                                format: nil)
        } catch {
            throw GaugingError.stagedValidationFailed("cannot re-parse the snapshot")
        }
        guard let root = object as? NSMutableDictionary,
              let info = root[GaugingSchema.rootKey] as? NSMutableDictionary,
              let packs = info[GaugingSchema.packDataKey] as? NSMutableDictionary,
              let pack = packs[plist.packIdentifier] as? NSMutableDictionary else {
            throw GaugingError.stagedValidationFailed("the snapshot lost its expected structure")
        }

        for key in keys {
            let target = key.isPackLevel ? pack : info
            let name = key.rawValue as NSString
            switch GaugingSchema.expected(key) {
            case .date(let date):
                target.setObject(date as NSDate, forKey: name)
            case .bool(let flag):
                target.setObject(NSNumber(value: flag), forKey: name)
            }
        }

        do {
            return try PropertyListSerialization.data(fromPropertyList: root, format: plist.format, options: 0)
        } catch {
            throw GaugingError.stagedValidationFailed("cannot serialize the staged plist")
        }
    }

    /// True when the two parsed plists are identical apart from the five managed keys.
    public static func equalExceptManagedKeys(_ a: NSDictionary, _ b: NSDictionary, pack: String) -> Bool {
        var ignored = Set<[String]>()
        for key in GaugingKey.allCases {
            if key.isPackLevel {
                ignored.insert([GaugingSchema.rootKey, GaugingSchema.packDataKey, pack, key.rawValue])
            } else {
                ignored.insert([GaugingSchema.rootKey, key.rawValue])
            }
        }
        return deepEqual(a, b, path: [], ignoring: ignored)
    }

    // MARK: Type-strict helpers

    static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID()
    }

    static func integer(_ value: Any) -> Int? {
        guard !isBoolean(value), let number = value as? NSNumber else { return nil }
        guard !CFNumberIsFloatType(number as CFNumber) else { return nil }
        return number.intValue
    }

    /// Structural equality that also compares value types (a boolean never equals the number 1).
    public static func deepEqual(_ a: Any, _ b: Any, path: [String] = [], ignoring: Set<[String]> = []) -> Bool {
        if let x = a as? NSDictionary {
            guard let y = b as? NSDictionary, x.count == y.count else { return false }
            for (rawKey, value) in x {
                guard let key = rawKey as? String, let other = y[key] else { return false }
                let childPath = path + [key]
                if ignoring.contains(childPath) { continue }
                if !deepEqual(value, other, path: childPath, ignoring: ignoring) { return false }
            }
            return true
        }
        if let x = a as? NSArray {
            guard let y = b as? NSArray, x.count == y.count else { return false }
            for index in 0..<x.count {
                if !deepEqual(x[index], y[index], path: path + ["[\(index)]"], ignoring: ignoring) {
                    return false
                }
            }
            return true
        }
        if let x = a as? NSString {
            guard let y = b as? NSString else { return false }
            return x.isEqual(to: y as String)
        }
        if let x = a as? NSDate {
            guard let y = b as? NSDate else { return false }
            return x.isEqual(to: y as Date)
        }
        if let x = a as? NSData {
            guard let y = b as? NSData else { return false }
            return x.isEqual(to: y as Data)
        }
        if let x = a as? NSNumber {
            guard let y = b as? NSNumber else { return false }
            let xBool = isBoolean(x), yBool = isBoolean(y)
            if xBool || yBool { return xBool && yBool && x.boolValue == y.boolValue }
            guard CFNumberIsFloatType(x as CFNumber) == CFNumberIsFloatType(y as CFNumber) else { return false }
            return x.isEqual(to: y)
        }
        return false
    }
}
