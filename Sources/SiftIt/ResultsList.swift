// The results, best first: the strong matches, then the weaker ones under a heading, in the engine's order. Each row
// is the file's name, its folder and where it matched, with the picture itself or the video's frame as its icon.

import AppKit
import SiftItKit

@MainActor
final class ResultsList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case hit(Hit)
        case heading(String)
    }

    let view: NSScrollView
    private let table = NSTableView()
    private var rows: [Row] = []

    /// The selection changed (nil: nothing selected).
    var onSelect: ((Hit?) -> Void)?
    /// A row was double-clicked.
    var onOpen: ((Hit) -> Void)?

    static let rowHeight: CGFloat = 44
    static let headingHeight: CGFloat = 26

    override init() {
        view = NSScrollView()
        super.init()
        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.selectionHighlightStyle = .regular
        // The search field keeps the keyboard; a click still selects.
        table.refusesFirstResponder = true
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        view.documentView = table
        view.drawsBackground = false
        view.hasVerticalScroller = true
        view.scrollerStyle = .overlay
        view.automaticallyAdjustsContentInsets = false
        view.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    }

    var selectedHit: Hit? {
        hit(at: table.selectedRow)
    }

    var isEmpty: Bool { rows.isEmpty }

    /// Shows these results, keeping `path` selected when it's among them, else selecting the first.
    func show(_ hits: [Hit], keeping path: String?) {
        let strong = hits.filter(\.strong)
        let weak = hits.filter { !$0.strong }
        rows = strong.map(Row.hit)
        if !weak.isEmpty {
            rows.append(.heading(strong.isEmpty ? "Weak matches" : "Weaker matches"))
            rows += weak.map(Row.hit)
        }
        table.reloadData()
        let kept = path.flatMap { path in
            rows.firstIndex { if case .hit(let hit) = $0 { hit.path == path } else { false } }
        }
        select(kept ?? firstHitRow)
    }

    /// Moves the selection by `step` results, past headings.
    func move(by step: Int) {
        guard !rows.isEmpty else { return }
        var row = table.selectedRow < 0 ? (step > 0 ? -1 : rows.count) : table.selectedRow
        repeat {
            row += step
        } while rows.indices.contains(row) && hit(at: row) == nil
        if rows.indices.contains(row) { select(row) }
    }

    func moveToEnd(_ end: Bool) {
        let rows = rows.indices.filter { hit(at: $0) != nil }
        if let row = end ? rows.last : rows.first { select(row) }
    }

    private var firstHitRow: Int? {
        rows.indices.first { hit(at: $0) != nil }
    }

    private func select(_ row: Int?) {
        guard let row else {
            table.deselectAll(nil)
            onSelect?(nil)
            return
        }
        let changed = table.selectedRow != row
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        // A reload that keeps the row selected changes no selection, but the hit in it may have changed.
        if !changed { onSelect?(hit(at: row)) }
    }

    private func hit(at row: Int) -> Hit? {
        guard rows.indices.contains(row), case .hit(let hit) = rows[row] else { return nil }
        return hit
    }

    @objc private func doubleClicked() {
        if let hit = hit(at: table.clickedRow) { onOpen?(hit) }
    }

    // MARK: - NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { hit(at: row) == nil }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        hit(at: row) == nil ? Self.headingHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { hit(at: row) != nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ResultRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let title):
            let cell =
                tableView.makeView(withIdentifier: HeadingCell.identifier, owner: nil) as? HeadingCell
                ?? HeadingCell()
            cell.label.stringValue = title
            return cell
        case .hit(let hit):
            let cell =
                tableView.makeView(withIdentifier: ResultCell.identifier, owner: nil) as? ResultCell
                ?? ResultCell()
            cell.show(hit)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedHit)
    }

    /// Dragging a result out gives the file.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        hit(at: row).map { $0.url as NSURL }
    }
}

/// A selected row: the accent colour in a rounded shape, as Spotlight draws it, also while the search field has the
/// keyboard.
private final class ResultRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 0), xRadius: 8, yRadius: 8).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {}
}

private final class HeadingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("heading")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class ResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("result")
    static let iconSize: CGFloat = 30

    private let icon = IconView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let place = NSTextField(labelWithString: "")
    private var path: String?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.lineBreakMode = .byTruncatingHead
        place.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        place.alignment = .right
        place.setContentCompressionResistancePriority(.required, for: .horizontal)
        place.setContentHuggingPriority(.required, for: .horizontal)
        for view in [icon, title, subtitle, place] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            title.trailingAnchor.constraint(lessThanOrEqualTo: place.leadingAnchor, constant: -6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            place.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            place.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        colour()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ hit: Hit) {
        path = hit.path
        title.stringValue = hit.name
        // A conversation's folder is the one it ran in, not its log's.
        subtitle.stringValue = hit.info.cwd.map { Format.shortPath($0) } ?? Format.folder(of: hit.path)
        place.stringValue = Format.shortLocation(of: hit) ?? ""
        guard Images.hasThumbnail(hit) else {
            icon.show(Images.shared.icon(for: hit), fill: false)
            return
        }
        if let cached = Images.shared.cachedThumbnail(for: hit) {
            icon.show(cached, fill: true)
            return
        }
        icon.show(Images.shared.icon(for: hit), fill: false)
        Task {
            let thumbnail = await Images.shared.thumbnail(for: hit, points: Self.iconSize * 1.5)
            // The cell may show another result by now.
            if let thumbnail, path == hit.path { icon.show(thumbnail, fill: true) }
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { colour() }
    }

    private func colour() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        subtitle.textColor =
            selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        place.textColor = subtitle.textColor
    }
}

/// A row's icon: a picture or a frame fills its square, cropped, as in Finder; a file type's icon fits in it.
private final class IconView: NSView {
    private var image: NSImage?
    private var fill = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func show(_ image: NSImage, fill: Bool) {
        self.image = image
        self.fill = fill
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
        layer.cornerRadius = fill ? 5 : 0
        layer.contents = image?.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
    }
}
