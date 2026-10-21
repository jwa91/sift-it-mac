// Playing a recording or a video in the preview, from the moment it matched: one player for the panel, the video's
// picture, the timeline under it, and a recording's waveform around the moment.

import AVFoundation
import AppKit
import SiftItKit

@MainActor
final class Player {
    let av = AVPlayer()
    /// Where it is, about twenty times a second while it plays, and after a seek.
    var onTime: ((Double) -> Void)?
    var onPlaying: ((Bool) -> Void)?

    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?

    init() {
        // Local files: start at once rather than buffer first.
        av.automaticallyWaitsToMinimizeStalling = false
        av.preventsDisplaySleepDuringVideoPlayback = false
        timeObserver = av.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.onTime?(time.seconds) }
        }
        statusObserver = av.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onPlaying?(playing) } }
        }
    }

    var isLoaded: Bool { av.currentItem != nil }
    var isPlaying: Bool { av.timeControlStatus != .paused }

    /// Loads a file and stands at `seconds`, paused.
    func load(_ url: URL, at seconds: Double) {
        av.replaceCurrentItem(with: AVPlayerItem(url: url))
        seek(to: seconds)
    }

    func seek(to seconds: Double) {
        av.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero)
        onTime?(seconds)
    }

    func toggle() {
        isPlaying ? av.pause() : av.play()
    }

    /// Lets the file go: decoders and buffers with it.
    func stop() {
        av.pause()
        av.replaceCurrentItem(with: nil)
    }
}

/// A video's picture, drawn by the player's own layer.
final class PlayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Play and pause, the time, and the whole length with the stretch that matched; a click or a drag seeks.
final class TimelineView: NSView {
    var onSeek: ((Double) -> Void)?
    var onToggle: (() -> Void)?

    private let button = NSButton()
    private let now = NSTextField(labelWithString: "0:00")
    private let length = NSTextField(labelWithString: "0:00")
    private let track = TrackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggle)
        button.contentTintColor = .labelColor
        playing = false
        for label in [now, length] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        track.onSeek = { [weak self] fraction in
            guard let self else { return }
            onSeek?(fraction * track.duration)
        }
        let row = NSStackView(views: [button, now, track, length])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 16),
            track.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(duration: Double, span: ClosedRange<Double>) {
        track.duration = max(duration, span.upperBound, 0.1)
        track.span = span
        length.stringValue = Format.timestamp(duration)
        time = span.lowerBound
    }

    var time: Double = 0 {
        didSet {
            track.time = time
            now.stringValue = Format.timestamp(time)
        }
    }

    var playing = false {
        didSet {
            let name = playing ? "pause.fill" : "play.fill"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: playing ? "Pause" : "Play")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        }
    }

    @objc private func toggle() { onToggle?() }
}

private final class TrackView: NSView {
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var span: ClosedRange<Double> = 0...0 { didSet { needsDisplay = true } }
    var time: Double = 0 { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: bounds.midY - 2, width: bounds.width, height: 4)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        // The stretch that matched; a moment is a short mark.
        let from = x(span.lowerBound)
        let to = max(x(span.upperBound), from + 3)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: from, y: bar.minY, width: to - from, height: bar.height), xRadius: 2,
            yRadius: 2
        ).fill()
        let head = NSRect(x: x(time) - 1, y: bounds.midY - 6, width: 2, height: 12)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: head, xRadius: 1, yRadius: 1).fill()
    }

    private func x(_ seconds: Double) -> CGFloat {
        bounds.width * CGFloat(min(max(seconds / duration, 0), 1))
    }

    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }

    private func seek(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onSeek?(Double(min(max(point.x / bounds.width, 0), 1)))
    }
}

/// A recording's loudness around the moment that matched, with that stretch in the accent colour and where it's
/// playing as a line.
final class WaveformView: NSView {
    /// The seconds shown.
    var range: ClosedRange<Double> = 0...1 { didSet { needsDisplay = true } }
    var span: ClosedRange<Double> = 0...0 { didSet { needsDisplay = true } }
    var levels: [Float] = [] { didSet { needsDisplay = true } }
    var time: Double? { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?

    static let bar: CGFloat = 2
    static let gap: CGFloat = 1

    /// How many bars fit.
    var columns: Int { max(1, Int(bounds.width / (Self.bar + Self.gap))) }

    override func draw(_ dirtyRect: NSRect) {
        let middle = bounds.midY
        let room = bounds.height / 2 - 4
        let seconds = range.upperBound - range.lowerBound
        let width = Self.bar + Self.gap
        let count = levels.isEmpty ? columns : levels.count
        for column in 0..<count {
            let at = range.lowerBound + seconds * (Double(column) + 0.5) / Double(count)
            let level = levels.isEmpty ? 0 : CGFloat(levels[column])
            let height = max(2, room * 2 * level)
            let color = span.contains(at) ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
            color.setFill()
            let rect = NSRect(x: CGFloat(column) * width, y: middle - height / 2, width: Self.bar, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
        if let time, range.contains(time) {
            let x = bounds.width * CGFloat((time - range.lowerBound) / seconds)
            NSColor.labelColor.setFill()
            NSRect(x: x - 0.75, y: 2, width: 1.5, height: bounds.height - 4).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = Double(min(max(point.x / bounds.width, 0), 1))
        onSeek?(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
    }
}
