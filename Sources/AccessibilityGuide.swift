import AppKit
import SwiftUI

struct AccessibilityGuide: View {
    enum Purpose {
        case directPaste
        case selection
    }

    @ObservedObject var store: Store
    let purpose: Purpose
    let appURL: URL
    let openSettings: () -> Void
    let close: () -> Void

    private var canDrag: Bool {
        appURL.pathExtension == "app" && !UpdateVerification.isTranslocated(appURL)
    }

    private var title: String {
        switch purpose {
        case .directPaste: return "开启直接粘贴"
        case .selection: return "允许快速翻译读取选中文字"
        }
    }

    private var isAuthorized: Bool {
        switch purpose {
        case .directPaste: return store.directPasteAuthorized
        case .selection: return store.translationSelectionAuthorized
        }
    }

    private var status: String {
        switch purpose {
        case .directPaste: return store.permissionStatus
        case .selection: return isAuthorized ? "已授权读取选中文字" : "尚未授权读取选中文字"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
            Label(status, systemImage: isAuthorized ? "checkmark.circle.fill" : "hand.raised")
                .font(.callout).foregroundStyle(isAuthorized ? Color.green : Color.secondary)
            if canDrag {
                Text("把下面的应用图标拖到辅助功能列表，再开启它的权限开关。")
                    .font(.callout).multilineTextAlignment(.center)
                ApplicationDragIcon(appURL: appURL).frame(width: 80, height: 80)
                VStack(spacing: 4) {
                    Text(appURL.lastPathComponent).font(.headline)
                    Text(appURL.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("列表里只有 OpenPaste 时，也请添加当前版本。拖拽无效时，点击系统列表下方的「+」，按访达显示的位置选择当前应用。")
                    if !isAuthorized {
                        Text("开关已开启但权限未生效时，请退出并重新打开 GuziPaste。如果仍未生效，请移除旧的 OpenPaste 条目，再添加当前版本。")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 72, height: 72)
                Text("请先将 GuziPaste.app 放入「应用程序」并从那里重新打开，再添加辅助功能权限。")
                    .font(.callout).multilineTextAlignment(.center)
                Text("当前应用位于临时路径，或没有从应用包运行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("打开辅助功能设置", action: openSettings).buttonStyle(.borderedProminent)
            if canDrag {
                Button("在访达中显示应用") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
                    .buttonStyle(.link)
            }
            Button(isAuthorized ? "完成" : "稍后", action: close).buttonStyle(.link)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ApplicationDragIcon: NSViewRepresentable {
    let appURL: URL

    final class IconView: NSImageView, NSDraggingSource {
        var appURL: URL?
        private var mouseDownEvent: NSEvent?
        override var intrinsicContentSize: NSSize { NSSize(width: 80, height: 80) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { mouseDownEvent = event }
        override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }
        override func mouseDragged(with event: NSEvent) {
            guard let appURL, let image, let mouseDownEvent else { return }
            self.mouseDownEvent = nil
            let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            AppDiagnostics.record("accessibility-guide.drag-begin")
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            AppDiagnostics.record("accessibility-guide.drag-end", ["operation": String(operation.rawValue)])
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    }

    func makeNSView(context: Context) -> IconView {
        let view = IconView()
        view.image = NSApp.applicationIconImage
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("拖拽 GuziPaste 应用图标")
        view.setAccessibilityHelp("拖到系统设置的辅助功能应用列表")
        view.toolTip = "拖入辅助功能列表以添加当前 GuziPaste"
        return view
    }
    func updateNSView(_ view: IconView, context: Context) { view.appURL = appURL }
}
