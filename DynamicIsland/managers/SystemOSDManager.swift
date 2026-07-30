/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import AppKit
import os

class SystemOSDManager {
    private init() {}

    // Tracks the PIDs we currently hold SIGSTOPped. macOS jetsam-exits
    // OSDUIHelper when idle and launchd respawns it on the next media-key press
    // as a fresh process, so we need to re-SIGSTOP every new incarnation.
    private struct SuppressionState {
        // Short, self-terminating poll that closes the gap until a helper exists
        // to be stopped. Nil whenever no window is open (the steady state).
        var windowTask: Task<Void, Never>?
        // One kqueue death watch per suspended PID. A SIGSTOPped process cannot
        // draw, so while a watch is live there is nothing to poll for: the only
        // way the native OSD can come back is that PID exiting.
        var deathWatchers: [pid_t: DispatchSourceProcess] = [:]
        var lastSuspendedPIDs: Set<pid_t> = []
        // True while suppressing the native OSD (between disable/enableSystemHUD).
        var active = false
        // True while the Mac is asleep — window pauses, not cancelled.
        var systemSleeping = false
        // Invalidates asynchronous enable/disable work left over from an older
        // settings state. HUD style switches update several Defaults in quick
        // succession, so those transitions must not race each other.
        var transitionGeneration: UInt64 = 0
        // Coalesces immediate suppression requests from a key event and its
        // resulting system-value notification.
        var immediateSuppressionInFlight = false
        // Sequential coalesce. `immediateSuppressionInFlight` only merges
        // *concurrent* requests, but a keypress and its resulting notifications
        // arrive one after another on the main thread, so they never overlapped.
        var lastImmediateSuppression: ContinuousClock.Instant?
    }
    private static let suppressionState = OSAllocatedUnfairLock(initialState: SuppressionState())

    /// Serial queue for kqueue death-watch callbacks.
    private static let watchQueue = DispatchQueue(label: "com.atoll.osd-suppression-watch")

    /// The kernel truncates process names to MAXCOMLEN; "OSDUIHelper" is 11
    /// characters, comfortably short of the 16-byte limit, so an exact compare
    /// against `p_comm` is unambiguous.
    private static let osduiHelperProcessName = "OSDUIHelper"

    /// How long to keep polling after an event that can produce a fresh helper.
    private static let suppressionWindow: Duration = .milliseconds(1500)
    private static let suppressionPollIntervalNanos: UInt64 = 150_000_000

    /// Ignore repeat immediate-suppression requests inside this window while we
    /// already hold a stopped helper.
    private static let immediateSuppressionCoalesceWindow: Duration = .milliseconds(120)

    /// Call once at startup to register sleep/wake observers.
    /// Safe to call multiple times — observers are registered only once.
    private static let sleepWakeSetupOnce: Void = {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleSystemSleep()
        }
        nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleSystemWake()
        }
        // Screen sleep can idle-exit OSDUIHelper without the system ever sleeping,
        // so recover on screen wake too — otherwise suppression could stay unarmed
        // until the next HUD-style transition.
        nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleSystemWake()
        }
    }()

    // MARK: - Sleep / Wake

    private static func handleSystemSleep() {
        // Mark as sleeping so an open window exits its current poll immediately.
        suppressionState.withLock { $0.systemSleeping = true }
        stopSuppressionWindow()
        // Death watchers are kqueue-based and cost nothing while asleep, so they
        // stay armed; their handler no-ops until we wake.
    }

    private static func handleSystemWake() {
        let generation = suppressionState.withLock { state -> UInt64? in
            state.systemSleeping = false
            guard state.active else { return nil }
            // Forget which PIDs we held so the window re-SIGSTOPs whatever
            // launchd spawned across the sleep (re-stopping is idempotent).
            state.lastSuspendedPIDs.removeAll()
            return state.transitionGeneration
        }
        if let generation {
            armSuppressionWindow(generation: generation)
        }
    }

    // MARK: - Public API

    /// Re-enables the system HUD by restarting OSDUIHelper
    public static func enableSystemHUD() {
        let generation = suppressionState.withLock { state -> UInt64 in
            state.active = false
            state.transitionGeneration &+= 1
            return state.transitionGeneration
        }
        teardownSuppression()
        Task.detached(priority: .background) {
            await enableSystemHUDAsync(generation: generation)
        }
    }
    
    private static func enableSystemHUDAsync(generation: UInt64) async {
        guard isCurrentTransition(generation, active: false) else { return }

        do {
            // First, stop any existing OSDUIHelper process
            let stopTask = Process()
            stopTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            stopTask.arguments = ["-9", "OSDUIHelper"]
            stopTask.standardError = Pipe() // silence "no such process" stderr
            try stopTask.run()
            stopTask.waitUntilExit()

            guard isCurrentTransition(generation, active: false) else { return }
            
            // Small delay to ensure process is fully stopped
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            guard isCurrentTransition(generation, active: false) else { return }
            
            // Then kickstart it again to ensure it's running properly
            let kickstart = Process()
            kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            kickstart.arguments = ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"]
            try kickstart.run()
            kickstart.waitUntilExit()

            // A replacement HUD may have been selected while launchctl was
            // running. In that case the current suppression transition owns the
            // helper; stop this stale restoration immediately.
            guard isCurrentTransition(generation, active: false) else {
                suppressNativeOSDNow()
                return
            }
            
            // Additional delay to ensure service is fully started
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard isCurrentTransition(generation, active: false) else { return }
            
            await MainActor.run {
                print("✅ System HUD re-enabled")
            }
        } catch {
            guard isCurrentTransition(generation, active: false) else { return }
            await MainActor.run {
                NSLog("❌ Error while trying to re-enable OSDUIHelper: \(error)")
            }
            
            // Fallback: Try to restart the service using launchctl load
            do {
                let fallbackTask = Process()
                fallbackTask.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                fallbackTask.arguments = ["load", "-w", "/System/Library/LaunchAgents/com.apple.OSDUIHelper.plist"]
                try fallbackTask.run()
                fallbackTask.waitUntilExit()

                guard isCurrentTransition(generation, active: false) else {
                    suppressNativeOSDNow()
                    return
                }
                
                await MainActor.run {
                    print("✅ System HUD re-enabled via fallback method")
                }
            } catch {
                await MainActor.run {
                    NSLog("❌ Fallback method also failed: \(error)")
                }
            }
        }
    }

    /// Synchronously resumes OSDUIHelper for app termination.
    ///
    /// `enableSystemHUD()` restarts the helper on a detached background `Task`,
    /// which never runs to completion when the process is already terminating —
    /// so a SIGSTOP-frozen OSDUIHelper stays frozen after Atoll quits, breaking
    /// every native OSD Atoll does not replace (keyboard backlight,
    /// external-display brightness, …) and leaving a stuck HUD on screen. This
    /// sends SIGCONT inline and blocks until it lands, guaranteeing the helper
    /// is resumed before Atoll exits. Idempotent; safe to call from a
    /// termination handler.
    public static func resumeOSDUIHelperForTermination() {
        suppressionState.withLock { state in
            state.active = false
            state.transitionGeneration &+= 1
        }

        // Cancel the suppression window and wait for it to fully exit before
        // resuming. A bare cancel is cooperative, so an in-flight SIGSTOP could
        // otherwise land after our SIGCONT and re-freeze the helper.
        // Bridge the async drain to this synchronous path with a bounded wait.
        if let window = stopSuppressionWindow() {
            let drained = DispatchSemaphore(value: 0)
            Task { await window.value; drained.signal() }
            _ = drained.wait(timeout: .now() + 1.0)
        }
        cancelDeathWatchers()

        // SIGCONT every helper we know about: what a fresh scan finds, plus any
        // PID we recorded as suspended (the scan can miss one that is mid-exit).
        // `kill(2)` cannot fail the way spawning a Process can once this process
        // is already tearing down, which is exactly when this runs.
        let recorded = suppressionState.withLock { state -> Set<pid_t> in
            let pids = state.lastSuspendedPIDs
            state.lastSuspendedPIDs.removeAll()
            return pids
        }
        resumeOSDUIHelper(pids: Array(Set(osduiHelperPIDs()).union(recorded)))
    }

    /// Disables the system HUD by stopping OSDUIHelper, and arms a short poll
    /// plus a kqueue death watch so any future incarnation launchd spawns is
    /// re-suspended (macOS auto-exits OSDUIHelper on idle).
    public static func disableSystemHUD() {
        // Ensure sleep/wake observers are registered.
        _ = sleepWakeSetupOnce
        let generation = suppressionState.withLock { state -> UInt64 in
            state.active = true
            state.transitionGeneration &+= 1
            return state.transitionGeneration
        }
        Task.detached(priority: .background) {
            await disableSystemHUDAsync(generation: generation)
        }
        armSuppressionWindow(generation: generation)
    }

    /// Immediately SIGSTOPs OSDUIHelper, ahead of the suppression window's poll. The
    /// CoreAudio volume write wakes/respawns the helper to draw the native OSD
    /// (brightness's private APIs never do), and the watcher can lose that race.
    /// No-op unless suppression is active.
    public static func suppressNativeOSDNow() {
        let now = ContinuousClock.now
        let generation = suppressionState.withLock { state -> UInt64? in
            guard state.active, !state.immediateSuppressionInFlight else { return nil }
            // Already holding a stopped helper and asked again moments ago: the
            // native OSD is structurally suppressed, so this request is redundant.
            if let last = state.lastImmediateSuppression,
               !state.lastSuspendedPIDs.isEmpty,
               now - last < immediateSuppressionCoalesceWindow {
                return nil
            }
            state.immediateSuppressionInFlight = true
            state.lastImmediateSuppression = now
            return state.transitionGeneration
        }
        guard let generation else { return }

        Task.detached(priority: .userInitiated) {
            defer {
                suppressionState.withLock { $0.immediateSuppressionInFlight = false }
            }
            suppressAndWatch(generation: generation)
        }

        // Also arm the window. The immediate scan above usually finds nothing:
        // macOS jetsam-exits OSDUIHelper when idle and launchd only respawns it in
        // response to the CoreAudio write that happens *after* this call — so
        // without a window there would be no armed death watch and no poll, and the
        // fresh helper would draw the native OSD unopposed.
        //
        // Armed here rather than inside suppressAndWatch: the window task calls that
        // on every tick and would renew itself forever.
        armSuppressionWindow(generation: generation)
    }

    /// Scans for OSDUIHelper, SIGSTOPs every instance we are not already holding
    /// stopped, and arms a death watch on each.
    ///
    /// One `sysctl` + N `kill(2)` calls. The previous implementation forked
    /// `pgrep` → `killall -STOP` → `pgrep` (three child processes) per call.
    private static func suppressAndWatch(generation: UInt64) {
        guard isCurrentTransition(generation, active: true) else { return }

        let live = Set(osduiHelperPIDs())
        guard !live.isEmpty else {
            pruneDeathWatchers(keeping: [])
            // Must clear too: the coalesce gate in suppressNativeOSDNow() treats a
            // non-empty set as "we hold a stopped helper", so a stale set would make
            // it drop every request inside the coalesce window — and key repeat is
            // faster than that window.
            suppressionState.withLock { $0.lastSuspendedPIDs.removeAll() }
            return
        }

        let known = suppressionState.withLock { $0.lastSuspendedPIDs }
        let fresh = Array(live.subtracting(known))
        if !fresh.isEmpty {
            guard isCurrentTransition(generation, active: true) else { return }
            suspendOSDUIHelper(pids: fresh)

            // If the user disabled Atoll's HUD replacement while SIGSTOP was in
            // flight, undo that stale suppression immediately. The current
            // restoration transition will still perform its clean restart.
            guard isCurrentTransition(generation, active: true) else {
                resumeOSDUIHelper(pids: fresh)
                return
            }
        }

        suppressionState.withLock { $0.lastSuspendedPIDs = live }
        pruneDeathWatchers(keeping: live)
        installDeathWatchers(for: live)
    }
    
    private static func disableSystemHUDAsync(generation: UInt64) async {
        guard isCurrentTransition(generation, active: true) else { return }

        do {
            let kickstart = Process()
            kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            // Force a clean helper instance. A plain kickstart is a no-op when
            // OSDUIHelper is already running, and macOS may replace that lingering
            // process on the first media key, briefly exposing the native HUD.
            kickstart.arguments = ["kickstart", "-k", "gui/\(getuid())/com.apple.OSDUIHelper"]
            try kickstart.run()
            kickstart.waitUntilExit()

            guard isCurrentTransition(generation, active: true) else { return }

            // launchctl kickstart returns once the request is queued, not after
            // OSDUIHelper has actually forked. At cold boot the helper can take
            // a while to appear — a fixed sleep races and the SIGSTOP misses,
            // letting the native OSD render on the first volume/brightness key.
            // Poll for the PID up to ~5s, then suspend, and retry if launchd
            // respawned a fresh copy between kickstart and SIGSTOP.
            var attempts = 0
            while attempts < 3 {
                guard isCurrentTransition(generation, active: true) else { return }
                let appeared = await waitForOSDUIHelper(timeoutMillis: 5000)
                guard isCurrentTransition(generation, active: true) else { return }
                if !appeared {
                    await MainActor.run {
                        NSLog("⚠️ OSDUIHelper did not appear within timeout; retrying SIGSTOP anyway")
                    }
                }

                suspendOSDUIHelper(pids: osduiHelperPIDs())

                // Settle, then confirm a process is actually present (and thus
                // suspended). If none is running, launchd hasn't spawned it yet
                // or the prior STOP raced — loop and try again.
                try await Task.sleep(nanoseconds: 250_000_000) // 250ms
                guard isCurrentTransition(generation, active: true) else { return }
                let live = Set(osduiHelperPIDs())
                if !live.isEmpty {
                    suppressionState.withLock { $0.lastSuspendedPIDs = live }
                    installDeathWatchers(for: live)
                    break
                }
                attempts += 1
            }

            if isCurrentTransition(generation, active: true) {
                await MainActor.run {
                    print("✅ System HUD disabled")
                }
            }
        } catch {
            guard isCurrentTransition(generation, active: true) else { return }
            await MainActor.run {
                NSLog("❌ Error while trying to hide OSDUIHelper: \(error)")
            }
        }
    }

    /// Polls for an OSDUIHelper process, returning true as soon as one appears
    /// or false if `timeoutMillis` elapses with no match.
    private static func waitForOSDUIHelper(timeoutMillis: Int) async -> Bool {
        let pollIntervalNanos: UInt64 = 200_000_000 // 200ms
        let maxAttempts = max(1, timeoutMillis / 200)
        for _ in 0..<maxAttempts {
            if isOSDUIHelperRunning() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        return isOSDUIHelperRunning()
    }

    private static func isCurrentTransition(_ generation: UInt64, active: Bool) -> Bool {
        suppressionState.withLock {
            $0.transitionGeneration == generation && $0.active == active
        }
    }

    // MARK: - Death watch

    /// Arms a kqueue `NOTE_EXIT` watch on every suspended helper.
    ///
    /// This is what replaces the old permanent 150ms poll. A SIGSTOPped process
    /// cannot draw, so while we hold one the native OSD is structurally
    /// impossible; the only way it can come back is that PID exiting (jetsam
    /// idle-exit, or `launchctl kickstart -k`). That is an event we can subscribe
    /// to, so the steady state costs zero syscalls instead of ~6.7 forks/second.
    private static func installDeathWatchers(for pids: Set<pid_t>) {
        let started = suppressionState.withLock { state -> [DispatchSourceProcess] in
            var created: [DispatchSourceProcess] = []
            for pid in pids where state.deathWatchers[pid] == nil {
                let source = DispatchSource.makeProcessSource(
                    identifier: pid,
                    eventMask: .exit,
                    queue: watchQueue
                )
                source.setEventHandler { handleHelperExit(pid: pid) }
                state.deathWatchers[pid] = source
                created.append(source)
            }
            return created
        }
        // resume() outside the lock: for a PID that died between the scan and the
        // registration the handler fires immediately, and it takes the same lock.
        started.forEach { $0.resume() }
    }

    private static func handleHelperExit(pid: pid_t) {
        let generation = suppressionState.withLock { state -> UInt64? in
            state.deathWatchers[pid]?.cancel()
            state.deathWatchers[pid] = nil
            state.lastSuspendedPIDs.remove(pid)
            guard state.active, !state.systemSleeping else { return nil }
            return state.transitionGeneration
        }
        guard let generation else { return }
        // launchd spawns a replacement on the next media key; poll briefly so the
        // fresh instance is SIGSTOPped before it gets a chance to draw.
        armSuppressionWindow(generation: generation)
    }

    private static func pruneDeathWatchers(keeping pids: Set<pid_t>) {
        let stale = suppressionState.withLock { state -> [DispatchSourceProcess] in
            var removed: [DispatchSourceProcess] = []
            for (pid, source) in state.deathWatchers where !pids.contains(pid) {
                removed.append(source)
                state.deathWatchers[pid] = nil
            }
            return removed
        }
        stale.forEach { $0.cancel() }
    }

    private static func cancelDeathWatchers() {
        let all = suppressionState.withLock { state -> [DispatchSourceProcess] in
            let sources = Array(state.deathWatchers.values)
            state.deathWatchers.removeAll()
            return sources
        }
        all.forEach { $0.cancel() }
    }

    // MARK: - Suppression window

    /// Short, self-terminating poll that covers the gap where no helper exists
    /// yet to be SIGSTOPped — i.e. right after a HUD-style transition, a wake, or
    /// the death of a helper we were holding. Once a helper is stopped, the death
    /// watch takes over and this stops running.
    ///
    /// Mirrors `SystemBrightnessController.markUserInitiated()`'s windowed poll:
    /// bounded lifetime, ~10 `sysctl` calls over 1.5s, versus the old loop's
    /// ~24,000 forks per hour, forever.
    ///
    /// Deliberately *not* gated on `ActivityGate`, unlike the brightness poll. This
    /// is user-visible latency, not background work, and it is already time-boxed —
    /// while gating it caused two concrete failures: the screen-sleep branch of the
    /// gate would kill the window with nothing to re-arm it (we observe system
    /// wake, not screen wake), and the `await MainActor.run` hop could not complete
    /// while `resumeOSDUIHelperForTermination()` blocks the main thread waiting for
    /// this very task to drain, stalling every quit by a full second.
    /// System sleep is still handled, by `systemSleeping` + `handleSystemWake()`.
    private static func armSuppressionWindow(generation: UInt64) {
        let newTask = Task.detached(priority: .userInitiated) {
            let deadline = ContinuousClock.now + suppressionWindow
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard isCurrentTransition(generation, active: true) else { return }
                // handleSystemWake() arms a fresh window, so returning is safe.
                if suppressionState.withLock({ $0.systemSleeping }) { return }

                // Scan every tick rather than stopping at the first success:
                // `launchctl kickstart -k` can spawn a replacement while we hold
                // the first instance stopped, and the whole window is ~10 cheap
                // syscalls, so there is nothing to save by bailing early.
                suppressAndWatch(generation: generation)

                try? await Task.sleep(nanoseconds: suppressionPollIntervalNanos)
            }
        }

        let previous = suppressionState.withLock { state -> Task<Void, Never>? in
            let prior = state.windowTask
            state.windowTask = newTask
            return prior
        }
        previous?.cancel()
    }

    /// Cancels the suppression window. Returns the cancelled task so callers that
    /// must not race it (e.g. termination) can wait for it to fully exit.
    @discardableResult
    private static func stopSuppressionWindow() -> Task<Void, Never>? {
        let previous = suppressionState.withLock { state -> Task<Void, Never>? in
            let prior = state.windowTask
            state.windowTask = nil
            return prior
        }
        previous?.cancel()
        return previous
    }

    /// Fully stops suppression bookkeeping (window + death watches + PID set).
    private static func teardownSuppression() {
        stopSuppressionWindow()
        cancelDeathWatchers()
        suppressionState.withLock { $0.lastSuspendedPIDs.removeAll() }
    }

    /// Returns every live OSDUIHelper PID owned by the current user.
    ///
    /// One `sysctl(KERN_PROC_UID)` call: the kernel copies out a `kinfo_proc` per
    /// process, including `p_comm`, so the whole table costs a single syscall.
    /// This replaces forking `/usr/bin/pgrep`, which the suppression watcher used
    /// to do every 150ms for the lifetime of the app. (`libproc`'s
    /// `proc_listallpids` + `proc_name` would need one syscall *per* PID.)
    private static func osduiHelperPIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        let stride = MemoryLayout<kinfo_proc>.stride

        // The process table can grow between the sizing call and the data call,
        // which makes the second one fail with ENOMEM. Ask for some slack and
        // retry a bounded number of times rather than giving up.
        for _ in 0..<3 {
            var needed = 0
            guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else {
                return []
            }

            let capacity = needed / stride + 16
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var size = capacity * stride
            let status = procs.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
            }

            if status == 0 {
                return procs.prefix(size / stride).compactMap { proc in
                    let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    return name == osduiHelperProcessName ? proc.kp_proc.p_pid : nil
                }
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// Sends SIGSTOP to the given OSDUIHelper PIDs. Idempotent.
    private static func suspendOSDUIHelper(pids: [pid_t]) {
        signal(pids, SIGSTOP, action: "SIGSTOP")
    }

    private static func resumeOSDUIHelper(pids: [pid_t]) {
        signal(pids, SIGCONT, action: "SIGCONT")
    }

    private static func signal(_ pids: [pid_t], _ sig: Int32, action: String) {
        for pid in pids {
            guard kill(pid, sig) != 0 else { continue }
            // ESRCH just means the helper exited between the scan and the signal,
            // which is the normal jetsam-idle-exit race — not worth logging.
            if errno != ESRCH {
                NSLog("Failed to \(action) OSDUIHelper \(pid): \(String(cString: strerror(errno)))")
            }
        }
    }

    /// Check if OSDUIHelper is currently running
    public static func isOSDUIHelperRunning() -> Bool {
        !osduiHelperPIDs().isEmpty
    }
    
    /// Async version of status checking to avoid main thread blocking
    public static func isOSDUIHelperRunningAsync() async -> Bool {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                let result = isOSDUIHelperRunning()
                continuation.resume(returning: result)
            }
        }
    }
}
