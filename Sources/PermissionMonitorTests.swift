import Foundation

func runPermissionMonitorTests() {
    var checks = 0
    func check(_ value: Bool, _ label: String) {
        guard value else { print("FAIL: \(label)"); exit(1) }
        checks += 1
    }

    check(!PermissionState(accessibility: false, eventPosting: true).directPasteAllowed && PermissionState(accessibility: false, eventPosting: true).status == "系统尚未识别授权", "missing accessibility remains conservative")
    check(!PermissionState(accessibility: true, eventPosting: false).directPasteAllowed && PermissionState(accessibility: true, eventPosting: false).status == "辅助功能已开，按键权限未生效", "event permission is independently required")
    check(PermissionState(accessibility: true, eventPosting: true).directPasteAllowed, "both current permissions allow direct paste")

    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var calls = 0, active = 0, maxActive = 0
    var queriedOffMain = true
    var published: [PermissionState] = []
    var publishedOnMain = true
    let monitor = PermissionMonitor(
        queue: DispatchQueue(label: "openpaste.permission-monitor-test"),
        query: {
            stateLock.lock()
            calls += 1; active += 1; maxActive = max(maxActive, active)
            let call = calls
            queriedOffMain = queriedOffMain && !Thread.isMainThread
            stateLock.unlock()
            started.signal(); release.wait()
            stateLock.lock(); active -= 1; stateLock.unlock()
            return PermissionState(accessibility: call.isMultiple(of: 2), eventPosting: call.isMultiple(of: 2))
        },
        publish: { state in
            publishedOnMain = publishedOnMain && Thread.isMainThread
            published.append(state)
        })

    let began = ProcessInfo.processInfo.systemUptime
    monitor.refresh()
    check(ProcessInfo.processInfo.systemUptime - began < 0.05, "slow permission query does not block refresh caller")
    var everySlowGenerationStarted = true, mainStayedResponsive = true
    for generation in 1...4 {
        everySlowGenerationStarted = everySlowGenerationStarted && started.wait(timeout: .now() + 1) == .success
        var mainTurnRan = false
        DispatchQueue.main.async { mainTurnRan = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        mainStayedResponsive = mainStayedResponsive && mainTurnRan
        if generation < 4 { for _ in 0..<20 { monitor.refresh() } }
        release.signal()
        let deadline = Date().addingTimeInterval(1)
        while published.count < generation && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    check(everySlowGenerationStarted, "each coalesced slow permission generation starts")
    check(mainStayedResponsive, "main queue remains responsive through sustained slow permission queries")
    stateLock.lock(); let finalCalls = calls, finalMaxActive = maxActive, finalOffMain = queriedOffMain; stateLock.unlock()
    check(finalCalls == 4, "repeated refreshes coalesce to one follow-up per slow generation")
    check(finalMaxActive == 1 && finalOffMain, "permission queries are serial and off main")
    let expected = [false, true, false, true].map { PermissionState(accessibility: $0, eventPosting: $0) }
    check(publishedOnMain && published == expected, "every completed slow sample is published on main in query order")
    checkAuthorizationBranches(check)
    checkAuthorizationDeduplication(check)
    checkAccessibilityOnboarding(check)
    print("Permission monitor: \(checks) checks passed")
}

private let installedApp = URL(fileURLWithPath: "/Applications/GuziPaste.app")

private func waitForPermissionTest(_ finished: () -> Bool) {
    let deadline = Date().addingTimeInterval(1)
    while !finished() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

private func checkAuthorizationBranches(_ check: (Bool, String) -> Void) {
    typealias Result = AccessibilityAuthorization.Result
    let cases: [(AccessibilityGuide.Purpose, PermissionState, Result, [String])] = [
        (.directPaste, PermissionState(accessibility: false, eventPosting: false), .accessibilityPrompt, ["query AX", "request AX"]),
        (.directPaste, PermissionState(accessibility: true, eventPosting: false), .eventPostingPrompt, ["query AX", "query CG", "request CG"]),
        (.directPaste, PermissionState(accessibility: true, eventPosting: true), .alreadyAuthorized, ["query AX", "query CG"]),
        (.selection, PermissionState(accessibility: false, eventPosting: true), .accessibilityPrompt, ["query AX", "request AX"]),
        (.selection, PermissionState(accessibility: true, eventPosting: false), .alreadyAuthorized, ["query AX"])
    ]
    for (purpose, state, expected, expectedCalls) in cases {
        var calls: [String] = []
        var callsOffMain = true
        func record(_ call: String, returning value: Bool) -> Bool {
            calls.append(call)
            callsOffMain = callsOffMain && !Thread.isMainThread
            return value
        }
        let authorization = AccessibilityAuthorization(
            queue: DispatchQueue(label: "openpaste.permission-request-test"),
            queryAccessibility: { record("query AX", returning: state.accessibility) },
            queryEventPosting: { record("query CG", returning: state.eventPosting) },
            requestAccessibility: { record("request AX", returning: false) },
            requestEventPosting: { record("request CG", returning: true) })
        var result: Result?
        var completedOnMain = false
        authorization.request(for: purpose, appURL: installedApp) {
            completedOnMain = Thread.isMainThread
            result = $0
        }
        waitForPermissionTest { result != nil }
        let label = "\(purpose), \(state)"
        check(result == expected && completedOnMain, "\(label) completes on main with \(expected)")
        check(calls == expectedCalls && callsOffMain, "\(label) calls only the required APIs off main, in order")
        check(!authorization.isRequesting && authorization.hasRequested == (expected != .alreadyAuthorized),
            "\(label) finishes and records whether a prompt was requested")
        check(authorization.lastRequest == (expected == .alreadyAuthorized ? nil : expected),
            "\(label) records the API used, regardless of the request return value")
    }

    let unexpectedCall: () -> Bool = { fatalError("Unstable application paths must not reach any permission API") }
    let authorization = AccessibilityAuthorization(
        queryAccessibility: unexpectedCall, queryEventPosting: unexpectedCall,
        requestAccessibility: unexpectedCall, requestEventPosting: unexpectedCall)
    for invalidApp in [URL(fileURLWithPath: "/private/var/folders/test/AppTranslocation/abc/d/GuziPaste.app"),
                       URL(fileURLWithPath: "/tmp/OpenPaste"), URL(string: "https://example.invalid/GuziPaste.app")!] {
        var completed = false
        authorization.request(for: .directPaste, appURL: invalidApp) {
            completed = $0 == .unavailable && Thread.isMainThread
        }
        check(completed && !authorization.isRequesting && !authorization.hasRequested && authorization.lastRequest == nil,
            "rejects \(invalidApp) without starting a request")
    }
}

private func checkAuthorizationDeduplication(_ check: (Bool, String) -> Void) {
    let queue = DispatchQueue(label: "openpaste.permission-request-deduplication-test")
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var requests = 0
    var accessibilityAllowed = false
    let authorization = AccessibilityAuthorization(
        queue: queue,
        queryAccessibility: { accessibilityAllowed },
        queryEventPosting: { false },
        requestAccessibility: {
            requests += 1
            if requests == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            return false
        },
        requestEventPosting: { true })
    var results: [AccessibilityAuthorization.Result] = []
    authorization.request(for: .directPaste, appURL: installedApp) { results.append($0) }
    check(started.wait(timeout: .now() + 1) == .success && authorization.isRequesting && !authorization.hasRequested,
        "a slow request is marked in progress")
    var mainTurnRan = false
    DispatchQueue.main.async { mainTurnRan = true }
    waitForPermissionTest { mainTurnRan }
    check(mainTurnRan && results.isEmpty && authorization.isRequesting, "main remains responsive during a slow permission request")
    for _ in 0..<20 {
        authorization.request(for: .selection, appURL: installedApp) { results.append($0) }
    }
    release.signal()
    waitForPermissionTest { !authorization.isRequesting }
    check(queue.sync { requests } == 1 && results == [.accessibilityPrompt],
        "consecutive clicks while a request is running are ignored")

    authorization.request(for: .directPaste, appURL: installedApp) { results.append($0) }
    waitForPermissionTest { results.count >= 2 }
    check(queue.sync { requests } == 2 && results == [.accessibilityPrompt, .accessibilityPrompt] &&
        authorization.lastRequest == .accessibilityPrompt && authorization.hasRequested && !authorization.isRequesting,
        "an unsuccessful permission request can be retried after completion")

    queue.sync { accessibilityAllowed = true }
    authorization.request(for: .directPaste, appURL: installedApp) { results.append($0) }
    waitForPermissionTest { results.count >= 3 }
    check(results.last == .eventPostingPrompt && authorization.lastRequest == .eventPostingPrompt &&
        queue.sync { requests } == 2 && !authorization.isRequesting,
        "the next request uses CG once the real AX query reports permission")
}

private func checkAccessibilityOnboarding(_ check: (Bool, String) -> Void) {
    let suite = "openpaste.accessibility-onboarding-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let onboarding = AccessibilityOnboarding(defaults: defaults)
    let unauthorized = PermissionState(accessibility: false, eventPosting: false)
    let authorized = PermissionState(accessibility: true, eventPosting: true)

    check(onboarding.needsCheck, "a fresh profile needs an onboarding check")
    defaults.set(true, forKey: "recordingAccepted")
    check(onboarding.needsCheck, "recording consent does not mark authorization onboarding handled")
    check(onboarding.consumeOffer(state: unauthorized, recordingAccepted: true, pasteOnReturn: true),
        "offers onboarding with recording consent and direct paste enabled when permission is missing")
    let reopened = AccessibilityOnboarding(defaults: UserDefaults(suiteName: suite)!)
    check(!reopened.needsCheck && !reopened.consumeOffer(state: unauthorized, recordingAccepted: true, pasteOnReturn: true),
        "consumed offers are persisted and do not recur")

    defaults.removePersistentDomain(forName: suite)
    onboarding.markHandled()
    check(!onboarding.consumeOffer(state: unauthorized, recordingAccepted: true, pasteOnReturn: true),
        "marking an offer handled before startup checks suppresses the automatic guide")
    check(!defaults.bool(forKey: "recordingAccepted"), "marking authorization onboarding handled leaves recording consent independent")

    for (state, recordingAccepted, pasteOnReturn, label) in [
        (authorized, true, true, "already authorized"),
        (unauthorized, true, false, "direct paste is off"),
        (unauthorized, false, true, "recording consent is missing")
    ] {
        defaults.removePersistentDomain(forName: suite)
        check(!onboarding.consumeOffer(state: state, recordingAccepted: recordingAccepted, pasteOnReturn: pasteOnReturn),
            "skips the automatic guide when \(label)")
        check(!onboarding.needsCheck && !onboarding.consumeOffer(state: unauthorized, recordingAccepted: true, pasteOnReturn: true),
            "a skipped onboarding check stays handled")
    }
}
