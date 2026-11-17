import AppKit
import SwiftUI

/// Colour names a board can use, in the order shown in its context menu.
enum BoardPalette {
    static let names = ["红色", "橙色", "黄色", "绿色", "青色", "蓝色", "紫色", "灰色"]
    static func nsColor(_ name: String?) -> NSColor {
        switch name {
        case "橙色": return .systemOrange
        case "黄色": return .systemYellow
        case "绿色": return .systemGreen
        case "青色": return .systemCyan
        case "蓝色": return .systemBlue
        case "紫色": return .systemPurple
        case "灰色": return .systemGray
        default: return .systemRed
        }
    }
}

private final class SwatchView: NSView {
    let name: String
    let selected: Bool
    let onPick: (String) -> Void
    init(name: String, selected: Bool, onPick: @escaping (String) -> Void) {
        self.name = name; self.selected = selected; self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        toolTip = name
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 4, dy: 4)
        BoardPalette.nsColor(name).setFill()
        NSBezierPath(ovalIn: dot).fill()
        if selected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)); ring.lineWidth = 2; ring.stroke()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            let outer = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)); outer.lineWidth = 1; outer.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { onPick(name) }
    override func accessibilityPerformPress() -> Bool { onPick(name); return true }
    override var acceptsFirstResponder: Bool { false }
}

/// One row of colour dots that lives inside a board's context menu.
private final class ColorRowView: NSView {
    init(current: String?, onPick: @escaping (String) -> Void) {
        let size: CGFloat = 26, gap: CGFloat = 6, inset: CGFloat = 14
        let width = inset * 2 + CGFloat(BoardPalette.names.count) * size + CGFloat(BoardPalette.names.count - 1) * gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: size + 14))
        for (index, name) in BoardPalette.names.enumerated() {
            let swatch = SwatchView(name: name, selected: (current ?? "红色") == name, onPick: onPick)
            swatch.frame.origin = NSPoint(x: inset + CGFloat(index) * (size + gap), y: 7)
            addSubview(swatch)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

enum BoardMenuBuilder {
    /// 重命名 / 删除 on top, a divider, then the colour row.
    @MainActor
    static func menu(for board: Board, rename: @escaping () -> Void, delete: @escaping () -> Void, pick: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let renameItem = ClosureMenuItem(title: "重命名", handler: rename)
        let deleteItem = ClosureMenuItem(title: "删除收藏板（保留内容）…", handler: delete)
        menu.addItem(renameItem); menu.addItem(deleteItem); menu.addItem(.separator())
        addColors(to: menu, current: board.color, pick: pick)
        return menu
    }

    @MainActor
    static func palette(current: String?, pick: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        addColors(to: menu, current: current, pick: pick)
        return menu
    }

    @MainActor
    private static func addColors(to menu: NSMenu, current: String?, pick: @escaping (String) -> Void) {
        let colors = NSMenuItem(title: "收藏板颜色", action: nil, keyEquivalent: "")
        colors.view = ColorRowView(current: current) { [weak menu] name in
            menu?.cancelTracking()
            pick(name)
        }
        menu.addItem(colors)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

private struct BoardColorButton: NSViewRepresentable {
    let board: Board
    let enabled: Bool
    let pick: (String) -> Void
    let makeContextMenu: () -> NSMenu

    func makeNSView(context: Context) -> ColorButton {
        let button = ColorButton()
        button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = button
        button.action = #selector(ColorButton.showPalette)
        return button
    }

    func updateNSView(_ button: ColorButton, context: Context) {
        button.isEnabled = enabled
        button.contentTintColor = BoardPalette.nsColor(board.color)
        button.toolTip = "更改收藏板颜色"
        button.setAccessibilityLabel("更改“\(board.name)”颜色")
        button.setAccessibilityValue(board.color ?? "红色")
        button.makePalette = { BoardMenuBuilder.palette(current: board.color, pick: pick) }
        button.makeContextMenu = makeContextMenu
    }

    final class ColorButton: NSButton {
        var makePalette: (() -> NSMenu)?
        var makeContextMenu: (() -> NSMenu)?

        @objc func showPalette() {
            let bottom = isFlipped ? bounds.maxY : bounds.minY
            makePalette?().popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bottom), in: self)
        }

        override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = makeContextMenu?() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

struct ShelfBoardTab: View {
    let board: Board
    let store: Store
    @State private var dropTargeted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        HStack(spacing: 0) {
            BoardColorButton(board: board, enabled: store.canModifyHistory, pick: pickColor, makeContextMenu: contextMenu)
                .frame(width: 22, height: 28)
            Button { store.selectBoard(board.id) } label: {
                Text(board.name)
                    .font(.system(size: 13, weight: .medium))
                    .frame(minHeight: 28)
                    .padding(.trailing, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("拖动调整收藏板顺序")
            .onDrag(boardProvider)
        }
        .padding(.leading, 4)
        .foregroundStyle(Color.primary)
        .background(store.board == board.id ? Color(nsColor: BoardPalette.nsColor(board.color)).opacity(0.12) : Color.clear, in: shape)
        .contentShape(Rectangle())
        .overlay {
            if dropTargeted && store.canModifyHistory {
                shape.strokeBorder(Color.accentColor, lineWidth: 1.5).allowsHitTesting(false)
            }
        }
        .onDrop(of: [ShelfDrag.boardType, ShelfDrag.clipType], isTargeted: $dropTargeted, perform: receiveDrop)
        .overlay { RightClickMenu(makeMenu: contextMenu) }
    }

    private func pickColor(_ color: String) {
        guard color != (board.color ?? "红色") else { return }
        store.setBoardColor(board.id, color: color)
    }

    private func contextMenu() -> NSMenu {
        BoardMenuBuilder.menu(for: board,
                              rename: { Controller.shared.renameBoard(board) },
                              delete: { Controller.shared.confirmRemoveBoard(board) },
                              pick: pickColor)
    }

    private func boardProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard store.canModifyHistory else { return provider }
        let reference = store.beginShelfDrag(.board(board.id))
        let data = Data(reference.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: ShelfDrag.boardType, visibility: .all) { complete in
            complete(data, nil)
            return nil
        }
        return provider
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard store.canModifyHistory, let type = store.pendingShelfDrag?.type,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }),
              let drag = store.takeShelfDrag(type: type) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let reference = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
            DispatchQueue.main.async { store.completeShelfDrag(drag, reference: reference, to: board.id) }
        }
        return true
    }
}

/// Transparent overlay that only claims right-clicks (and Control-clicks), so left clicks,
/// drops and hover reach the SwiftUI view underneath.
struct RightClickMenu: NSViewRepresentable {
    let makeMenu: () -> NSMenu
    func makeNSView(context: Context) -> RightClickView { RightClickView() }
    func updateNSView(_ view: RightClickView, context: Context) { view.makeMenu = makeMenu }
    final class RightClickView: NSView {
        var makeMenu: (() -> NSMenu)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContext = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContext && bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func rightMouseDown(with event: NSEvent) { present(event) }
        override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { present(event) } }
        private func present(_ event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
