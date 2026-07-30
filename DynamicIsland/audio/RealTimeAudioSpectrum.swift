/*
 * Atoll (DynamicIsland)
 * Original work Copyright (C) 2026 ZephyrCodesStuff (https://github.com/ZephyrCodesStuff/rtaudio)
 * Modified work Copyright (C) 2026 Atoll Contributors
 *
 * Real-time audio spectrum visualization using CoreAudio tap data.
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
import Cocoa
import SwiftUI
import simd
import Defaults

/// NSView-based real-time audio spectrum visualizer
class RealTimeAudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?
    /// Tracks whether we currently hold an AudioTap consumer slot, so acquire and
    /// release stay balanced: startAnimating()/stopAnimating() are each reachable
    /// from several paths (viewDidMoveToWindow, setPlaying, deinit) and may be
    /// called twice in a row.
    private var isTapConsumer = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    deinit {
        stopAnimating()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = Defaults[.visualizerBarCount]
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            
            barLayers.append(barLayer)
            layer?.addSublayer(barLayer)
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else if isPlaying {
            startAnimating()
        }
    }

    private func acquireTap() {
        guard !isTapConsumer else { return }
        isTapConsumer = true
        AudioTap.shared.addVisualizerConsumer()
    }

    private func releaseTap() {
        guard isTapConsumer else { return }
        isTapConsumer = false
        AudioTap.shared.removeVisualizerConsumer()
    }

    private func startAnimating() {
        // `setPlaying(_:)` is called unconditionally from makeNSView/updateNSView, so
        // without this an off-window view could un-gate the CoreAudio DSP and start a
        // 30fps timer after viewDidMoveToWindow(nil). viewDidMoveToWindow re-enters
        // here once the view is actually in a window.
        guard window != nil else { return }
        acquireTap()
        guard animationTimer == nil else { return }
        // Use a timer at ~30fps for smooth animation.
        // The timer only runs while the view is in a window (see viewDidMoveToWindow)
        // and playback is active; tolerance lets the OS coalesce wakeups to save CPU.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.updateBarsFromAudio()
        }
        timer.tolerance = 1.0/60.0
        animationTimer = timer
    }
    
    private func stopAnimating() {
        releaseTap()
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }
    
    private func updateBarsFromAudio() {
        guard isPlaying else {
            resetBars()
            return
        }

        // Get real-time magnitudes from AudioTap
        let magnitudes = AudioTap.shared.getSmoothedMagnitudes()

        // One transaction around the whole loop rather than per bar: this runs at
        // 30fps, and each begin/commit pair is CoreAnimation bookkeeping.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, barLayer) in barLayers.enumerated() {
            guard index < magnitudes.count else { break }
            let magnitude = magnitudes[index]
            // Map magnitude (0-1) to scale (0.2 - 1.0) for visual appeal
            let scale = max(0.2, min(1.0, CGFloat(magnitude) * 1.5 + 0.2))
            barLayer.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }

    private func resetBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for barLayer in barLayers {
            barLayer.transform = CATransform3DMakeScale(1, 0.2, 1)
        }
        CATransaction.commit()
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

/// SwiftUI wrapper for RealTimeAudioSpectrum
struct RealTimeAudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    
    func makeNSView(context: Context) -> RealTimeAudioSpectrum {
        let spectrum = RealTimeAudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }
    
    func updateNSView(_ nsView: RealTimeAudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ nsView: RealTimeAudioSpectrum, coordinator: ()) {
        nsView.setPlaying(false)
    }
}

#Preview {
    RealTimeAudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
