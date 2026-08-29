import CoreGraphics
import Foundation

/// Controls the built-in display brightness via the DisplayServices private framework.
///
/// Using dlopen/dlsym rather than a direct link keeps the framework out of the build
/// graph. A future macOS that removes or renames the symbols degrades to no-ops
/// instead of a link failure or a crash. Every call that can fail returns nil/false —
/// brightness is a quality-of-life feature, never a safety path.
///
/// The `@convention(c)` on both typealiases is load-bearing, not decoration. `dlsym`
/// returns one word; a plain Swift closure type is *two* (function pointer plus a
/// context pointer), so `unsafeBitCast`-ing a symbol into `(CGDirectDisplayID, Float)
/// -> Int32` traps on the size precondition the first time the lid shuts. Only the C
/// calling convention is one word wide and safe to cast a symbol into.
///
/// Thread safety: the lazy dlopen and symbol resolution are protected by `lock`.
/// After the first resolve the function pointers are read-only.
public final class DisplayBrightness: @unchecked Sendable {

    public static let shared = DisplayBrightness()

    /// The floor DisplayServices accepts. On a built-in panel this is the dimmest
    /// backlight the brightness keys can reach, not a powered-off display.
    public static let minimumLevel: Float = 0.0

    // MARK: - C function signatures

    private typealias GetBrightness =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness =
        @convention(c) (CGDirectDisplayID, Float) -> Int32

    // MARK: - Private state

    private let lock = NSLock()
    private var isResolved = false
    private var getBrightness: GetBrightness?
    private var setBrightness: SetBrightness?

    public init() {}

    // MARK: - Public API

    /// The built-in panel's display ID, or nil on a desktop Mac — and also nil once the
    /// lid is shut with no external display attached, because macOS drops the panel from
    /// the active list. A nil here makes every call below a no-op, which is why a failed
    /// dim leaves `savedBrightness` untouched rather than recording a level it never set.
    public func builtInDisplayId() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var display = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &display, &count) == .success else { return nil }
        return display.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// The built-in display's current brightness, 0.0–1.0, or nil when unavailable.
    public func read() -> Float? {
        guard let get = resolved().get, let id = builtInDisplayId() else { return nil }
        var value: Float = 0
        guard get(id, &value) == 0 else { return nil }
        return value
    }

    /// Sets the built-in display's brightness, clamped to 0.0–1.0.
    @discardableResult
    public func set(_ value: Float) -> Bool {
        guard let set = resolved().set, let id = builtInDisplayId() else { return false }
        return set(id, min(1.0, max(0.0, value))) == 0
    }

    // MARK: - Lazy symbol resolution

    private func resolved() -> (get: GetBrightness?, set: SetBrightness?) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return (getBrightness, setBrightness) }
        // Flipped before the dlopen so a framework that cannot be opened is attempted
        // once and stays a no-op, rather than paying for a failing dlopen every tick.
        isResolved = true

        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW
        ) else { return (nil, nil) }

        if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        }
        if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightness = unsafeBitCast(symbol, to: SetBrightness.self)
        }
        return (getBrightness, setBrightness)
    }
}
