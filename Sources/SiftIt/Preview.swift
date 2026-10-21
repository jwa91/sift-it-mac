// The selected result, large: the picture, the PDF page or the video where it matched, a recording's waveform around
// the moment, and the text that matched with the query's words in bold (a passage, a page, what's said).
//
// A new search that finds the same place again only changes which words are bold: nothing is loaded twice while
// someone types.

import AppKit
import SiftItKit

@MainActor
final class PreviewView: NSView {
    let player = Player()
    var engine: Engine?

    private let stack = NSStackView()
    private let media = NSView()
    private let picture = NSImageView()
    private let video = PlayerView()
    private let waveform = WaveformView()
    private let timeline = TimelineView()
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let why = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let footer = NSTextField(labelWithString: "")
    private var mediaWidth: NSLayoutConstraint!
    private var mediaHeight: NSLayoutConstraint!

    private(set) var hit: Hit?
    private var query = ""
    /// The text shown, before the query's words are made bold, and the line it starts at for code.
    private var passage: (text: String, firstLine: Int?)?
    /// Counts the results shown: work started for an earlier one is dropped when it ends.
    private var shown = 0

    static let inset: CGFloat = 16
    /// The width the preview's content has: the panel's, less the list and the margins.
    static let contentWidth = SearchController.width - SearchController.listWidth - 1 - 2 * inset

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        player.onTime = { [weak self] seconds in
            self?.timeline.time = seconds
            self?.waveform.time = seconds
        }
        player.onPlaying = { [weak self] playing in self?.timeline.playing = playing }
        timeline.onSeek = { [weak self] seconds in self?.player.seek(to: seconds) }
        timeline.onToggle = { [weak self] in self?.togglePlayback() }
        waveform.onSeek = { [weak self] seconds in self?.player.seek(to: seconds) }
        video.playerLayer.player = player.av
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Showing a result

    func show(_ hit: Hit?, query: String) {
        self.query = query
        if let hit, hit.path == self.hit?.path, hit.segmentId == self.hit?.segmentId {
            self.hit = hit
            render()
            return
        }
        shown += 1
        player.stop()
        self.hit = hit
        isHidden = hit == nil
        guard let hit else { return }
        title.stringValue = hit.name
        meta.stringValue = Self.meta(of: hit)
        why.stringValue = Self.why(hit) ?? ""
        why.isHidden = why.stringValue.isEmpty
        let play = hit.kind.plays && hit.loc != nil ? "    ⇥ Play" : ""
        footer.stringValue = "↩ \(Actions.openTitle(hit))\(play)    ⌘↩ Show in Finder    ⌘Y Quick Look"
        showMedia(hit)
        showText(hit)
    }

    /// Plays or pauses a recording or video; false when the result doesn't play.
    @discardableResult
    func togglePlayback() -> Bool {
        guard player.isLoaded else { return false }
        player.toggle()
        return true
    }

    /// Stops playing and lets the file go: when the panel hides.
    func stop() {
        player.stop()
        hit = nil
    }

    // MARK: - Media

    private func showMedia(_ hit: Hit) {
        let id = shown
        let pixels = Int(Self.contentWidth * (window?.backingScaleFactor ?? 2))
        let aspect = hit.info.width.flatMap { w in hit.info.height.map { CGFloat($0) / CGFloat(max(w, 1)) } }
        picture.image = nil
        waveform.levels = []
        for view in [picture, video, waveform, timeline] as [NSView] { view.isHidden = true }
        media.isHidden = false
        media.layer?.backgroundColor = .clear

        /// Shows a picture once it's decoded; `refit` sizes the media to it, for pictures whose shape isn't known before.
        func showPicture(refit: Bool = false, _ load: @escaping () async -> Picture?) {
            picture.isHidden = false
            Task {
                guard let made = await load(), id == shown else { return }
                if refit { fit(CGFloat(made.image.height) / CGFloat(max(made.image.width, 1)), maxHeight: 260) }
                picture.image = NSImage(cgImage: made.image, size: .zero)
            }
        }

        switch hit.kind {
        case .image, .screenshot:
            fit(aspect ?? 3 / 4, maxHeight: 260)
            picture.image = Images.shared.cachedThumbnail(for: hit)
            showPicture { await Images.picture(hit.url, pixels: pixels) }
        case .document where Format.isPDF(hit.path):
            fit(1.414, maxHeight: 260)
            showPicture(refit: true) { await Images.page(hit.url, Int(hit.loc ?? 1), pixels: pixels) }
        case .video:
            fit(aspect ?? 9 / 16, maxHeight: 250)
            media.layer?.backgroundColor = .black
            video.isHidden = false
            // A frame that decodes fast shows until the player has the exact one.
            showPicture { await Images.frame(hit.url, at: hit.loc ?? 0, pixels: pixels, exact: false) }
            showTimeline(hit)
        case .audio:
            mediaWidth.constant = Self.contentWidth
            mediaHeight.constant = 72
            waveform.isHidden = false
            showTimeline(hit)
            let range = Self.around(hit)
            waveform.range = range
            waveform.span = Self.span(of: hit)
            let columns = Int(Self.contentWidth / (WaveformView.bar + WaveformView.gap))
            Task {
                let levels = await Images.levels(
                    hit.url, from: range.lowerBound, to: range.upperBound, columns: columns)
                if let levels, id == shown { waveform.levels = levels }
            }
        default:
            media.isHidden = true
        }
    }

    /// Sizes the media to a shape (height over width), as large as fits.
    private func fit(_ aspect: CGFloat, maxHeight: CGFloat) {
        let height = min(maxHeight, Self.contentWidth * aspect)
        mediaHeight.constant = height.rounded()
        mediaWidth.constant = min(Self.contentWidth, height / max(aspect, 0.01)).rounded()
    }

    private func showTimeline(_ hit: Hit) {
        timeline.isHidden = false
        timeline.playing = false
        timeline.show(duration: hit.info.duration ?? 0, span: Self.span(of: hit))
        player.load(hit.url, at: hit.loc ?? 0)
    }

    /// The stretch that matched: a sound window's 30 seconds, what's said, or a frame's moment.
    static func span(of hit: Hit) -> ClosedRange<Double> {
        let start = hit.loc ?? 0
        let end = hit.locEnd ?? (hit.segment == .sound ? start + 30 : start)
        return start...max(start, end)
    }

    /// The two minutes or so a recording's waveform shows: a little before the match and the rest after.
    static func around(_ hit: Hit) -> ClosedRange<Double> {
        let span = span(of: hit)
        let duration = hit.info.duration ?? span.upperBound + 60
        guard duration > 120 else { return 0...max(duration, 1) }
        let start = min(max(0, span.lowerBound - 30), duration - 120)
        return start...(start + 120)
    }

    // MARK: - Text

    private func showText(_ hit: Hit) {
        let id = shown
        passage = hit.excerpt.map { ($0, nil) }
        render()
        let hasText = [Segment.passage, .page, .ocr, .speech].contains(hit.segment)
        scroll.isHidden = !hasText && passage == nil
        guard hasText, let engine else { return }
        Task {
            guard let whole = await engine.text(of: hit.segmentId), id == shown else { return }
            let numbered = hit.segment == .passage && Self.isCode(hit) ? hit.loc.map { max(1, Int($0)) } : nil
            passage = (whole, numbered)
            render()
        }
    }

    private static func isCode(_ hit: Hit) -> Bool {
        hit.kind == .code || hit.kind == .structured
    }

    /// The text with the query's words in bold, scrolled to the first of them.
    private func render() {
        guard let hit, let passage else {
            text.string = ""
            return
        }
        let code = Self.isCode(hit)
        let font: NSFont = code ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 13)
        let bold: NSFont =
            code ? .monospacedSystemFont(ofSize: 11.5, weight: .bold) : .systemFont(ofSize: 13, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = code ? 1 : 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let body = NSMutableAttributedString()
        if let first = passage.firstLine {
            let number: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
            ]
            for (index, line) in passage.text.components(separatedBy: "\n").enumerated() {
                if index > 0 { body.append(NSAttributedString(string: "\n", attributes: attributes)) }
                body.append(NSAttributedString(string: String(format: "%4d  ", first + index), attributes: number))
                body.append(NSAttributedString(string: line, attributes: attributes))
            }
        } else {
            body.append(NSAttributedString(string: passage.text, attributes: attributes))
        }

        var first: NSRange?
        let plain = body.string as NSString
        // Words of one or two letters ("a", "op", "in") would be bold all over: they're left plain.
        for word in Format.words(of: query) where word.count > 2 || word.allSatisfy(\.isNumber) {
            var searched = NSRange(location: 0, length: plain.length)
            while true {
                let found = plain.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searched)
                guard found.location != NSNotFound else { break }
                body.addAttributes(
                    [.font: bold, .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.3)], range: found)
                if first == nil || found.location < first!.location { first = found }
                searched = NSRange(location: NSMaxRange(found), length: plain.length - NSMaxRange(found))
            }
        }
        text.textStorage?.setAttributedString(body)
        if let first {
            text.scrollRangeToVisible(first)
        } else {
            text.scroll(.zero)
        }
    }

    // MARK: - Words about the result

    /// "Video · 3:50 · 640×360 · 3.9 MB · 12 Oct 2026"
    static func meta(of hit: Hit) -> String {
        let info = hit.info
        var parts = [Format.kindName(hit.kind)]
        if let duration = info.duration { parts.append(Format.timestamp(duration)) }
        if let pages = info.pages { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if hit.kind != .audio, let width = info.width, let height = info.height { parts.append("\(width)×\(height)") }
        let tags = [info.tags["title"], info.tags["artist"]].compactMap { $0 }
        if !tags.isEmpty { parts.append(tags.joined(separator: " — ")) }
        parts.append(Format.bytes(hit.size))
        parts.append(Date(timeIntervalSince1970: hit.modified).formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    /// What matched, in words: "What's said at 0:50–1:18", "Page 3".
    static func why(_ hit: Hit) -> String? {
        switch hit.segment {
        case .frame: Format.span(of: hit).map { "What's shown at \($0)" }
        case .sound: Format.span(of: hit).map { "What's heard at \($0)" }
        case .speech: Format.span(of: hit).map { "What's said at \($0)" }
        case .ocr:
            Format.isPDF(hit.path)
                ? Format.location(of: hit).map { "Text read from \($0.lowercased())" } : "Text in the picture"
        default: Format.location(of: hit)
        }
    }

    // MARK: - Layout

    private func build() {
        media.wantsLayer = true
        media.layer?.cornerRadius = 10
        media.layer?.masksToBounds = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        for view in [picture, video, waveform] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            media.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: media.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: media.trailingAnchor),
                view.topAnchor.constraint(equalTo: media.topAnchor),
                view.bottomAnchor.constraint(equalTo: media.bottomAnchor),
            ])
        }
        // The frame that decodes fast lies under the player, which draws over it once it has the exact one.
        video.playerLayer.backgroundColor = .clear

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        why.font = .systemFont(ofSize: 11, weight: .medium)
        why.textColor = .controlAccentColor
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setViews([media, timeline, title, meta, why, scroll, footer], in: .top)
        stack.setCustomSpacing(10, after: media)
        stack.setCustomSpacing(10, after: timeline)
        stack.setCustomSpacing(10, after: why)
        stack.setCustomSpacing(10, after: scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        mediaHeight = media.heightAnchor.constraint(equalToConstant: 250)
        mediaWidth = media.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            mediaWidth!,
            mediaHeight!,
            timeline.heightAnchor.constraint(equalToConstant: 18),
        ]
        for view in [timeline, title, meta, why, scroll, footer] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
}
