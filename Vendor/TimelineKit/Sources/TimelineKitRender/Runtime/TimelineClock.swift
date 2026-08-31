import Foundation
#if canImport(UIKit)
import QuartzCore
#endif

// MARK: - TimelineClock

/// Drives the Timeline Runtime rendering loop.
///
/// - iOS: `CADisplayLink` — fires `onTick` on every screen refresh.
/// - macOS: `Timer` on the main run loop (~60 Hz) — CADisplayLink is iOS-only;
///   a timer on `.common` mode keeps firing during window tracking.
///
/// Fires `onTick` while started. The coordinator reads `player.currentTime()`
/// inside `onTick` to obtain the current composition time — no separate time
/// tracking needed here.
///
/// Lifecycle:
///   - `start()` — schedule the driver on the main run loop.
///   - `stop()`  — invalidate and remove the driver.
///   - deinit    — automatically invalidates the driver.
@MainActor
public final class TimelineClock {

    // MARK: - Public

    /// Called on each driver fire (main actor, ~60 fps).
    public var onTick: (() -> Void)?

    // MARK: - Private

#if canImport(UIKit)
    // nonisolated(unsafe): deinit is nonisolated; CADisplayLink.invalidate() is thread-safe.
    nonisolated(unsafe) private var displayLink: CADisplayLink?
#else
    // nonisolated(unsafe): deinit is nonisolated; Timer.invalidate() is thread-safe.
    nonisolated(unsafe) private var timer: Timer?
#endif

    // MARK: - Lifecycle

    public init() {}

    deinit {
#if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
#else
        timer?.invalidate()
        timer = nil
#endif
    }

    // MARK: - Public API

    /// Start firing `onTick` at screen refresh rate. Idempotent.
    public func start() {
#if canImport(UIKit)
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(target: self)
        let link  = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
#else
        guard timer == nil else { return }
        let proxy = ClockProxy(target: self)
        let t = Timer(timeInterval: 1.0 / 60.0,
                      target: proxy,
                      selector: #selector(ClockProxy.tick),
                      userInfo: nil,
                      repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
#endif
    }

    /// Stop the driver (e.g. when switching to AVPlayer path or view disappears).
    public func stop() {
#if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
#else
        timer?.invalidate()
        timer = nil
#endif
    }

    // MARK: - Internal (called by proxy on main thread)

    fileprivate func handleTick() {
        onTick?()
    }
}

// MARK: - ClockProxy

#if canImport(UIKit)
/// `@MainActor` weak-proxy that breaks the `CADisplayLink → target` retain cycle.
/// Both `TimelineClock` and this proxy are `@MainActor`, so passing `self` between
/// them is safe under Swift 6 strict concurrency. `CADisplayLink` fires on the main
/// run loop, which is the main actor's executor, so `@objc func tick()` always runs
/// in the correct actor context.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var target: TimelineClock?

    init(target: TimelineClock) {
        self.target = target
    }

    @objc func tick() {
        target?.handleTick()
    }
}
#else
/// `@MainActor` weak-proxy that breaks the `Timer → target` retain cycle.
/// The timer is scheduled on the main run loop, which is the main actor's
/// executor, so `@objc func tick()` always runs in the correct actor context.
@MainActor
private final class ClockProxy: NSObject {
    weak var target: TimelineClock?

    init(target: TimelineClock) {
        self.target = target
    }

    @objc func tick() {
        target?.handleTick()
    }
}
#endif
