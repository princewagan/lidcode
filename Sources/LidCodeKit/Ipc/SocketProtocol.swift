import Foundation

// MARK: - App ↔ CLI

/// Everything `lidcode` can ask the running app to do. The app owns all state; the CLI
/// is a thin client, so a script and the menu bar always read one shared truth.
public enum AppRequest: Codable, Sendable {
    case status
    case start(second: Int?, mode: HoldMode)
    case stop
    case clamshell(isOn: Bool, second: Int?, mode: HoldMode)
    case autowatch(isOn: Bool)
    case watch(pattern: String)
    case unwatch(pattern: String)
    case pattern
    /// Explicit work lease — the agent-awareness path. An agent declares it is busy
    /// instead of being inferred from a process name at 0% CPU.
    ///
    /// `key` makes a claim idempotent: claiming twice with the same key renews the
    /// one lease rather than stacking two. That is what lets a hook fire on every
    /// turn without leaking a lease per turn.
    case claim(label: String, ttlSecond: Int, key: String?)
    case renew(token: String, ttlSecond: Int)
    case release(token: String)
    case releaseKey(key: String)
    case lease
    case recentLog(limit: Int)
    case notify(title: String, body: String)
    case settingList
    /// Also how the two safety guards are turned on and off — they are persisted
    /// settings, not a transient mode, so they travel in the same patch as every other
    /// threshold. This replaces the old `override(second:)` request, which expressed a
    /// bounded waiver the product no longer has.
    case updateSetting(SettingPatch)
    /// The same sweep the menu bar draws, as text. Shares one implementation with the
    /// panel so a script and the UI can never disagree about what is broken.
    case health
}

/// Only the fields a caller actually passed. Anything nil is left alone, so
/// `lidcode set --soft-battery 25` cannot silently reset every other threshold.
public struct SettingPatch: Codable, Sendable {
    public var softBatteryPercent: Int?
    public var hardBatteryPercent: Int?
    public var idleReleaseSecond: Int?
    public var isChargingOnly: Bool?
    public var thermalCeiling: ThermalLevel?
    public var isNetworkProbeOn: Bool?
    public var isBatteryGuardOn: Bool?
    public var isThermalGuardOn: Bool?
    public var sustainedHeatSecond: Int?
    public var holdSecond: Int?
    // Menu bar icon visibility toggles (I1, I2)
    public var menuBarShowStateIcon: Bool?
    public var menuBarShowActiveBadge: Bool?
    public var menuBarShowBlockedBadge: Bool?
    public var menuBarShowErrorBadge: Bool?
    public var menuBarShowTempWarnIcon: Bool?
    public var menuBarShowAlertIcon: Bool?

    public init(
        softBatteryPercent: Int? = nil,
        hardBatteryPercent: Int? = nil,
        idleReleaseSecond: Int? = nil,
        isChargingOnly: Bool? = nil,
        thermalCeiling: ThermalLevel? = nil,
        isNetworkProbeOn: Bool? = nil,
        isBatteryGuardOn: Bool? = nil,
        isThermalGuardOn: Bool? = nil,
        sustainedHeatSecond: Int? = nil,
        holdSecond: Int? = nil,
        menuBarShowStateIcon: Bool? = nil,
        menuBarShowActiveBadge: Bool? = nil,
        menuBarShowBlockedBadge: Bool? = nil,
        menuBarShowErrorBadge: Bool? = nil,
        menuBarShowTempWarnIcon: Bool? = nil,
        menuBarShowAlertIcon: Bool? = nil
    ) {
        self.softBatteryPercent = softBatteryPercent
        self.hardBatteryPercent = hardBatteryPercent
        self.idleReleaseSecond = idleReleaseSecond
        self.isChargingOnly = isChargingOnly
        self.thermalCeiling = thermalCeiling
        self.isNetworkProbeOn = isNetworkProbeOn
        self.isBatteryGuardOn = isBatteryGuardOn
        self.isThermalGuardOn = isThermalGuardOn
        self.sustainedHeatSecond = sustainedHeatSecond
        self.holdSecond = holdSecond
        self.menuBarShowStateIcon = menuBarShowStateIcon
        self.menuBarShowActiveBadge = menuBarShowActiveBadge
        self.menuBarShowBlockedBadge = menuBarShowBlockedBadge
        self.menuBarShowErrorBadge = menuBarShowErrorBadge
        self.menuBarShowTempWarnIcon = menuBarShowTempWarnIcon
        self.menuBarShowAlertIcon = menuBarShowAlertIcon
    }

    public var isEmpty: Bool {
        softBatteryPercent == nil && hardBatteryPercent == nil && idleReleaseSecond == nil
            && isChargingOnly == nil && thermalCeiling == nil && isNetworkProbeOn == nil
            && isBatteryGuardOn == nil && isThermalGuardOn == nil
            && sustainedHeatSecond == nil && holdSecond == nil
            && menuBarShowStateIcon == nil && menuBarShowActiveBadge == nil
            && menuBarShowBlockedBadge == nil && menuBarShowErrorBadge == nil
            && menuBarShowTempWarnIcon == nil && menuBarShowAlertIcon == nil
    }

    public func applied(to setting: Setting) -> Setting {
        var copy = setting
        if let softBatteryPercent { copy.softBatteryPercent = softBatteryPercent }
        if let hardBatteryPercent { copy.hardBatteryPercent = hardBatteryPercent }
        if let idleReleaseSecond { copy.idleReleaseSecond = idleReleaseSecond }
        if let isChargingOnly { copy.isChargingOnly = isChargingOnly }
        if let thermalCeiling { copy.thermalCeiling = thermalCeiling }
        if let isNetworkProbeOn { copy.isNetworkProbeOn = isNetworkProbeOn }
        if let isBatteryGuardOn { copy.isBatteryGuardOn = isBatteryGuardOn }
        if let isThermalGuardOn { copy.isThermalGuardOn = isThermalGuardOn }
        if let sustainedHeatSecond { copy.sustainedHeatSecond = sustainedHeatSecond }
        if let holdSecond { copy.holdSecond = holdSecond }
        if let menuBarShowStateIcon { copy.menuBarShowStateIcon = menuBarShowStateIcon }
        if let menuBarShowActiveBadge { copy.menuBarShowActiveBadge = menuBarShowActiveBadge }
        if let menuBarShowBlockedBadge { copy.menuBarShowBlockedBadge = menuBarShowBlockedBadge }
        if let menuBarShowErrorBadge { copy.menuBarShowErrorBadge = menuBarShowErrorBadge }
        if let menuBarShowTempWarnIcon { copy.menuBarShowTempWarnIcon = menuBarShowTempWarnIcon }
        if let menuBarShowAlertIcon { copy.menuBarShowAlertIcon = menuBarShowAlertIcon }
        return copy.normalized()
    }
}

public enum AppResponse: Codable, Sendable {
    case ok(String)
    case failed(String)
    case snapshot(RuntimeSnapshot)
    case token(String)
    case text([String])
    case log([LogEntry])
}

// MARK: - App ↔ root helper

/// The privileged surface, kept as small as it can possibly be: two power settings
/// and a heartbeat. The helper does not run arbitrary commands on the app's behalf.
public enum HelperRequest: Codable, Sendable {
    /// Set `pmset -a disablesleep`. The helper starts a deadman timer when turning on.
    case setClamshell(isOn: Bool)
    /// Keep the deadman switch fed. Miss it and the helper reverts on its own.
    case heartbeat
    /// `pmset sleepnow` — the hard battery floor, which must win over every assertion.
    case sleepNow(reason: String)
    case status
}

public struct HelperStatus: Codable, Sendable {
    public var isClamshellOn: Bool
    public var isOwnedByLidCode: Bool
    public var secondSinceHeartbeat: Int?
    public var version: String

    public init(isClamshellOn: Bool, isOwnedByLidCode: Bool, secondSinceHeartbeat: Int?, version: String) {
        self.isClamshellOn = isClamshellOn
        self.isOwnedByLidCode = isOwnedByLidCode
        self.secondSinceHeartbeat = secondSinceHeartbeat
        self.version = version
    }
}

public enum HelperResponse: Codable, Sendable {
    case ok
    case failed(String)
    case status(HelperStatus)
}

// MARK: - Framing

public enum Wire {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// One JSON object per line. Newline framing keeps the protocol debuggable with `nc`.
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try decoder.decode(type, from: line)
    }
}

public enum SocketError: LocalizedError {
    case cannotCreate(String)
    case cannotBind(String)
    case cannotConnect(String)
    case timedOut
    case closed

    public var errorDescription: String? {
        switch self {
        case .cannotCreate(let m): return "cannot create socket: \(m)"
        case .cannotBind(let m):   return "cannot bind socket: \(m)"
        case .cannotConnect(let m):return "cannot connect: \(m)"
        case .timedOut:            return "timed out"
        case .closed:              return "connection closed"
        }
    }
}
