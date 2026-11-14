import Foundation
import Combine

struct ReleaseVersion: Comparable {
    let numbers: [Int]
    let suffix: [String]
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard text.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "-", maxSplits: 1)
        let parsed = parts[0].split(separator: ".").compactMap { Int($0) }
        guard parsed.count == 3 else { return nil }
        numbers = parsed
        suffix = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.suffix.isEmpty { return false }
        if rhs.suffix.isEmpty { return true }
        for (a, b) in zip(lhs.suffix, rhs.suffix) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return lhs.suffix.count < rhs.suffix.count
    }
}
struct GitHubRelease: Codable {
    static let repository = "Drangon-Li/OpenPaste"
    struct Asset: Codable { let name: String; let state: String }
    struct Installer {
        let appName: String
        let zipName: String
        let checksumName: String
    }
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var pageURL: URL? {
        guard let url = URL(string: html_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/\(Self.repository)/releases/tag/\(tag_name)" else { return nil }
        return url
    }
    /// A release the checker may offer: published, from this repository, and a stable version unless prereleases were chosen.
    func isEligible(includePrerelease: Bool) -> Bool {
        guard !draft, pageURL != nil, let parsed = ReleaseVersion(tag_name) else { return false }
        return includePrerelease || (!prerelease && parsed.suffix.isEmpty)
    }
    func isNewer(than current: String, includePrerelease: Bool = false) -> Bool {
        guard isEligible(includePrerelease: includePrerelease), let latest = ReleaseVersion(tag_name) else { return false }
        if let installed = ReleaseVersion(current) { return installed < latest }
        return current == "draft" || current.range(of: #"^.+-[0-9a-f]{8}$"#, options: .regularExpression) != nil
    }
    var hasInstaller: Bool { installer != nil }
    var installer: Installer? {
        guard ReleaseVersion(tag_name) != nil, pageURL != nil else { return nil }
        let uploaded = Set(assets.lazy.filter { $0.state == "uploaded" }.map(\.name))
        for product in ["GuziPaste", "OpenPaste"] {
            let stem = "\(product)-\(version)-macos-universal"
            let zip = "\(stem).zip"
            let checksum = "\(stem).sha256"
            if uploaded.contains(zip), uploaded.contains(checksum) {
                return Installer(appName: "\(product).app", zipName: zip, checksumName: checksum)
            }
        }
        return nil
    }
    func assetURL(_ name: String) -> URL? {
        guard let installer, name == installer.zipName || name == installer.checksumName else { return nil }
        return URL(string: "https://github.com/\(Self.repository)/releases/download/\(tag_name)/\(name)")
    }
}
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published var automatic: Bool { didSet {
        guard automatic != oldValue else { return }
        defaults.set(automatic, forKey: "automaticUpdateChecks")
        if automatic {
            checkIfDue()
        } else if pendingIntent == .launch || pendingIntent == .background {
            cancelCheck()
            onChange?()
        }
    } }
    @Published var includePrerelease: Bool { didSet {
        guard includePrerelease != oldValue else { return }
        defaults.set(includePrerelease, forKey: "updateIncludePrerelease")
        cancelCheck()
        clearRelease()
        check(.channelChanged)
    } }
    @Published private(set) var checking = false
    @Published private(set) var release: GitHubRelease?
    @Published private(set) var message = "尚未检查更新"
    var onChange: (() -> Void)?
    var onLaunchUpdateAvailable: ((GitHubRelease) -> Void)?
    private enum CheckIntent: Int {
        case background, launch, channelChanged, manual
        var reportsErrors: Bool { self == .channelChanged || self == .manual }
    }
    private static let skipKey = "skippedForkUpdateVersion"
    private let defaults: UserDefaults
    private let current: String
    private let session: URLSession
    private var timer: Timer?
    private var lastAttempt: Date?
    private var task: URLSessionDataTask?
    private var requestGeneration = 0
    private var pendingIntent: CheckIntent?
    var available: GitHubRelease? { release?.version == defaults.string(forKey: Self.skipKey) ? nil : release }
    var menuTitle: String { checking ? "正在检查更新…" : available.map { "发现新版 \($0.version)…" } ?? "检查更新…" }
    init(defaults: UserDefaults = AppEnvironment.current.defaults, current: String? = nil, session: URLSession? = nil) {
        self.defaults = defaults
        self.current = current ?? Bundle.main.object(forInfoDictionaryKey: "OpenPasteReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        automatic = defaults.object(forKey: "automaticUpdateChecks") as? Bool ?? true
        includePrerelease = defaults.bool(forKey: "updateIncludePrerelease")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: config)
        lastAttempt = defaults.object(forKey: "updateLastAttempt") as? Date
        if let data = defaults.data(forKey: "cachedGitHubRelease"), let cached = try? JSONDecoder().decode(GitHubRelease.self, from: data), cached.isNewer(than: self.current, includePrerelease: self.includePrerelease), cached.hasInstaller {
            release = cached
            message = "发现新版 \(cached.version)"
        }
    }
    deinit {
        timer?.invalidate()
        task?.cancel()
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        if automatic { check(.launch) }
    }
    func checkIfDue(now: Date = Date()) {
        guard automatic, lastAttempt.map({ now.timeIntervalSince($0) >= 86400 }) ?? true else { return }
        check(manual: false)
    }
    func skip() {
        if let available { skip(available) }
    }
    func skip(_ offered: GitHubRelease) {
        defaults.set(offered.version, forKey: Self.skipKey)
        if release?.version == offered.version { message = "已跳过 \(offered.version)，可手动检查重新查看" }
        onChange?()
    }
    /// `/releases/latest` returns one object; the list endpoint returns an array. The newest eligible release wins.
    static func newest(in data: Data, includePrerelease: Bool) -> GitHubRelease? {
        let decoder = JSONDecoder()
        let candidates = includePrerelease ? (try? decoder.decode([GitHubRelease].self, from: data)) ?? [] : (try? decoder.decode(GitHubRelease.self, from: data)).map { [$0] } ?? []
        return candidates.filter { $0.isEligible(includePrerelease: includePrerelease) }
            .max { (ReleaseVersion($0.tag_name) ?? ReleaseVersion("0.0.0")!) < (ReleaseVersion($1.tag_name) ?? ReleaseVersion("0.0.0")!) }
    }
    func check(manual: Bool = true) { check(manual ? .manual : .background) }

    private func cancelCheck() {
        requestGeneration += 1
        task?.cancel()
        task = nil
        pendingIntent = nil
        checking = false
    }

    private func check(_ intent: CheckIntent) {
        if let pendingIntent {
            if intent.rawValue > pendingIntent.rawValue { self.pendingIntent = intent }
            return
        }
        pendingIntent = intent
        checking = true
        if intent.reportsErrors { message = "正在检查更新…" }
        lastAttempt = Date()
        defaults.set(lastAttempt, forKey: "updateLastAttempt")
        let generation = requestGeneration
        let endpoint = includePrerelease ? "releases?per_page=30" : "releases/latest"
        let requestURL = URL(string: "https://api.github.com/repos/\(GitHubRelease.repository)/\(endpoint)")!
        var request = URLRequest(url: requestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GuziPaste-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.requestGeneration == generation else { return }
                let http = response as? HTTPURLResponse
                self.finishCheck(data: data, status: error == nil && http?.url == requestURL ? http?.statusCode : nil)
            }
        }
        task?.resume()
        onChange?()
    }

    private func finishCheck(data: Data?, status: Int?) {
        guard let intent = pendingIntent else { return }
        task = nil
        pendingIntent = nil
        checking = false
        defer { onChange?() }
        guard let status else { if intent.reportsErrors { message = "检查失败，请检查网络后重试" }; return }
        if status == 404 {
            clearRelease()
            message = "暂未发布正式版本"
            return
        }
        guard status == 200 else { if intent.reportsErrors { message = status == 403 || status == 429 ? "GitHub 请求受限，请稍后重试" : "检查失败（HTTP \(status)）" }; return }
        guard let data, data.count <= 2_000_000, let latest = Self.newest(in: data, includePrerelease: includePrerelease) else {
            if intent.reportsErrors { message = "无法识别版本信息，请稍后重试" }
            return
        }
        guard latest.isNewer(than: current, includePrerelease: includePrerelease) else {
            clearRelease()
            message = includePrerelease ? "已是最新版本" : "已是最新正式版本"
            return
        }
        guard latest.hasInstaller else {
            clearRelease()
            message = "新版安装包仍在构建，请稍后检查"
            return
        }
        release = latest
        defaults.set(try? JSONEncoder().encode(latest), forKey: "cachedGitHubRelease")
        if intent == .manual, defaults.string(forKey: Self.skipKey) == latest.version { defaults.removeObject(forKey: Self.skipKey) }
        message = available == nil ? "已跳过 \(latest.version)" : "发现新版 \(latest.version)"
        if intent == .launch, automatic, let available { onLaunchUpdateAvailable?(available) }
    }

    private func clearRelease() {
        release = nil
        defaults.removeObject(forKey: "cachedGitHubRelease")
    }
}
