import Foundation

private final class UpdateMockProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    static var requests = 0
    static var lastURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class UpdateSweepFileManager: FileManager, @unchecked Sendable {
    let enumerationStarted = DispatchSemaphore(value: 0)
    let enumerationAllowed = DispatchSemaphore(value: 0)
    let enumerationReturned = DispatchSemaphore(value: 0)
    let enumeratedOnMain = DispatchSemaphore(value: 0)
    let removed = DispatchSemaphore(value: 0)
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if Thread.isMainThread { enumeratedOnMain.signal() }
        enumerationStarted.signal()
        _ = enumerationAllowed.wait(timeout: .now() + 3)
        defer { enumerationReturned.signal() }
        return try super.contentsOfDirectory(atPath: path)
    }
    override func removeItem(at URL: URL) throws {
        try super.removeItem(at: URL)
        removed.signal()
    }
}
func runUpdateTests() {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { print("FAIL: \(label)"); exit(1) }
        count += 1; print("PASS: \(label)")
    }
    expect(ReleaseVersion("0.9.0")! < ReleaseVersion("0.10.0")!, "numeric version comparison")
    expect(ReleaseVersion("v1.0.0-beta.2")! < ReleaseVersion("1.0.0-beta.10")!, "numeric prerelease comparison")
    expect(ReleaseVersion("1.0.0-rc.1")! < ReleaseVersion("1.0.0")!, "stable supersedes installed prerelease")
    expect(ReleaseVersion("garbage") == nil, "invalid version rejected")
    func assets(_ tag: String, product: String) -> [GitHubRelease.Asset] {
        let stem = "\(product)-\(tag.dropFirst())-macos-universal"
        return [.init(name: "\(stem).zip", state: "uploaded"), .init(name: "\(stem).sha256", state: "uploaded")]
    }
    func release(_ tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false, url: String? = nil, names: [GitHubRelease.Asset]? = nil) -> GitHubRelease {
        GitHubRelease(tag_name: tag, html_url: url ?? "https://github.com/Drangon-Li/OpenPaste/releases/tag/\(tag)", body: "Demo release notes", draft: draft, prerelease: prerelease, assets: names ?? assets(tag, product: "GuziPaste"))
    }
    expect(release().isNewer(than: "draft"), "draft can discover stable release")
    expect(release().isNewer(than: "feature/search-a1b2c3d4"), "branch commit build can discover stable release")
    expect(!release().isNewer(than: "invalid"), "unknown installed version not treated as draft")
    expect(release().isNewer(than: "1.1.0"), "new stable release accepted")
    expect(!release().isNewer(than: "1.2.0"), "same version is not update")
    expect(!release(draft: true).isNewer(than: "1.1.0"), "draft ignored")
    expect(!release(prerelease: true).isNewer(than: "1.1.0"), "prerelease ignored")
    expect(!release(url: "https://example.com/update").isNewer(than: "1.1.0"), "untrusted download page rejected")
    let upstream = release(url: "https://github.com/SwallOwDili/OpenPaste/releases/tag/v1.2.0")
    expect(!upstream.isNewer(than: "1.1.0") && !upstream.hasInstaller, "upstream releases rejected")
    expect(!release(names: []).hasInstaller, "release without installer held back")
    let suite = "OpenPaste.UpdateTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UpdateMockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    expect(UpdateChecker(defaults: defaults, current: "1.1.0", session: session).automatic, "automatic checks default on")
    defaults.set(false, forKey: "automaticUpdateChecks")
    let checker = UpdateChecker(defaults: defaults, current: "1.1.0", session: session)
    expect(!checker.automatic, "explicitly disabled automatic checks stay off")
    checker.start()
    expect(!checker.checking, "disabled automatic check sends no request")
    func waitForCheck(_ checker: UpdateChecker, _ label: String) {
        let deadline = Date().addingTimeInterval(3)
        while checker.checking && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(!checker.checking, label)
    }
    func check(_ status: Int, _ item: GitHubRelease? = nil, manual: Bool = true) {
        UpdateMockProtocol.status = status
        UpdateMockProtocol.payload = item.flatMap { try? JSONEncoder().encode($0) } ?? Data("invalid".utf8)
        checker.check(manual: manual)
        waitForCheck(checker, "request completes \(status)")
    }
    check(200, release())
    expect(checker.available?.version == "1.2.0", "mock HTTP response produces update")
    checker.skip()
    expect(checker.available == nil, "skip hides notification")
    check(200, release(), manual: false)
    expect(checker.available == nil, "automatic check respects skip")
    check(200, release())
    expect(checker.available != nil, "manual check restores skipped version")
    let restored = UpdateChecker(defaults: defaults, current: "1.1.0", session: session)
    expect(restored.available?.version == "1.2.0", "cached update survives restart")
    let upgraded = UpdateChecker(defaults: defaults, current: "1.2.0", session: session)
    expect(upgraded.available == nil, "installed update removes stale badge")
    check(403)
    expect(checker.message.contains("受限"), "rate limit reported manually")
    let before = checker.message
    check(500, manual: false)
    expect(checker.message == before, "automatic error stays silent")
    check(200)
    expect(checker.message.contains("无法识别"), "malformed response reported")
    check(404)
    expect(checker.release == nil && checker.message.contains("暂未发布"), "missing release handled")
    check(200, release(names: []))
    expect(checker.available == nil && checker.message.contains("仍在构建"), "published release waits for uploaded installer")
    check(200, release("v1.0.0"))
    expect(checker.available == nil && checker.message.contains("最新"), "older release never downgrades")
    let requestCount = UpdateMockProtocol.requests
    checker.automatic = true
    checker.checkIfDue()
    expect(UpdateMockProtocol.requests == requestCount && !checker.checking, "24 hour throttle includes manual attempt")
    UpdateMockProtocol.payload = try! JSONEncoder().encode(release())
    defaults.set(try! JSONEncoder().encode(upstream), forKey: "cachedGitHubRelease")
    defaults.set("1.2.0", forKey: "skippedUpdateVersion")
    let launchChecker = UpdateChecker(defaults: defaults, current: "1.1.0", session: session)
    var launchOffers = [String]()
    launchChecker.onLaunchUpdateAvailable = { launchOffers.append($0.version) }
    expect(launchChecker.available == nil, "upstream cache ignored")
    launchChecker.start()
    expect(launchChecker.checking, "enabled launch check bypasses the last attempt timestamp")
    expect(launchOffers.isEmpty, "launch does not prompt before a response")
    waitForCheck(launchChecker, "launch request completes")
    expect(UpdateMockProtocol.lastURL?.absoluteString == "https://api.github.com/repos/Drangon-Li/OpenPaste/releases/latest", "launch requests stable fork release")
    expect(launchOffers == ["1.2.0"], "launch prompts once for a fresh fork release despite old upstream skip")
    launchChecker.start()
    expect(!launchChecker.checking && launchOffers == ["1.2.0"], "starting the same checker twice does not request or prompt again")
    launchChecker.skip(release("v1.1.0"))
    expect(launchChecker.available?.version == "1.2.0", "skip applies to the presented version")
    launchChecker.skip(release())
    let restartedChecker = UpdateChecker(defaults: defaults, current: "1.1.0", session: session)
    restartedChecker.onLaunchUpdateAvailable = { launchOffers.append($0.version) }
    restartedChecker.start()
    waitForCheck(restartedChecker, "restarted checker request completes")
    expect(launchOffers == ["1.2.0"] && restartedChecker.available == nil, "skip suppresses the same release on a new launch")
    let disabledDuringLaunch = UpdateChecker(defaults: defaults, current: "1.1.0", session: session)
    disabledDuringLaunch.onLaunchUpdateAvailable = { launchOffers.append($0.version) }
    disabledDuringLaunch.start()
    disabledDuringLaunch.automatic = false
    expect(!disabledDuringLaunch.checking, "disabling automatic checks cancels an in-flight launch check")
    defaults.set(true, forKey: "automaticUpdateChecks")
    // Prerelease opt-in
    func rc(_ tag: String, draft: Bool = false) -> GitHubRelease {
        return release(tag, draft: draft, prerelease: tag.contains("-"), names: assets(tag, product: "OpenPaste"))
    }
    expect(rc("v0.0.4-rc1").isNewer(than: "0.0.3", includePrerelease: true), "prerelease offered when opted in")
    expect(!rc("v0.0.4-rc1").isNewer(than: "0.0.3"), "prerelease hidden by default")
    expect(rc("v0.0.4-rc2").isNewer(than: "0.0.4-rc1", includePrerelease: true), "newer rc replaces older rc")
    expect(!rc("v0.0.4-rc1").isNewer(than: "0.0.4", includePrerelease: true), "stable is never downgraded to rc")
    expect(rc("v0.0.4").isNewer(than: "0.0.4-rc2", includePrerelease: true), "stable supersedes installed rc")
    expect(!rc("v0.0.5-rc1", draft: true).isNewer(than: "0.0.3", includePrerelease: true), "draft ignored even when opted in")
    func listData(_ items: [GitHubRelease]) -> Data { try! JSONEncoder().encode(items) }
    expect(UpdateChecker.newest(in: listData([rc("v0.0.3"), rc("v0.0.4-rc1"), rc("v0.0.4-rc2"), rc("v0.0.5-rc1", draft: true)]), includePrerelease: true)?.tag_name == "v0.0.4-rc2", "list picks newest eligible release")
    expect(UpdateChecker.newest(in: listData([rc("v0.0.4-rc1")]), includePrerelease: true)?.tag_name == "v0.0.4-rc1", "list with only rc offers it")
    expect(UpdateChecker.newest(in: Data("[]".utf8), includePrerelease: true) == nil, "empty list offers nothing")
    expect(UpdateChecker.newest(in: Data("{}".utf8), includePrerelease: false) == nil, "malformed latest rejected")
    let optIn = UpdateChecker(defaults: defaults, current: "0.0.3", session: session)
    UpdateMockProtocol.status = 200
    UpdateMockProtocol.payload = listData([rc("v0.0.3"), rc("v0.0.4-rc1")])
    expect(!optIn.includePrerelease, "prerelease opt-in defaults off")
    optIn.includePrerelease = true
    let optInDeadline = Date().addingTimeInterval(3)
    while (optIn.checking || optIn.available == nil) && Date() < optInDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(optIn.available?.version == "0.0.4-rc1", "opting in discovers rc")
    optIn.includePrerelease = false
    expect(optIn.available == nil, "opting out clears rc offer immediately")
    // Installer addressing
    let target = rc("v0.0.4-rc1")
    expect(target.installer?.appName == "OpenPaste.app" && target.installer?.checksumName == "OpenPaste-0.0.4-rc1-macos-universal.sha256", "legacy installer and checksum located by exact name")
    expect(target.assetURL("OpenPaste-0.0.4-rc1-macos-universal.zip")?.absoluteString == "https://github.com/Drangon-Li/OpenPaste/releases/download/v0.0.4-rc1/OpenPaste-0.0.4-rc1-macos-universal.zip", "asset URL built from fork, tag and name")
    expect(target.assetURL("../evil.zip") == nil && target.assetURL("OpenPaste-1.0.0-macos-universal.zip/../x") == nil && target.assetURL("other.zip") == nil, "asset names outside the pattern rejected")
    let modernAssets = assets("v1.2.0", product: "GuziPaste")
    let legacyAssets = assets("v1.2.0", product: "OpenPaste")
    expect(release(names: legacyAssets + modernAssets).installer?.appName == "GuziPaste.app", "prefer the new complete asset pair")
    expect(release(names: [modernAssets[0]] + legacyAssets).installer?.appName == "OpenPaste.app", "an incomplete new pair falls back to the complete legacy pair")
    expect(!release(names: [modernAssets[0], legacyAssets[1]]).hasInstaller, "ZIP and checksum with different prefixes are refused")
    expect(!release(names: [modernAssets[0]]).hasInstaller, "missing checksum holds back release")
    expect(release().assetURL("GuziPaste-9.9.9-macos-universal.zip") == nil, "asset for another version refused")
    let digest = String(repeating: "ab", count: 32)
    expect(UpdateVerification.expectedChecksum(from: "\(digest)  OpenPaste-x.zip\n", fileName: "OpenPaste-x.zip") == digest, "shasum line parsed")
    expect(UpdateVerification.expectedChecksum(from: digest.uppercased(), fileName: "any.zip") == digest, "bare digest parsed and lowercased")
    expect(UpdateVerification.expectedChecksum(from: "\(digest)  other.zip", fileName: "OpenPaste-x.zip") == nil, "checksum for another file rejected")
    expect(UpdateVerification.expectedChecksum(from: "not a digest", fileName: "x.zip") == nil && UpdateVerification.expectedChecksum(from: "abc  x.zip", fileName: "x.zip") == nil, "malformed checksum rejected")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPasteUpdateTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let abc = scratch.appendingPathComponent("abc.bin"); try! Data("abc".utf8).write(to: abc)
    expect((try? UpdateVerification.sha256(of: abc)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of known content")
    expect(UpdateVerification.isAllowedDownloadHost(URL(string: "https://github.com/a")) && UpdateVerification.isAllowedDownloadHost(URL(string: "https://release-assets.githubusercontent.com/x")), "GitHub hosts allowed")
    expect(!UpdateVerification.isAllowedDownloadHost(URL(string: "http://github.com/a")) && !UpdateVerification.isAllowedDownloadHost(URL(string: "https://evilgithub.com/a")) && !UpdateVerification.isAllowedDownloadHost(URL(string: "https://github.com.evil.example/a")) && !UpdateVerification.isAllowedDownloadHost(URL(string: "https://u:p@github.com/a")), "non-GitHub or insecure hosts refused")
    expect(UpdateVerification.isCertificateBased(requirement: "identifier \"x\" and certificate leaf = H\"ab\"") && !UpdateVerification.isCertificateBased(requirement: "cdhash H\"ab\" or cdhash H\"cd\""), "ad-hoc requirement is not certificate based")
    expect(UpdateVerification.isExpectedArchiveLayout(["GuziPaste.app"], appName: "GuziPaste.app") && UpdateVerification.isExpectedArchiveLayout(["OpenPaste.app", "__MACOSX"], appName: "OpenPaste.app"), "new and legacy single app archives accepted")
    expect(!UpdateVerification.isExpectedArchiveLayout([], appName: "GuziPaste.app") && !UpdateVerification.isExpectedArchiveLayout(["GuziPaste.app", "run.sh"], appName: "GuziPaste.app") && !UpdateVerification.isExpectedArchiveLayout(["OpenPaste.app"], appName: "GuziPaste.app"), "unexpected archive contents rejected")
    // Eligibility of the running copy
    let appDir = scratch.appendingPathComponent("Apps", isDirectory: true)
    let fakeApp = appDir.appendingPathComponent("OpenPaste.app", isDirectory: true)
    try! FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
    let signed = "identifier \"io.github.SwallOwDili.OpenPaste\" and certificate leaf = H\"ab\""
    expect(UpdateInstaller(bundleURL: fakeApp).blockingReason(requirement: signed) == nil, "writable certificate-signed app can update")
    expect(UpdateInstaller(bundleURL: fakeApp).blockingReason(requirement: "cdhash H\"ab\"") == .adHocSigned, "ad-hoc app refused")
    expect(UpdateInstaller(bundleURL: fakeApp).blockingReason(requirement: nil) == .unsigned, "unsigned app refused")
    expect(UpdateInstaller(bundleURL: scratch.appendingPathComponent("OpenPaste")).blockingReason(requirement: signed) == .notInstalledApp, "non-bundle run refused")
    expect(UpdateInstaller(bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/OpenPaste.app")).blockingReason(requirement: signed) == .translocated, "translocated app refused")
    let readOnlyDir = scratch.appendingPathComponent("ReadOnly", isDirectory: true)
    let lockedApp = readOnlyDir.appendingPathComponent("OpenPaste.app", isDirectory: true)
    try! FileManager.default.createDirectory(at: lockedApp, withIntermediateDirectories: true)
    try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)
    expect(UpdateInstaller(bundleURL: lockedApp).blockingReason(requirement: signed) == .notWritable, "unwritable parent refused")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path)
    // Startup cleanup must remain responsive while the app's parent directory is unavailable.
    func waitForSweepSignal(_ signal: DispatchSemaphore) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if signal.wait(timeout: .now()) == .success { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }
    let sweepDir = scratch.appendingPathComponent("Sweep", isDirectory: true)
    let sweepApp = sweepDir.appendingPathComponent("OpenPaste.app", isDirectory: true)
    let stale = sweepDir.appendingPathComponent(".OpenPaste-update-stale", isDirectory: true)
    let backup = sweepDir.appendingPathComponent(".OpenPaste-backup-original", isDirectory: true)
    let unrelated = sweepDir.appendingPathComponent("Other.app", isDirectory: true)
    for directory in [sweepApp, stale, backup, unrelated] { try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    let sweepManager = UpdateSweepFileManager()
    let sweepInstaller = UpdateInstaller(bundleURL: sweepApp, fileManager: sweepManager)
    let sweepStarted = Date()
    sweepInstaller.sweepStaleStaging()
    expect(Date().timeIntervalSince(sweepStarted) < 0.2, "staging sweep returns before slow enumeration completes")
    expect(waitForSweepSignal(sweepManager.enumerationStarted), "staging sweep begins directory enumeration")
    expect(sweepManager.enumeratedOnMain.wait(timeout: .now()) == .timedOut, "staging enumeration runs off the main thread")
    let mainResponded = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { mainResponded.signal() }
    expect(waitForSweepSignal(mainResponded), "main queue responds while staging enumeration is blocked")
    expect(FileManager.default.fileExists(atPath: stale.path), "blocked enumeration has not removed staging")
    sweepManager.enumerationAllowed.signal()
    expect(waitForSweepSignal(sweepManager.removed), "staging sweep eventually removes an abandoned directory")
    expect(!FileManager.default.fileExists(atPath: stale.path), "abandoned staging is removed")
    expect(FileManager.default.fileExists(atPath: backup.path) && FileManager.default.fileExists(atPath: unrelated.path), "staging sweep preserves backups and unrelated apps")
    let cancelledStale = sweepDir.appendingPathComponent(".OpenPaste-update-cancelled-sweep", isDirectory: true)
    try! FileManager.default.createDirectory(at: cancelledStale, withIntermediateDirectories: true)
    let cancelledManager = UpdateSweepFileManager()
    let cancelledInstaller = UpdateInstaller(bundleURL: sweepApp, fileManager: cancelledManager)
    cancelledInstaller.sweepStaleStaging()
    expect(waitForSweepSignal(cancelledManager.enumerationStarted), "competing generation test pauses enumeration")
    // cancel and prepare increment the same generation; this exercises the guard without downloading an update.
    cancelledInstaller.cancel()
    cancelledManager.enumerationAllowed.signal()
    expect(waitForSweepSignal(cancelledManager.enumerationReturned), "cancelled sweep enumeration returns")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    expect(cancelledManager.removed.wait(timeout: .now()) == .timedOut && FileManager.default.fileExists(atPath: cancelledStale.path), "generation change safely skips the entire staging sweep")
    // Candidate identity and signature
    func candidate(id: String, version: String) -> URL {
        let app = scratch.appendingPathComponent("Candidate-\(UUID().uuidString).app", isDirectory: true)
        try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "OpenPasteReleaseVersion": version, "CFBundleExecutable": "OpenPaste", "CFBundlePackageType": "APPL"]
        try! (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    func verify(_ app: URL, id: String = "io.github.SwallOwDili.OpenPaste") -> UpdateInstallError? {
        do { try UpdateInstaller.verifyBundle(app, release: target, requirement: signed, expectedIdentifier: id); return nil }
        catch { return error as? UpdateInstallError }
    }
    expect(verify(candidate(id: "com.evil.App", version: "0.0.4-rc1")) == .identityMismatch("bundle id"), "foreign bundle id refused")
    expect(verify(candidate(id: "io.github.SwallOwDili.OpenPaste", version: "0.0.9")) == .identityMismatch("版本号"), "version differing from the release refused")
    expect(verify(candidate(id: "io.github.SwallOwDili.OpenPaste", version: "0.0.4-rc1")) == .signatureMismatch, "unsigned candidate refused")
    // Update result notice
    let noticeSuite = "OpenPaste.UpdateNoticeTests.\(UUID().uuidString)"
    let noticeDefaults = UserDefaults(suiteName: noticeSuite)!
    defer { noticeDefaults.removePersistentDomain(forName: noticeSuite) }
    expect(UpdateNotice.consumePending(current: "0.0.4-rc1", defaults: noticeDefaults) == nil, "no notice without an update in flight")
    UpdateNotice.recordPending(from: "0.0.4-rc0", to: "0.0.4-rc1", defaults: noticeDefaults)
    expect(UpdateNotice.consumePending(current: "0.0.4-rc1", defaults: noticeDefaults) == UpdateNotice(from: "0.0.4-rc0", to: "0.0.4-rc1", succeeded: true), "notice reports success when the new version runs")
    expect(UpdateNotice.consumePending(current: "0.0.4-rc1", defaults: noticeDefaults) == nil, "notice shown only once")
    UpdateNotice.recordPending(from: "0.0.4-rc0", to: "0.0.4-rc1", defaults: noticeDefaults)
    expect(UpdateNotice.consumePending(current: "0.0.4-rc0", defaults: noticeDefaults) == UpdateNotice(from: "0.0.4-rc0", to: "0.0.4-rc1", succeeded: false), "notice reports failure when the old version still runs")
    UpdateNotice.recordPending(from: "0.0.4-rc0", to: "0.0.4-rc1", defaults: noticeDefaults)
    UpdateNotice.clearPending(defaults: noticeDefaults)
    expect(UpdateNotice.consumePending(current: "0.0.4-rc1", defaults: noticeDefaults) == nil, "cancelled install leaves no notice")
    print("Update checks: \(count) tests passed")
}
