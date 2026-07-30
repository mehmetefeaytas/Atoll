/*
 * Atoll (DynamicIsland)
 * Original work Copyright (C) 2026 ZephyrCodesStuff (https://github.com/ZephyrCodesStuff/rtaudio)
 * Modified work Copyright (C) 2026 Atoll Contributors
 *
 * CoreAudio tap for capturing real-time audio from music applications.
 * Uses macOS 14.2+ Process Tap API for efficient audio capture.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import AudioToolbox
import CoreAudio
import simd
import os
import os.log

private let audioTapLog = OSLog(subsystem: "com.atoll.dynamicisland", category: "AudioTap")

// Debug: track callback invocations
private var callbackCount: Int = 0

// CoreAudio fires this on a high-priority background real-time thread.
let audioIOProc: AudioDeviceIOProc = {
    inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, clientData in

    guard let clientData = clientData else { return noErr }
    let scanner = Unmanaged<AudioTap>.fromOpaque(clientData).takeUnretainedValue()

    if scanner.isPaused { return noErr }

    let mutableInputData = UnsafeMutablePointer(mutating: inInputData)
    let bufferList = UnsafeMutableAudioBufferListPointer(mutableInputData)

    if let firstBuffer = bufferList.first, let data = firstBuffer.mData {
        // CoreAudio gives us byte size, divide by 4 (Float size) to get array length
        let floatCount = Int32(firstBuffer.mDataByteSize) / Int32(MemoryLayout<Float>.size)

        let floatData = data.assumingMemoryBound(to: Float.self)

        // Pass the mono array directly to C++
        scanner.bridge.processBuffer(floatData, count: floatCount)
        
        // Debug: log periodically with audio level info
        callbackCount += 1
        if callbackCount % 1000 == 0 {
            // Calculate max absolute value in buffer to check if audio is present
            var maxVal: Float = 0.0
            for i in 0..<Int(floatCount) {
                let absVal = abs(floatData[i])
                if absVal > maxVal { maxVal = absVal }
            }
            os_log(.debug, log: audioTapLog, "🔊 Audio callback fired %d times, buffer size: %d, max amplitude: %f", callbackCount, floatCount, maxVal)
        }
    }

    return noErr
}

private func getAudioObjectID(for pid: pid_t) -> AudioObjectID? {
    var audioObjectID: AudioObjectID = kAudioObjectUnknown
    var pidValue = pid

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

    // We query the global system object (kAudioObjectSystemObject)
    // We pass the PID as the "qualifier", and it returns the AudioObjectID
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        qualifierSize,
        &pidValue,
        &size,
        &audioObjectID
    )

    if status == noErr && audioObjectID != kAudioObjectUnknown {
        return audioObjectID
    }

    return nil
}

/// Singleton class for real-time audio capture from music apps
class AudioTap: NSObject {
    static let shared = AudioTap()
    
    let bridge = AudioBridge()
    /// Gates the DSP work in the CoreAudio IOProc. Written on main (from the
    /// consumer refcount below), read on the real-time thread — a single-byte
    /// access, so the worst case is one stale buffer; deliberately not locked,
    /// because taking a lock on the RT thread is far worse than that.
    var isPaused: Bool = false
    private var displayMagnitudes: [Float] = Array(repeating: 0, count: 6)
    /// Preallocated destination for `copySmoothedMagnitudes` so the display-rate
    /// timer does not allocate.
    private var magnitudeScratch: [Float] = Array(repeating: 0, count: 6)

    /// Number of mounted visualizer views. The 60 Hz timer below used to run
    /// whenever capture was live — notch closed, no visualizer on screen, screen
    /// asleep — burning main-thread time on magnitudes nobody rendered.
    private var consumerCount = 0

    // CoreAudio stuff
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID? = nil
    private var captureIsRunning = false
    /// `captureIsRunning` mirrored for readers off `audioQueue` — the timer-arming
    /// decision on the main thread needs it, and reading the plain `var` across
    /// threads is a data race.
    private let captureRunningFlag = OSAllocatedUnfairLock(initialState: false)
    private var isCaptureRunning: Bool {
        captureRunningFlag.withLock { $0 }
    }
    private var updateTimer: Timer?
    
    // Serial queue to prevent race conditions
    private let audioQueue = DispatchQueue(label: "com.atoll.audiotap", qos: .userInitiated)
    
    // Debounce restart requests
    private var pendingRestartWorkItem: DispatchWorkItem?

    private let targetBundleIDs = [
        "com.apple.Music",
        "com.spotify.client",
        "com.amazon.music",
        "sh.cider.genten.mac",
        "com.apple.Safari",
        "com.tidal.desktop",
        "tv.plex.plexamp",
        "com.roon.Roon",
        "com.audirvana.Audirvana-Studio",
        "com.vox.vox",
        "com.coppertino.Vox",
    ]

    private override init() {
        super.init()
    }

    @objc private func updateSmoothedMagnitudes() {
        let written = magnitudeScratch.withUnsafeMutableBufferPointer { buffer in
            Int(bridge.copySmoothedMagnitudes(buffer.baseAddress!, capacity: Int32(buffer.count)))
        }

        let smoothingFactor: Float = 0.4

        for i in 0..<min(written, displayMagnitudes.count) {
            let difference = magnitudeScratch[i] - displayMagnitudes[i]
            displayMagnitudes[i] += difference * smoothingFactor
        }
    }

    func getSmoothedMagnitudes() -> [Float] {
        return displayMagnitudes
    }

    // MARK: - Visualizer consumers

    /// Call when a view that renders `getSmoothedMagnitudes()` becomes visible.
    /// Balanced by `removeVisualizerConsumer()`.
    func addVisualizerConsumer() {
        onMain {
            self.consumerCount += 1
            if self.consumerCount == 1 {
                self.isPaused = false
                self.startUpdateTimerIfNeeded()
            }
        }
    }

    func removeVisualizerConsumer() {
        onMain {
            self.consumerCount = max(0, self.consumerCount - 1)
            guard self.consumerCount == 0 else { return }
            // Stop the timer and gate the DSP, but deliberately leave the tap and
            // aggregate device up: creating them is expensive, and startCaptureSync
            // re-decides which processes to tap (including the Bluetooth/Spotify
            // exclusion), so churning that on every view mount would destabilise
            // the CoreAudio session.
            self.isPaused = true
            self.updateTimer?.invalidate()
            self.updateTimer = nil
            self.displayMagnitudes = Array(repeating: 0, count: self.displayMagnitudes.count)
        }
    }

    /// Always asynchronous, never inline-on-main.
    ///
    /// A mixed inline/async hop would not be FIFO across threads: an off-main
    /// release (a view deallocated on a background thread) would be deferred while a
    /// main-thread acquire ran inline before it, so the decrement could land last and
    /// gate the timer off while a visualizer is still mounted.
    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    private func startUpdateTimerIfNeeded() {
        guard updateTimer == nil, isCaptureRunning, consumerCount > 0 else { return }
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(updateSmoothedMagnitudes),
            userInfo: nil,
            repeats: true
        )
        // Let the OS coalesce these with other main-runloop work.
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    func startCapture() async {
        await withCheckedContinuation { continuation in
            audioQueue.async { [weak self] in
                self?.startCaptureSync()
                continuation.resume()
            }
        }
    }
    
    private func startCaptureSync() {
        guard !captureIsRunning else {
            print("⚠️ [AudioTap] Capture already running, skipping start")
            return
        }

        let runningApps = NSWorkspace.shared.runningApplications
        var targetPIDs: [AudioDeviceID] = []

        // AirPods/Bluetooth output + Spotify don't mix: process-tapping Spotify into our
        // private aggregate device disturbs the system Now Playing / AVRCP session, so the
        // AirPods pause gesture finds no target and macOS falls back to Siri. Spotify is
        // controlled via AppleScript and registers weakly with MediaRemote, which is why
        // only it is affected (Apple Music etc. stay registered). While a Bluetooth route is
        // active, skip tapping Spotify to preserve media control — the visualizer stays live
        // for Spotify on wired/built-in output and for every other app on any output.
        let bluetoothOutputActive = AudioRouteManager.shared.isDefaultOutputBluetooth()

        for app in runningApps {
            if let bundleID = app.bundleIdentifier, targetBundleIDs.contains(bundleID) {
                if bundleID == SpotifyController.bundleIdentifier, bluetoothOutputActive {
                    print("⏭️ [AudioTap] Bluetooth output active — skipping Spotify tap to preserve AirPods media control")
                    continue
                }
                if let deviceID = getAudioObjectID(for: app.processIdentifier) {
                    targetPIDs.append(deviceID)
                    print("🎯 [AudioTap] Found \(app.localizedName ?? "App") with PID: \(app.processIdentifier), AudioObjectID: \(deviceID)")
                }
            }
        }

        if targetPIDs.isEmpty {
            print("⚠️ [AudioTap] None of our target apps are running right now.")
            return
        }

        let description = CATapDescription()
        description.processes = targetPIDs
        description.isMixdown = true
        description.isMono = true
        
        print("📋 [AudioTap] Creating tap for \(targetPIDs.count) processes: \(targetPIDs)")

        tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            print("🛑 [AudioTap] Tap Error: \(status) (\(fourCharCodeToString(status)))")
            return
        }
        print("✅ [AudioTap] Created process tap with ID: \(tapID)")

        // Get the tap's unique hardware UID
        var tapUID: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.stride)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        status = withUnsafeMutablePointer(to: &tapUID) { uidPtr in
            AudioObjectGetPropertyData(tapID, &propertyAddress, 0, nil, &propertySize, uidPtr)
        }
        guard status == noErr else {
            print("🛑 [AudioTap] UID Error: \(status) (\(fourCharCodeToString(status)))")
            cleanupPartialSetup()
            return
        }
        print("✅ [AudioTap] Got tap UID: \(tapUID)")

        // Create the Aggregate Device (a "virtual microphone" that we can route the tap into)
        let tapList = [[kAudioSubTapUIDKey: tapUID]]
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Atoll_Virtual_Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,  // Hides it from the user's sound settings
            kAudioAggregateDeviceTapListKey: tapList,
        ]

        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDict as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            print("🛑 [AudioTap] Aggregate Error: \(status) (\(fourCharCodeToString(status)))")
            cleanupPartialSetup()
            return
        }
        print("✅ [AudioTap] Created aggregate device with ID: \(aggregateDeviceID)")

        // Bind the Callback to the device
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        status = AudioDeviceCreateIOProcID(aggregateDeviceID, audioIOProc, selfPointer, &ioProcID)

        guard status == noErr, let validIOProcID = ioProcID else {
            print("🛑 [AudioTap] IOProc Error: \(status) (\(fourCharCodeToString(status)))")
            cleanupPartialSetup()
            return
        }
        print("✅ [AudioTap] Created IO proc")

        // Start listening
        status = AudioDeviceStart(aggregateDeviceID, validIOProcID)
        guard status == noErr else {
            print("🛑 [AudioTap] Start Error: \(status) (\(fourCharCodeToString(status)))")
            cleanupPartialSetup()
            return
        }

        captureIsRunning = true
        captureRunningFlag.withLock { $0 = true }
        callbackCount = 0
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateTimer?.invalidate()
            self.updateTimer = nil
            // A capture that comes up with nothing mounted stays gated; the timer
            // is armed by addVisualizerConsumer() when a view appears. A view that
            // stayed mounted across restartCapture() re-arms it here.
            self.isPaused = self.consumerCount == 0
            self.startUpdateTimerIfNeeded()
        }
        
        print("🟢 [AudioTap] CoreAudio CATap flowing through Aggregate Device!")
    }
    
    private func cleanupPartialSetup() {
        if let validIOProcID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, validIOProcID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
        
        DispatchQueue.main.async { [weak self] in
            self?.updateTimer?.invalidate()
            self?.updateTimer = nil
        }
    }

    func restartCapture() {
        // Cancel any pending restart
        pendingRestartWorkItem?.cancel()
        
        // Debounce: wait 500ms before actually restarting
        let workItem = DispatchWorkItem { [weak self] in
            self?.audioQueue.async {
                print("🔄 [AudioTap] Restarting capture...")
                self?.stopCaptureSync()
                // Small delay to let CoreAudio fully release resources
                Thread.sleep(forTimeInterval: 0.1)
                self?.startCaptureSync()
            }
        }
        pendingRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func stopCapture() {
        audioQueue.sync { [weak self] in
            self?.stopCaptureSync()
        }
    }
    
    private func stopCaptureSync() {
        guard captureIsRunning else { return }

        // Stop listening
        if let validIOProcID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, validIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, validIOProcID)
        }

        // Destroy resources
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }

        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
        captureIsRunning = false
        captureRunningFlag.withLock { $0 = false }
        
        DispatchQueue.main.async { [weak self] in
            self?.updateTimer?.invalidate()
            self?.updateTimer = nil
            // Reset display magnitudes safely on main thread
            self?.displayMagnitudes = Array(repeating: 0, count: 6)
        }

        print("🔴 [AudioTap] CoreAudio CATap capture stopped")
    }
    
    var isCapturing: Bool {
        captureIsRunning
    }

    deinit {
        stopCaptureSync()
    }
}

// Helper to convert OSStatus to readable string
private func fourCharCodeToString(_ code: OSStatus) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF)
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
    return String(code)
}
