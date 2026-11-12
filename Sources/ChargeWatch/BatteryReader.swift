import Foundation
import IOKit
import IOKit.ps

/// Reads battery data. Nothing here needs administrator rights and the battery serial is never read.
///
/// Sources:
/// - IOPowerSources (`IOPSCopyPowerSourcesInfo`): public, documented API.
/// - `IOPSCopyExternalPowerAdapterDetails`: public API.
/// - The `AppleSmartBattery` IORegistry entry: read through public IOKit calls, but its keys are
///   undocumented and can change between macOS versions. The app labels these readings.
enum BatteryReader {

    static func read() -> BatteryReading {
        var reading = BatteryReading(timestamp: Date())
        readPowerSources(&reading)
        readAdapter(&reading)
        readRegistry(&reading)
        return reading
    }

    // MARK: IOPowerSources (public)

    private static func readPowerSources(_ reading: inout BatteryReading) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        guard let listRef = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return }
        let sources = (listRef as NSArray) as [AnyObject]

        for source in sources {
            guard let descriptionRef = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue(),
                  let info = (descriptionRef as NSDictionary) as? [String: Any] else { continue }
            // kIOPSTypeKey / kIOPSInternalBatteryType
            guard (info["Type"] as? String) == "InternalBattery" else { continue }

            reading.hasBattery = true
            // kIOPSCurrentCapacityKey / kIOPSMaxCapacityKey: percentage on Apple silicon (max is 100).
            if let current = int(info["Current Capacity"]), let maximum = int(info["Max Capacity"]), maximum > 0 {
                reading.percent = Int((Double(current) / Double(maximum) * 100).rounded())
            }
            // kIOPSPowerSourceStateKey: "AC Power" or "Battery Power"
            if let state = info["Power Source State"] as? String {
                reading.acConnected = (state == "AC Power")
            }
            reading.isCharging = info["Is Charging"] as? Bool          // kIOPSIsChargingKey
            reading.isCharged = info["Is Charged"] as? Bool            // kIOPSIsChargedKey
            if let minutes = int(info["Time to Empty"]), minutes >= 0 { // -1 means "still calculating"
                reading.minutesToEmpty = minutes
            }
            if let minutes = int(info["Time to Full Charge"]), minutes >= 0 {
                reading.minutesToFull = minutes
            }
            reading.condition = info["BatteryHealth"] as? String        // kIOPSBatteryHealthKey
            break
        }
    }

    private static func readAdapter(_ reading: inout BatteryReading) {
        guard let detailsRef = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue(),
              let details = (detailsRef as NSDictionary) as? [String: Any] else { return }
        reading.adapterWatts = int(details["Watts"])
        reading.adapterName = (details["Name"] as? String) ?? (details["Description"] as? String)
        reading.adapterVoltageMV = int(details["AdapterVoltage"])
        reading.adapterCurrentMA = int(details["Current"])
    }

    // MARK: AppleSmartBattery registry (undocumented keys)

    private static func readRegistry(_ reading: inout BatteryReading) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let propertiesRef = unmanaged?.takeRetainedValue(),
              let properties = (propertiesRef as NSDictionary) as? [String: Any] else { return }

        // On recent macOS versions the capacities sit inside the nested "BatteryData" dictionary
        // (seen on macOS 27.2.1). Older versions put them at the top level. Both are checked.
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { properties[key] ?? batteryData[key] }

        reading.cycleCount = int(value("CycleCount"))
        reading.designCapacityMAh = int(value("DesignCapacity"))
        reading.fullChargeCapacityMAh = int(value("AppleRawMaxCapacity"))
            ?? int(value("FullChargeCapacity"))
            ?? int(value("NominalChargeCapacity"))

        // Reported in hundredths of a degree Celsius. Discarded if the result is implausible.
        // Not present on every Mac: macOS 27.2.1 on the tested MacBook does not report it.
        if let raw = int(value("Temperature")) ?? int(value("VirtualTemperature")) {
            let celsius = Double(raw) / 100
            if celsius > -20 && celsius < 100 { reading.temperatureC = celsius }
        }
        if let millivolts = int(properties["Voltage"]), millivolts > 0 {
            reading.voltageMV = millivolts
        }
        // Signed milliamps: negative while discharging.
        // Signed milliamps stored as an unsigned 64-bit pattern (ioreg prints -332 as
        // 18446744073709551284). int64Value reinterprets the bits, which gives the signed value.
        if let number = (properties["Amperage"] ?? properties["InstantAmperage"]) as? NSNumber {
            let milliamps = Int(truncatingIfNeeded: number.int64Value)
            if abs(milliamps) < 20_000 { reading.currentMA = milliamps }
        }
        if let charger = properties["ChargerData"] as? [String: Any] {
            reading.notChargingReason = int(charger["NotChargingReason"])
        }
        // Fallbacks when IOPowerSources did not answer.
        if reading.acConnected == nil { reading.acConnected = properties["ExternalConnected"] as? Bool }
        if reading.isCharging == nil { reading.isCharging = properties["IsCharging"] as? Bool }
        if reading.percent == nil, let current = int(properties["CurrentCapacity"]) {
            reading.percent = current
            reading.hasBattery = true
        }

        var hints: [String] = []
        var stateFound = false
        collectGaugingHints(properties, path: "", depth: 0, into: &hints, stateFound: &stateFound)
        reading.gaugingHints = hints
        reading.gaugingStateInRegistry = stateFound
    }

    /// Collects registry keys or string values that mention gauging. Only those entries are kept,
    /// so identifiers such as the serial number never end up in the app's records.
    private static func collectGaugingHints(_ value: Any, path: String, depth: Int,
                                            into hints: inout [String], stateFound: inout Bool) {
        guard depth < 6, hints.count < 20 else { return }
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                let childPath = path.isEmpty ? key : path + "." + key
                let isContainer = child is [String: Any] || child is [Any]
                if let text = child as? String, mentionsGauging(text) {
                    hints.append("\(childPath) = \(text)")
                    stateFound = true
                } else if mentionsGauging(key), !isContainer {
                    hints.append("\(childPath) = \(child)")
                } else if isContainer {
                    collectGaugingHints(child, path: childPath, depth: depth + 1, into: &hints, stateFound: &stateFound)
                }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.prefix(8).enumerated() {
                collectGaugingHints(child, path: path + "[\(index)]", depth: depth + 1,
                                    into: &hints, stateFound: &stateFound)
            }
        }
    }

    static func mentionsGauging(_ text: String) -> Bool {
        text.range(of: "gaug", options: .caseInsensitive) != nil
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
