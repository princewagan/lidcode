import Foundation

/// Live CPU die temperature in degrees Celsius, read from the AppleVendor HID
/// temperature sensors that Apple silicon publishes through IOHIDEventSystem.
///
/// Why private API: there is no public macOS interface that reports a number. The only
/// supported signal is `ProcessInfo.thermalState`, which on Apple silicon sits at
/// `.nominal` almost permanently — accurate about *thermal pressure*, useless as a
/// temperature. The SMC route that used to work on Intel does not exist on M-series.
/// The remaining path is `IOHIDEventSystemClient`, which is what every temperature
/// menu-bar app on the platform uses.
///
/// Because it is private, nothing here is allowed to be load-bearing. Every symbol is
/// resolved by `dlsym` behind an optional, resolution happens exactly once, and any
/// failure at any step latches this object into a permanent "unavailable" state that
/// returns nil forever. It never throws, never traps, and never retries in a loop — a
/// future macOS that removes these symbols degrades LidCode to the OS thermal level it
/// used before, rather than crashing the menu bar app.
///
/// ## Cost
///
/// Measured on this machine (24 matching `tdie` sensors across two PMU dies):
///
/// - first `readCelsius()`: **~17.7 ms**, including dlopen, six dlsyms, client
///   creation and the service-list copy
/// - each uncached `readCelsius()` after that: **~17.7 ms** — the setup is not the
///   expensive part. Every sensor costs a separate `IOHIDServiceClientCopyEvent`,
///   which is a round trip to the HID event system, at ~0.7 ms each. There is no
///   batch read; this is what the cost of a real temperature is on this platform.
/// - a cached `readCelsius()`: **~0.4 µs**
///
/// 17.7 ms once per 5 s tick is ~0.35% of one core, which is the budget this was
/// written against. The service list is therefore cached (re-copying it per read would
/// roughly double that for nothing), and `cacheWindow` bounds the damage when a caller
/// is burstier than the tick — `LidCodeRuntime.publish()` fires on every state change,
/// and reading 24 HID sensors per lease claim would not be acceptable. The window is
/// shorter than the tick, so the value a tick sees is always freshly sampled.
public final class TemperatureSensor: @unchecked Sendable {

    // MARK: - Private IOKit surface

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias ClientSetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias ClientCopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias ServiceCopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventGetFloatValue = @convention(c) (AnyObject, Int32) -> Double

    /// `kIOHIDEventTypeTemperature`.
    private static let temperatureEventType: Int64 = 15
    /// `IOHIDEventFieldBase(kIOHIDEventTypeTemperature)` — the field selector whose
    /// float value is the reading in degrees Celsius.
    private static let temperatureField = Int32(15 << 16)
    /// AppleVendor-defined temperature sensor page/usage. Everything else on the HID
    /// event system (keyboards, trackpads, ambient light) is filtered out by this.
    private static let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]

    /// A real die reading on a Mac is never <= 0 °C and never > 130 °C. Anything else is
    /// a sensor that is offline, unpopulated, or reporting a sentinel — and a bogus 0
    /// matters more than it looks, because it would silently sit in a `max()` doing
    /// nothing instead of announcing itself.
    private static func isPlausible(_ celsius: Double) -> Bool {
        celsius > 0 && celsius <= 130
    }

    // MARK: - Resolved handles

    /// The C function pointers plus the live client, kept together so "resolved" is a
    /// single optional rather than six that could disagree.
    private struct Bridge {
        let client: AnyObject
        let copyProperty: ServiceCopyProperty
        let copyEvent: ServiceCopyEvent
        let floatValue: EventGetFloatValue
        let copyServices: ClientCopyServices
    }

    /// A matched sensor, pre-classified so `readCelsius` does no string work per read.
    private struct Sensor {
        /// Retains the underlying `IOHIDServiceClient`.
        let service: AnyObject
        let name: String
        let isDie: Bool
        let isCalibration: Bool
    }

    private let lock = NSLock()
    private var bridge: Bridge?
    private var sensors: [Sensor] = []
    /// Latches true the moment anything is missing. Never cleared except by `rescan()`,
    /// so a machine without these symbols pays the dlopen cost once and nothing after.
    private var isUnavailable = false
    private var hasPrepared = false

    private var cached: (celsius: Double?, at: Date)?
    /// Shorter than the 5 s runtime tick, so every tick samples the hardware afresh;
    /// long enough that one tick's several `readThermal()` calls — and any burst of
    /// state-change publishes between ticks — collapse into a single 17.7 ms sweep.
    private let cacheWindow: TimeInterval

    /// Shared instance. The service list is per-process state worth having exactly one
    /// of, and a second instance would also keep a second read cache — two callers a
    /// few hundred milliseconds apart would then pay two full sweeps instead of one.
    public static let shared = TemperatureSensor()

    public init(cacheWindow: TimeInterval = 2.0) {
        self.cacheWindow = cacheWindow
    }

    // MARK: - Reading

    /// CPU die temperature in degrees Celsius, or nil when no usable sensor exists.
    ///
    /// The *maximum* of the die sensors, not the mean: a package with one core at 95 °C
    /// and fourteen at 45 °C is a hot machine, and averaging is exactly the arithmetic
    /// that would hide it. Falls back to the calibration/device sensors only when no
    /// `tdie` exists at all, since those track the same package more loosely.
    public func readCelsius() -> Double? {
        lock.lock()
        defer { lock.unlock() }

        if let cached, Date().timeIntervalSince(cached.at) < cacheWindow {
            return cached.celsius
        }
        let value = sampleLocked()
        cached = (value, Date())
        return value
    }

    /// Re-resolve the sensor list. Not needed in normal operation — the set of thermal
    /// sensors on a Mac is fixed by its hardware — but a sleep/wake cycle can in
    /// principle invalidate service clients, and this is the escape hatch that does not
    /// require tearing down the object.
    public func rescan() {
        lock.lock()
        defer { lock.unlock() }
        bridge = nil
        sensors = []
        cached = nil
        hasPrepared = false
        isUnavailable = false
    }

    // MARK: - Internals

    private func sampleLocked() -> Double? {
        prepareLocked()
        guard let bridge, !isUnavailable else { return nil }

        if let die = maxLocked(bridge: bridge, where: { $0.isDie }) { return die }
        return maxLocked(bridge: bridge, where: { $0.isCalibration })
    }

    private func maxLocked(bridge: Bridge, where include: (Sensor) -> Bool) -> Double? {
        var best: Double?
        for sensor in sensors where include(sensor) {
            guard let event = bridge.copyEvent(
                sensor.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = bridge.floatValue(event, Self.temperatureField)
            guard Self.isPlausible(value) else { continue }
            best = max(best ?? value, value)
        }
        return best
    }

    /// Resolves symbols and the service list at most once per `rescan()`.
    private func prepareLocked() {
        guard !hasPrepared else { return }
        hasPrepared = true

        guard let bridge = Self.makeBridge() else {
            isUnavailable = true
            return
        }
        self.bridge = bridge
        sensors = Self.makeSensor(bridge: bridge)
        // A machine that matches zero sensors is as unavailable as one missing the
        // symbols; latch it so we stop paying for the walk.
        if sensors.isEmpty { isUnavailable = true }
    }

    private static func makeBridge() -> Bridge? {
        // RTLD_NOLOAD would be tidier, but IOKit is always already loaded in this
        // process and dlopen just bumps its refcount. The handle is intentionally
        // never dlclose'd: the function pointers outlive this call.
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_NOLOAD)
            ?? dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        else { return nil }

        func symbol<T>(_ name: String) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }

        guard let create: ClientCreate = symbol("IOHIDEventSystemClientCreate"),
              let setMatching: ClientSetMatching = symbol("IOHIDEventSystemClientSetMatching"),
              let copyServices: ClientCopyServices = symbol("IOHIDEventSystemClientCopyServices"),
              let copyProperty: ServiceCopyProperty = symbol("IOHIDServiceClientCopyProperty"),
              let copyEvent: ServiceCopyEvent = symbol("IOHIDServiceClientCopyEvent"),
              let floatValue: EventGetFloatValue = symbol("IOHIDEventGetFloatValue"),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        setMatching(client, matching as CFDictionary)
        return Bridge(
            client: client,
            copyProperty: copyProperty,
            copyEvent: copyEvent,
            floatValue: floatValue,
            copyServices: copyServices)
    }

    private static func makeSensor(bridge: Bridge) -> [Sensor] {
        guard let raw = bridge.copyServices(bridge.client)?.takeRetainedValue() as? [AnyObject]
        else { return [] }

        return raw.compactMap { service in
            guard let name = bridge.copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String
            else { return nil }
            let lowered = name.lowercased()
            let isDie = lowered.contains("tdie")
            let isCalibration = lowered.contains("tcal") || lowered.contains("tdev")
            // Battery and NAND sensors match the same usage page but say nothing about
            // the CPU, so they are dropped here rather than filtered on every read.
            guard isDie || isCalibration else { return nil }
            return Sensor(service: service, name: name, isDie: isDie, isCalibration: isCalibration)
        }
    }
}
