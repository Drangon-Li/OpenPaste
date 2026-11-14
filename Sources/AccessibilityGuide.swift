import AppKit
import SwiftUI

struct AccessibilityGuide: View {
    enum Purpose {
        case directPaste
        case selection
    }

    @ObservedObject var store: Store
    @ObservedObject var authorization: AccessibilityAuthorization
    let purpose: Purpose
    let appURL: URL
    let requestPermission: () -> Void
    let openSettings: () -> Void
    let close: () -> Void

    private var canRequest: Bool {
        AccessibilityAuthorization.canRequest(appURL: appURL)
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

    private var explanation: String {
        switch purpose {
        case .directPaste: return "辅助功能权限用于向原输入框发送粘贴快捷键。稍后开启也能继续复制内容。"
        case .selection: return "辅助功能权限用于读取其他应用中选中的文字。稍后开启也能继续使用剪贴板历史。"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 20, weight: .semibold))
                        Label(status, systemImage: isAuthorized ? "checkmark.circle.fill" : "hand.raised")
                            .font(.callout).foregroundStyle(isAuthorized ? Color.green : Color.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("当前应用位置").font(.subheadline.weight(.medium))
                    Text(verbatim: appURL.path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !canRequest {
                    Text("请先将 GuziPaste.app 放入「应用程序」，从那里重新打开后再授权。")
                        .font(.callout)
                    if appURL.isFileURL { showInFinder }
                } else if !isAuthorized {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(explanation)
                        Text("系统提示出现后，按提示打开辅助功能设置并开启 GuziPaste 的开关。返回后，应用会自动检查权限。")
                    }
                    .font(.callout)
                }

                HStack(spacing: 10) {
                    Spacer()
                    if !canRequest {
                        Button("关闭", action: close).buttonStyle(.bordered)
                    } else if isAuthorized {
                        Button("查看辅助功能设置", action: openSettings).buttonStyle(.bordered)
                        Button("完成", action: close).buttonStyle(.borderedProminent)
                    } else {
                        Button("稍后", action: close).buttonStyle(.bordered)
                        primaryPermissionButton
                    }
                }

                if canRequest && !isAuthorized { recovery }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420)
    }

    private var primaryPermissionButton: some View {
        Group {
            if authorization.isRequesting {
                Button("正在请求…", action: requestPermission).disabled(true)
            } else if purpose == .directPaste && store.translationSelectionAuthorized &&
                        !store.directPasteAuthorized && authorization.lastRequest != .eventPostingPrompt {
                Button("请求粘贴按键权限", action: requestPermission)
            } else if authorization.hasRequested {
                Button("打开辅助功能设置", action: openSettings)
            } else {
                Button("请求辅助功能权限", action: requestPermission)
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private var showInFinder: some View {
        Button("在访达中显示当前位置") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
            .buttonStyle(.link)
    }

    private var recovery: some View {
        DisclosureGroup("找不到应用或权限未生效") {
            VStack(alignment: .leading, spacing: 8) {
                Text("列表中没有当前应用时，点击辅助功能列表下方的「+」，按访达显示的位置选择当前应用，再开启它的开关。")
                Text("旧 OpenPaste 的开关可能对应其他版本。当前应用的开关已开启但仍未生效时，先退出并重新打开 GuziPaste。仍有问题时，可在系统设置移除失效的旧条目，再添加当前应用。")
                showInFinder
                if authorization.hasRequested {
                    Button("再次请求权限", action: requestPermission)
                        .buttonStyle(.link).disabled(authorization.isRequesting)
                }
            }
            .font(.callout)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
