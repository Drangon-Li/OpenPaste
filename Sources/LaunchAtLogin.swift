import AppKit
import Combine
import ServiceManagement

final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var changing = false
    @Published private(set) var message = ""

    var enabled: Bool { status == .enabled || status == .requiresApproval }
    var available: Bool { !AppEnvironment.current.acceptanceMode && !TestMode.active }

    func refresh() {
        guard available else { return }
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        guard available, !changing else { return }
        changing = true
        message = ""
        Task { @MainActor in
            defer { changing = false; refresh() }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                message = "登录启动设置失败：\(error.localizedDescription)"
            }
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
