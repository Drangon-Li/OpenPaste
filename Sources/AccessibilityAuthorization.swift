import ApplicationServices
import Combine
import Foundation

final class AccessibilityAuthorization: ObservableObject {
    enum Result: Equatable {
        case accessibilityPrompt
        case eventPostingPrompt
        case alreadyAuthorized
        case unavailable
    }

    @Published private(set) var isRequesting = false
    @Published private(set) var hasRequested = false
    @Published private(set) var lastRequest: Result?

    private let queue: DispatchQueue
    private let queryAccessibility: () -> Bool
    private let queryEventPosting: () -> Bool
    private let requestAccessibility: () -> Bool
    private let requestEventPosting: () -> Bool

    init(
        queue: DispatchQueue = DispatchQueue(label: "openpaste.accessibility-authorization", qos: .userInitiated),
        queryAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
        queryEventPosting: @escaping () -> Bool = { CGPreflightPostEventAccess() },
        requestAccessibility: @escaping () -> Bool = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            return AXIsProcessTrustedWithOptions(options as CFDictionary)
        },
        requestEventPosting: @escaping () -> Bool = { CGRequestPostEventAccess() }
    ) {
        self.queue = queue
        self.queryAccessibility = queryAccessibility
        self.queryEventPosting = queryEventPosting
        self.requestAccessibility = requestAccessibility
        self.requestEventPosting = requestEventPosting
    }

    static func canRequest(appURL: URL) -> Bool {
        appURL.isFileURL && appURL.pathExtension == "app" && !UpdateVerification.isTranslocated(appURL)
    }

    func request(for purpose: AccessibilityGuide.Purpose, appURL: URL, completion: @escaping (Result) -> Void) {
        precondition(Thread.isMainThread, "Accessibility authorization must be initiated on the main thread")
        guard !isRequesting else { return }
        guard Self.canRequest(appURL: appURL) else {
            completion(.unavailable)
            return
        }

        isRequesting = true
        queue.async {
            let result = self.requestIfNeeded(for: purpose)
            DispatchQueue.main.async {
                if result == .accessibilityPrompt || result == .eventPostingPrompt {
                    self.lastRequest = result
                    self.hasRequested = true
                }
                self.isRequesting = false
                completion(result)
            }
        }
    }

    private func requestIfNeeded(for purpose: AccessibilityGuide.Purpose) -> Result {
        guard queryAccessibility() else {
            _ = requestAccessibility()
            return .accessibilityPrompt
        }
        if purpose == .directPaste && !queryEventPosting() {
            _ = requestEventPosting()
            return .eventPostingPrompt
        }
        return .alreadyAuthorized
    }
}

struct AccessibilityOnboarding {
    private static let key = "accessibilityOnboardingHandled"
    let defaults: UserDefaults

    var needsCheck: Bool { !defaults.bool(forKey: Self.key) }

    func markHandled() {
        defaults.set(true, forKey: Self.key)
    }

    func consumeOffer(state: PermissionState, recordingAccepted: Bool, pasteOnReturn: Bool) -> Bool {
        guard needsCheck else { return false }
        markHandled()
        return recordingAccepted && pasteOnReturn && !state.directPasteAllowed
    }
}
