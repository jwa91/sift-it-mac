// The window the search lives in: a borderless panel that floats over every app and space, takes the keyboard without
// making Sift It the active app, and hands Quick Look the selected file.

import AppKit
import Quartz

final class SearchPanel: NSPanel {
    /// The file Quick Look shows.
    var quickLookItem: (@MainActor () -> URL?)?
    /// A key pressed while Quick Look shows; true when it was handled.
    var quickLookKey: (@MainActor (NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Growing to show results, and shrinking back to the bar, is quick.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.12 }

    // MARK: - Quick Look

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

extension SearchPanel: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItem?() == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookItem?() as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        return quickLookKey?(event) ?? false
    }
}

/// What's behind the panel's content: a material that blurs what's under the panel, so text stays legible over
/// anything. On macOS 26 it sits in Liquid Glass, which gives the panel its edge and its light; before, its corners are
/// rounded by a mask.
@MainActor
func panelBackground(cornerRadius: CGFloat, content: NSView) -> NSView {
    let material = NSVisualEffectView()
    material.material = .popover
    material.blendingMode = .behindWindow
    material.state = .active
    content.translatesAutoresizingMaskIntoConstraints = false
    material.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
        content.topAnchor.constraint(equalTo: material.topAnchor),
        content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
    ])
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = material
        return glass
    }
    material.maskImage = roundedMask(cornerRadius)
    return material
}

/// A mask that rounds a visual effect view's corners, stretching with it.
private func roundedMask(_ radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}
