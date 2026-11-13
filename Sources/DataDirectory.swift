import AppKit
import FileProvider

struct SyncRevision: Codable, Equatable {
    var time: Double
    var deleted: Bool
    var signature: String
}
struct SyncIndex: Codable, Equatable {
    var clips: [String: SyncRevision] = [:]
    var boards: [String: SyncRevision] = [:]
}
struct SyncSnapshot {
    var archive: Archive
    var index: SyncIndex
}
struct ICloudDownloadPending: LocalizedError {
    var errorDescription: String? { "iCloud 内容正在下载" }
}
private struct DirectoryTargetChanged: LocalizedError {
    var errorDescription: String? { "目标目录在迁移前发生变化，请重新选择" }
}
private struct DirectoryTarget {
    let snapshot: SyncSnapshot
    let hasDeviceManifests: Bool
    let exists: Bool
    let stamp: String?
    let watchesLegacy: Bool
}
private final class DirectoryTargetHistory {
    // Probe and migration reads are serialized by the main-queue handoff.
    var existed = false
    var indexes = Set<URL>()
}
enum DataDirectory {
    typealias ReadinessCheck = (URL) throws -> Void
    typealias DownloadState = (pending: Bool, downloading: Bool)
    static var defaultRoot: URL { AppEnvironment.current.defaultDataRoot }
    private static var mobileDocuments: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }
    static var iCloudDriveRoot: URL { mobileDocuments.appendingPathComponent("com~apple~CloudDocs", isDirectory: true) }
    static func deviceID(defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: "dataDeviceID"), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString; defaults.set(id, forKey: "dataDeviceID"); return id
    }
    static func isCloud(_ root: URL) -> Bool {
        root.standardizedFileURL.path.hasPrefix(mobileDocuments.path + "/") ||
            (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }
    static func cacheURL(_ root: URL) -> URL {
        defaultRoot.deletingLastPathComponent().appendingPathComponent("OpenPaste-sync-cache").appendingPathComponent(HistoryStorage.digest(Data(root.standardizedFileURL.path.utf8))).appendingPathComponent("history.json")
    }
    static func cached(_ root: URL) throws -> SyncSnapshot? {
        let url = cacheURL(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let archive = try HistoryStorage.read(from: url)
        return SyncSnapshot(archive: archive, index: try HistoryStorage.syncIndex(from: url) ?? baseline(archive).index)
    }
    static func cache(_ snapshot: SyncSnapshot, root: URL) throws {
        try HistoryStorage.write(snapshot.archive, to: cacheURL(root), sync: snapshot.index)
    }
    static func ready(_ url: URL) throws {
        try ready(url, requestDownload: FileManager.default.startDownloadingUbiquitousItem(at:))
    }
    static func ready(_ url: URL, downloadStatus: (URL) throws -> DownloadState = DataDirectory.downloadState,
                      requestDownload: (URL) throws -> Void) throws {
        let placeholder = downloadPlaceholder(for: url)
        let hasPlaceholder = try fileInfo(placeholder) != nil
        let state = try downloadStatus(url)
        guard hasPlaceholder || state.pending else { return }
        if state.downloading { throw ICloudDownloadPending() }
        do { try requestDownload(url) }
        catch {
            if isTemporaryDownloadError(error) { throw ICloudDownloadPending() }
            // The canonical path can appear while the request is being sent.
            guard isMissingFile(error), hasPlaceholder else { throw error }
        }
        if try fileInfo(placeholder) != nil || downloadStatus(url).pending || fileInfo(url) == nil {
            throw ICloudDownloadPending()
        }
    }
    private static func downloadPlaceholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }
    private static func downloadState(of url: URL) throws -> DownloadState {
        // Directory enumeration and repeated checks can leave stale URL resource values.
        let freshURL = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
        let values: URLResourceValues
        do {
            values = try freshURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingErrorKey])
        } catch {
            if isMissingFile(error) { return (false, false) }
            if isTemporaryDownloadError(error) { return (true, false) }
            throw error
        }
        if let error = values.ubiquitousItemDownloadingError, !isTemporaryDownloadError(error) { throw error }
        let downloading = values.ubiquitousItemIsDownloading == true
        let stale = values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus.map { $0 != .current } == true
        return (downloading || stale || values.ubiquitousItemDownloadingError != nil, downloading)
    }
    private static func isTemporaryDownloadError(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain:
            if error.code == NSUbiquitousFileUnavailableError || error.code == NSUbiquitousFileUbiquityServerNotAvailable { return true }
            if [NSFileReadUnknownError, NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code),
               let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                return isTemporaryDownloadError(underlying)
            }
            return false
        case NSFileProviderErrorDomain:
            if #available(macOS 14.1, *), error.code == NSFileProviderError.Code.providerDomainTemporarilyUnavailable.rawValue { return true }
            return error.code == NSFileProviderError.Code.serverUnreachable.rawValue
        case NSURLErrorDomain:
            return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(error.code)
        default:
            return false
        }
    }
    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
    private static func fileInfo(_ url: URL, followingSymlinks: Bool = false) throws -> stat? {
        var info = stat()
        let result = followingSymlinks ? stat(url.path, &info) : lstat(url.path, &info)
        if result == 0 { return info }
        let code = errno
        if code == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    private static func readyDirectory(_ url: URL, readiness: ReadinessCheck) throws {
        var directory = url
        while true {
            try readiness(directory)
            if try fileInfo(directory, followingSymlinks: true) != nil { return }
            directory.deleteLastPathComponent()
        }
    }
    static func coordinated<T>(_ url: URL, writing: Bool, _ action: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { path in result = Result { try action(path) } }
        if writing { coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
        if let error = coordinationError { throw error }
        guard let result else { throw PasteImport.failure("无法访问数据目录") }
        return try result.get()
    }
    static func manifests(_ root: URL, readiness: ReadinessCheck = DataDirectory.ready,
                          includeLegacy: Bool = false, includeLegacyAlongsideDevices: Bool = false) throws -> [URL] {
        try readiness(root)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let names = files.compactMap { name -> String? in
            if name.hasPrefix("device-"), name.hasSuffix(".json") { return name }
            if name.hasPrefix(".device-"), name.hasSuffix(".json.icloud") {
                return String(name.dropFirst().dropLast(".icloud".count))
            }
            return nil
        }
        var indexes = Set(names)
        if includeLegacy, indexes.isEmpty || includeLegacyAlongsideDevices,
           files.contains("history.json") || files.contains(".history.json.icloud") {
            indexes.insert("history.json")
        }
        return indexes.sorted().map { root.appendingPathComponent($0, isDirectory: false) }
    }
    static func usesSync(_ root: URL) -> Bool {
        isCloud(root) || (try? FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            ($0.hasPrefix("device-") && $0.hasSuffix(".json")) ||
                ($0.hasPrefix(".device-") && $0.hasSuffix(".json.icloud"))
        }) == true
    }
    static func stamp(_ root: URL, manifestFiles: [URL]) throws -> String {
        try stamp(manifestFiles.isEmpty ? [root.appendingPathComponent("history.json")] : manifestFiles,
                  allowMissingLegacy: manifestFiles.isEmpty)
    }
    private static func stamp(_ candidates: [URL], allowMissingLegacy: Bool = false) throws -> String {
        return try candidates.compactMap { url -> String? in
            let placeholder = downloadPlaceholder(for: url)
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]
            var path = try fileInfo(placeholder) == nil ? url : placeholder
            let values: URLResourceValues
            do { values = try path.resourceValues(forKeys: keys) }
            catch {
                guard isMissingFile(error) else { throw error }
                if path == placeholder {
                    path = url
                    values = try path.resourceValues(forKeys: keys)
                } else if try fileInfo(placeholder) != nil {
                    path = placeholder
                    values = try path.resourceValues(forKeys: keys)
                } else {
                    if allowMissingLegacy { return nil }
                    throw error
                }
            }
            return "\(path.lastPathComponent):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0):\(String(describing: values.fileResourceIdentifier))"
        }.joined(separator: "|")
    }
    static func clipSignature(_ clip: Clip) -> String {
        var metadata = clip; metadata.cachedDigest = clip.fingerprint; metadata.parts = []; metadata.boards.sort { $0.uuidString < $1.uuidString }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return HistoryStorage.digest((try? encoder.encode(metadata)) ?? Data())
    }
    static func boardSignature(_ board: Board) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return HistoryStorage.digest((try? encoder.encode(board)) ?? Data())
    }
    static func baseline(_ archive: Archive) -> SyncSnapshot {
        SyncSnapshot(archive: archive, index: SyncIndex(clips: Dictionary(archive.clips.map { ($0.id.uuidString, SyncRevision(time: 0, deleted: false, signature: clipSignature($0))) }, uniquingKeysWith: { a, _ in a }), boards: Dictionary(archive.boards.map { ($0.id.uuidString, SyncRevision(time: 0, deleted: false, signature: boardSignature($0))) }, uniquingKeysWith: { a, _ in a })))
    }
    static func newer(_ a: SyncRevision, _ b: SyncRevision) -> Bool {
        if a.time != b.time { return a.time > b.time }
        if a.deleted != b.deleted { return a.deleted }
        return a.signature > b.signature
    }
    static func merge(_ a: SyncSnapshot, _ b: SyncSnapshot) -> SyncSnapshot {
        var index = a.index
        var clips = Dictionary(a.archive.clips.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { x, _ in x })
        var boards = Dictionary(a.archive.boards.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { x, _ in x })
        let otherClips = Dictionary(b.archive.clips.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { x, _ in x })
        let otherBoards = Dictionary(b.archive.boards.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { x, _ in x })
        for (id, revision) in b.index.clips where index.clips[id].map({ newer(revision, $0) }) ?? true { index.clips[id] = revision; clips[id] = revision.deleted ? nil : otherClips[id] }
        for (id, revision) in b.index.boards where index.boards[id].map({ newer(revision, $0) }) ?? true { index.boards[id] = revision; boards[id] = revision.deleted ? nil : otherBoards[id] }
        let validBoards = Set(boards.values.map(\.id))
        let validClips: [Clip] = clips.values.map { item in
            var clip = item
            clip.boards.removeAll { !validBoards.contains($0) }
            return clip
        }
        let orderedClips = validClips.sorted { lhs, rhs in
            if lhs.created == rhs.created { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.created > rhs.created
        }
        return SyncSnapshot(archive: Archive(clips: orderedClips, boards: boards.values.sorted { $0.id.uuidString < $1.id.uuidString }), index: index)
    }
    static func equivalent(_ a: Clip, _ b: Clip) -> Bool {
        guard a.created == b.created, a.source == b.source, a.sourceID == b.sourceID, a.kind == b.kind, a.title == b.title, a.text == b.text, Set(a.boards) == Set(b.boards), a.ocrText == b.ocrText, a.userLabel == b.userLabel, a.linkTitle == b.linkTitle else { return false }
        if let first = a.cachedDigest, let second = b.cachedDigest { return first == second }
        return a.parts == b.parts
    }
    static func changes(_ archive: Archive, from baseline: SyncSnapshot, at time: Double = Date().timeIntervalSince1970) -> SyncSnapshot {
        var next = SyncSnapshot(archive: archive, index: baseline.index)
        let previousClips = Dictionary(baseline.archive.clips.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let previousBoards = Dictionary(baseline.archive.boards.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(archive.clips.map { $0.id.uuidString }), boardIDs = Set(archive.boards.map { $0.id.uuidString })
        for clip in archive.clips {
            let id = clip.id.uuidString
            if let previous = previousClips[id], baseline.index.clips[id]?.deleted == false, equivalent(clip, previous) { continue }
            let signature = clipSignature(clip)
            if baseline.index.clips[id]?.signature != signature || baseline.index.clips[id]?.deleted == true { next.index.clips[id] = SyncRevision(time: max(time, (baseline.index.clips[id]?.time ?? 0) + 0.000001), deleted: false, signature: signature) }
        }
        for (id, revision) in baseline.index.clips where !revision.deleted && !ids.contains(id) { next.index.clips[id] = SyncRevision(time: max(time, revision.time + 0.000001), deleted: true, signature: "") }
        for board in archive.boards {
            let id = board.id.uuidString
            if let previous = previousBoards[id], baseline.index.boards[id]?.deleted == false, previous.name == board.name, previous.color == board.color { continue }
            let signature = boardSignature(board)
            if baseline.index.boards[id]?.signature != signature || baseline.index.boards[id]?.deleted == true { next.index.boards[id] = SyncRevision(time: max(time, (baseline.index.boards[id]?.time ?? 0) + 0.000001), deleted: false, signature: signature) }
        }
        for (id, revision) in baseline.index.boards where !revision.deleted && !boardIDs.contains(id) { next.index.boards[id] = SyncRevision(time: max(time, revision.time + 0.000001), deleted: true, signature: "") }
        return next
    }
    static func load(_ root: URL) throws -> SyncSnapshot {
        try load(root, manifestFiles: manifests(root))
    }
    private static func loadLegacy(_ root: URL, readiness: ReadinessCheck, observed: DirectoryTargetHistory? = nil,
                                   cloudAttachments: Bool? = nil) throws -> SyncSnapshot {
        let url = root.appendingPathComponent("history.json")
        for _ in 0..<2 {
            if observed != nil, try fileInfo(url) != nil || fileInfo(downloadPlaceholder(for: url)) != nil { observed?.indexes.insert(url) }
            try readiness(url)
            if try fileInfo(url) != nil {
                observed?.indexes.insert(url)
                return try baseline(HistoryStorage.read(from: url, readiness: readiness, checkCloudAttachments: cloudAttachments))
            }
        }
        guard observed?.indexes.contains(url) != true else { throw PasteImport.failure("目标历史清单已不可读，请重新选择目录") }
        try readiness(root)
        guard try fileInfo(root, followingSymlinks: true) != nil else { throw PasteImport.failure("无法读取数据目录") }
        try readiness(root.appendingPathComponent("blobs", isDirectory: true))
        return baseline(Archive())
    }
    static func load(_ root: URL, manifestFiles files: [URL], readiness: ReadinessCheck = DataDirectory.ready,
                     requireListedFiles: Bool = false, cloudAttachments: Bool? = nil) throws -> SyncSnapshot {
        if files.isEmpty {
            return try loadLegacy(root, readiness: readiness, cloudAttachments: cloudAttachments)
        }
        var pendingItems = Set<String>()
        func check(_ url: URL) throws {
            if pendingItems.contains(url.path) { throw ICloudDownloadPending() }
            do { try checkedDownloadRead { try readiness(url) } }
            catch let error as ICloudDownloadPending {
                pendingItems.insert(url.path)
                throw error
            }
        }
        let readable = try files.filter { file in
            do {
                try check(file)
                if requireListedFiles, try fileInfo(file) == nil {
                    try check(file)
                    guard try fileInfo(file) != nil else { throw PasteImport.failure("目标历史清单已不可读，请重新选择目录") }
                }
                return true
            }
            catch is ICloudDownloadPending { return false }
        }
        var pending = readable.count != files.count
        var snapshot = baseline(Archive())
        for file in readable {
            do {
                let other = try coordinated(file, writing: false) { path -> SyncSnapshot in
                    let archive = try HistoryStorage.read(from: path, readiness: check, checkCloudAttachments: cloudAttachments)
                    if file.lastPathComponent == "history.json" { return baseline(archive) }
                    return SyncSnapshot(archive: archive, index: try HistoryStorage.syncIndex(from: path) ?? baseline(archive).index)
                }
                snapshot = merge(snapshot, other)
            } catch is ICloudDownloadPending { pending = true }
            catch let error {
                // The item can be evicted between preflight and file coordination.
                if isTemporaryDownloadError(error) { pending = true; continue }
                guard isMissingFile(error) else { throw error }
                do { try check(file) }
                catch is ICloudDownloadPending { pending = true; continue }
                throw error
            }
            // iCloud may retain a conflicting version when a device identity was cloned.
            guard file.lastPathComponent != "history.json" else { continue }
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? [] {
                do {
                    let archive = try HistoryStorage.read(from: version.url, contentRoot: root, readiness: check, checkCloudAttachments: cloudAttachments)
                    snapshot = merge(snapshot, SyncSnapshot(archive: archive, index: try HistoryStorage.syncIndex(from: version.url) ?? baseline(archive).index))
                } catch is ICloudDownloadPending { pending = true }
                catch { if isTemporaryDownloadError(error) { pending = true } else { throw error } }
            }
        }
        if pending { throw ICloudDownloadPending() }
        return snapshot
    }
    private static func checkedDownloadRead<T>(_ read: () throws -> T) throws -> T {
        do { return try read() }
        catch {
            if isTemporaryDownloadError(error) { throw ICloudDownloadPending() }
            throw error
        }
    }
    fileprivate static func loadTarget(_ root: URL, cloud: Bool, readiness: ReadinessCheck, observed: DirectoryTargetHistory? = nil,
                                       manifestEnumerator: ((URL) throws -> [URL])? = nil, verifyStable: Bool = false) throws -> DirectoryTarget {
        do { try checkedDownloadRead { try readyDirectory(root, readiness: readiness) } }
        catch is ICloudDownloadPending {
            observed?.existed = true
            throw ICloudDownloadPending()
        }
        guard let info = try fileInfo(root, followingSymlinks: true) else {
            if cloud || observed?.existed == true {
                try checkedDownloadRead { try readiness(root) }
                throw PasteImport.failure("无法读取目标目录，请重新选择")
            }
            return DirectoryTarget(snapshot: baseline(Archive()), hasDeviceManifests: false, exists: false, stamp: nil, watchesLegacy: true)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw PasteImport.failure("目标路径不是文件夹") }
        observed?.existed = true
        let legacyWasObserved = observed?.indexes.contains { $0.lastPathComponent == "history.json" } == true
        let files = try checkedDownloadRead {
            try manifestEnumerator?(root) ?? manifests(root, readiness: readiness, includeLegacy: true,
                                                       includeLegacyAlongsideDevices: legacyWasObserved)
        }
        observed?.indexes.formUnion(files)
        let indexes = (observed?.indexes ?? Set(files)).sorted { $0.path < $1.path }
        let hasDeviceManifests = indexes.contains { $0.lastPathComponent != "history.json" }
        let watchesLegacy = !hasDeviceManifests || indexes.contains { $0.lastPathComponent == "history.json" }
        let before = verifyStable ? try checkedDownloadRead { try stamp(files) } : nil
        let snapshot = try checkedDownloadRead {
            if indexes.isEmpty {
                return try loadLegacy(root, readiness: readiness, observed: observed, cloudAttachments: cloud ? true : nil)
            }
            return try load(root, manifestFiles: indexes, readiness: readiness, requireListedFiles: true, cloudAttachments: cloud ? true : nil)
        }
        try checkedDownloadRead { try readiness(root.appendingPathComponent("blobs", isDirectory: true)) }
        if let before {
            let current = try migrationStamp(root, readiness: readiness, watchesLegacy: watchesLegacy, observed: observed)
            if current != before { throw DirectoryTargetChanged() }
        }
        return DirectoryTarget(snapshot: snapshot, hasDeviceManifests: hasDeviceManifests, exists: true, stamp: before, watchesLegacy: watchesLegacy)
    }
    private static func migrationStamp(_ root: URL, readiness: ReadinessCheck, watchesLegacy: Bool, observed: DirectoryTargetHistory?) throws -> String {
        try checkedDownloadRead {
            let files = try manifests(root, readiness: readiness, includeLegacy: watchesLegacy, includeLegacyAlongsideDevices: watchesLegacy)
            observed?.indexes.formUnion(files)
            var pending = false
            for file in files {
                do { try checkedDownloadRead { try readiness(file) } }
                catch is ICloudDownloadPending { pending = true }
            }
            if pending { throw ICloudDownloadPending() }
            try readiness(root.appendingPathComponent("blobs", isDirectory: true))
            return try stamp(files)
        }
    }
    static func loadRecoveryTarget(_ root: URL, cloud: Bool? = nil, readiness: ReadinessCheck = DataDirectory.ready) throws -> SyncSnapshot {
        try recoverySnapshot(root, cloud: cloud ?? isCloud(root), readiness: readiness).0
    }
    fileprivate static func recoverySnapshot(_ root: URL, cloud: Bool, readiness: ReadinessCheck, observed: DirectoryTargetHistory? = nil) throws -> (SyncSnapshot, Bool) {
        let target = try loadTarget(root, cloud: cloud, readiness: readiness, observed: observed)
        let shared = cloud || target.hasDeviceManifests
        if let cached = try cached(root) { return (merge(target.snapshot, cached), shared) }
        return (target.snapshot, shared)
    }
    static func write(_ snapshot: SyncSnapshot, root: URL, device: String, progress: ((ImportProgress) -> Void)? = nil) throws {
        let url = root.appendingPathComponent("device-\(device).json")
        try coordinated(url, writing: true) { path in try HistoryStorage.write(snapshot.archive, to: path, phase: "保存同步历史", progress: progress, sync: snapshot.index) }
    }
    static func validateDestination(_ destination: URL, from source: URL, environment: AppEnvironment) throws -> URL {
        let source = try environment.validateDataRoot(source).standardizedFileURL.resolvingSymlinksInPath()
        let destination = try environment.validateDataRoot(destination).standardizedFileURL.resolvingSymlinksInPath()
        guard destination.path != source.path, !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/") else { throw PasteImport.failure("请选择独立的数据文件夹，不能使用当前目录或它的上级、子目录") }
        return destination
    }
    static func migrate(_ archive: Archive, from source: URL, to destination: URL, device: @autoclosure () -> String, environment: AppEnvironment = .current, destinationIsCloud: Bool? = nil, readiness: ReadinessCheck = DataDirectory.ready, manifestEnumerator: ((URL) throws -> [URL])? = nil, progress: ((ImportProgress) -> Void)? = nil) throws -> SyncSnapshot {
        try migrateSnapshot(archive, from: source, to: destination, device: device, environment: environment, destinationIsCloud: destinationIsCloud,
                            readiness: readiness, manifestEnumerator: manifestEnumerator, progress: progress).0
    }
    fileprivate static func migrateSnapshot(_ archive: Archive, from source: URL, to destination: URL, device: () -> String, environment: AppEnvironment, destinationIsCloud: Bool?, readiness: ReadinessCheck, observed: DirectoryTargetHistory? = nil, manifestEnumerator: ((URL) throws -> [URL])? = nil, progress: ((ImportProgress) -> Void)?) throws -> (SyncSnapshot, Bool) {
        let destination = try validateDestination(destination, from: source, environment: environment)
        let cloudDestination = destinationIsCloud ?? isCloud(destination)
        var target = try loadTarget(destination, cloud: cloudDestination, readiness: readiness, observed: observed,
                                    manifestEnumerator: manifestEnumerator, verifyStable: true)
        var existing = target.snapshot
        let shared = cloudDestination || target.hasDeviceManifests
        if shared, let cached = try cached(destination) { existing = merge(existing, cached) }
        if !target.exists {
            try readyDirectory(destination, readiness: readiness)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            target = try loadTarget(destination, cloud: cloudDestination, readiness: readiness, observed: observed, verifyStable: true)
            guard target.stamp == "" else {
                throw DirectoryTargetChanged()
            }
        }
        _ = try environment.validateDataRoot(destination)
        let local = changes(archive, from: baseline(Archive()))
        let merged = merge(existing, local)
        // The source remains a complete backup; also snapshot destination before changing it.
        let history = destination.appendingPathComponent("history.json")
        let backup = destination.appendingPathComponent("before-directory-change-\(UUID()).json")
        let stagingManifest = destination.appendingPathComponent("migration-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: stagingManifest) }
        try HistoryStorage.write(merged.archive, to: stagingManifest, phase: "迁移历史与附件", progress: progress, sync: merged.index)
        let verified = try checkedDownloadRead { try HistoryStorage.read(from: stagingManifest, readiness: readiness) }
        guard verified.clips.count == merged.archive.clips.count else { throw PasteImport.failure("迁移校验失败") }
        if target.hasDeviceManifests {
            try HistoryStorage.write(existing.archive, to: backup, phase: "备份目标历史", progress: progress, sync: existing.index)
        } else if target.stamp != "" {
            try checkedDownloadRead {
                try readiness(history)
                do { try FileManager.default.copyItem(at: history, to: backup) }
                catch {
                    try readiness(history)
                    throw error
                }
            }
        }
        let currentStamp = try migrationStamp(destination, readiness: readiness, watchesLegacy: target.watchesLegacy, observed: observed)
        guard currentStamp == target.stamp else { throw DirectoryTargetChanged() }
        if shared { try write(merged, root: destination, device: device()); try cache(merged, root: destination) }
        else { try coordinated(history, writing: true) { path in try HistoryStorage.write(merged.archive, to: path) } }
        return (SyncSnapshot(archive: verified, index: merged.index), shared)
    }
}

private struct DirectoryChange {
    let id = UUID()
    let source: URL
    let destination: URL
    let environment: AppEnvironment
    let requiresICloud: Bool
    let readiness: DataDirectory.ReadinessCheck
    let willReadForMigration: (() throws -> Void)?
    let queue = DispatchQueue(label: "openpaste.directory-check", qos: .utility)
    let targetHistory = DirectoryTargetHistory()
}

extension Store {
    var storageDescription: String { isICloudDirectory ? "由 iCloud Drive 同步" : "保存在所选目录" }
    func chooseICloudDirectory() {
        guard !directoryChangeInProgress, !importingPaste, !ephemeral else { return }
        guard !AppEnvironment.current.acceptanceMode else {
            directoryStatus = "切换失败：当前验收配置只能使用隔离的本机目录。"
            return
        }
        let cloudRoot = DataDirectory.iCloudDriveRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let available = FileManager.default.ubiquityIdentityToken != nil &&
                FileManager.default.fileExists(atPath: cloudRoot.path)
            DispatchQueue.main.async {
                guard !self.directoryChangeInProgress, !self.importingPaste else { return }
                guard available else {
                    self.directoryStatus = "切换失败：iCloud Drive 不可用。请在系统设置登录 Apple 账户并开启 iCloud Drive 后重试。"
                    return
                }
                self.presentDataDirectoryPicker(startingAt: cloudRoot, requiresICloud: true)
            }
        }
    }
    func chooseDataDirectory() { presentDataDirectoryPicker(startingAt: root, requiresICloud: false) }
    private func presentDataDirectoryPicker(startingAt initialDirectory: URL, requiresICloud: Bool) {
        guard !directoryChangeInProgress, !importingPaste else { return }
        guard let parent = Controller.shared.settingsWindow, parent.attachedSheet == nil else { return }
        let picker = NSOpenPanel()
        picker.title = requiresICloud ? "选择 iCloud Drive 中的专用文件夹" : "选择历史数据目录"
        picker.prompt = "使用此目录"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false; picker.directoryURL = initialDirectory
        picker.beginSheetModal(for: parent) { response in
            if response == .OK, let url = picker.url { self.changeDataDirectory(to: url, requiresICloud: requiresICloud) }
        }
    }
    func changeDataDirectory(to destination: URL, environment: AppEnvironment = .current, requiresICloud: Bool = false,
                             readiness: @escaping DataDirectory.ReadinessCheck = DataDirectory.ready,
                             willReadForMigration: (() throws -> Void)? = nil) {
        guard !ephemeral, !initialLoading, !directoryChangeInProgress, !importingPaste else { return }
        let change = DirectoryChange(source: root, destination: destination, environment: environment,
                                     requiresICloud: requiresICloud, readiness: readiness, willReadForMigration: willReadForMigration)
        directoryChangeID = change.id
        directoryStatus = "正在检查所选目录，继续使用原目录…"
        checkDirectoryChange(change)
    }
    func cancelDataDirectoryChange() {
        guard canCancelDirectoryChange else { return }
        directoryChangeID = nil
        directoryStatus = "已取消切换，继续使用原目录。"
    }
    private func isCurrent(_ change: DirectoryChange) -> Bool {
        directoryChangeID == change.id && root == change.source
    }
    private func checkDirectoryChange(_ change: DirectoryChange, retryDelay: TimeInterval = 1) {
        change.queue.async { [weak self] in
            let result = Result { () throws -> (URL, Bool) in
                let target = try DataDirectory.validateDestination(change.destination, from: change.source, environment: change.environment)
                let cloud = DataDirectory.isCloud(target)
                if change.requiresICloud && (!cloud || target.path == DataDirectory.iCloudDriveRoot.path) {
                    throw PasteImport.failure("请选择 iCloud Drive 中专用于剪贴板历史的子文件夹")
                }
                _ = try DataDirectory.loadTarget(target, cloud: cloud, readiness: change.readiness, observed: change.targetHistory)
                return (target, cloud)
            }
            DispatchQueue.main.async {
                guard let self, self.isCurrent(change) else { return }
                switch result {
                case .success(let (target, cloud)):
                    self.prepareDirectoryMigration(change, target: target, cloud: cloud, retryDelay: retryDelay)
                case .failure(is ICloudDownloadPending):
                    self.waitForDirectoryDownload(change, delay: retryDelay)
                case .failure(let error):
                    self.directoryChangeID = nil
                    self.directoryStatus = "切换失败：\(error.localizedDescription)。仍使用原目录。"
                }
            }
        }
    }
    private func waitForDirectoryDownload(_ change: DirectoryChange, delay: TimeInterval) {
        let status = "iCloud 内容正在下载，完成后将自动切换。当前继续使用原目录。"
        if directoryStatus != status { directoryStatus = status }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCurrent(change) else { return }
            self.checkDirectoryChange(change, retryDelay: min(delay * 2, 15))
        }
    }
    private func resumeAfterDirectoryMigration(recovering: Bool) {
        directoryProgress = ImportProgress(phase: "", completed: 0, total: 0)
        changingDataDirectory = false
        endTemporaryPause()
        if !recovering { save() }
    }
    private func prepareDirectoryMigration(_ change: DirectoryChange, target: URL, cloud: Bool, retryDelay: TimeInterval) {
        guard !initialLoading, !changingDataDirectory, !importingPaste, !savePending, !syncChecking else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.isCurrent(change) else { return }
                self.prepareDirectoryMigration(change, target: target, cloud: cloud, retryDelay: retryDelay)
            }
            return
        }
        let recoveringFromLoadFailure = hasHistoryLoadFailure
        // Finish capture while recording still has its previous state; then freeze migration.
        captureQueue.sync {}
        finishDirectoryCapture()
        // A save queued while finishing capture still needs to reach the original directory.
        invalidatePendingStorageCallbacks(keepingQueuedSave: true)
        let operationGeneration = directoryMutation
        changingDataDirectory = true
        beginTemporaryPause()
        directoryStatus = recoveringFromLoadFailure ? "正在读取目标目录，损坏的原目录不会迁移…" : "正在迁移，原目录会保留…"
        directoryProgress = ImportProgress(phase: recoveringFromLoadFailure ? "读取目标目录" : "准备迁移", completed: 0, total: recoveringFromLoadFailure ? 0 : archive.clips.count)
        let snapshot = archive
        persistenceQueue.async {
            let result = Result { () throws -> (SyncSnapshot, Bool) in
                try change.willReadForMigration?()
                if recoveringFromLoadFailure {
                    let validated = try DataDirectory.validateDestination(target, from: change.source, environment: change.environment)
                    return try DataDirectory.recoverySnapshot(validated, cloud: cloud, readiness: change.readiness, observed: change.targetHistory)
                }
                return try DataDirectory.migrateSnapshot(snapshot, from: change.source, to: target, device: self.deviceIDForPersistence,
                                                         environment: change.environment, destinationIsCloud: cloud, readiness: change.readiness,
                                                         observed: change.targetHistory, progress: { progress in
                    DispatchQueue.main.async {
                        guard self.isCurrent(change),
                              self.directoryMutation == operationGeneration,
                              self.changingDataDirectory else { return }
                        self.directoryProgress = progress
                    }
                })
            }
            DispatchQueue.main.async {
                guard self.isCurrent(change),
                      self.directoryMutation == operationGeneration,
                      self.changingDataDirectory else { return }
                var completedRecovery = false
                switch result {
                case .success(let (migrated, destinationIsShared)):
                    self.root = target.standardizedFileURL
                    self.isICloudDirectory = cloud
                    self.usesSharedDirectory = destinationIsShared
                    self.syncBaseline = migrated
                    self.syncStamp = nil
                    self.directorySyncStatus = ""
                    self.setDirectorySyncChecked()
                    if recoveringFromLoadFailure { self.installLoadedArchive(migrated.archive) }
                    else { self.installImportedArchive(migrated.archive) }
                    self.persistSelectedDataRoot()
                    self.initialDirectoryLoadFailed = false
                    self.directoryStatus = recoveringFromLoadFailure ? "目录已切换，原目录保留。请在修复后读取原历史。" : "目录已切换，原目录保留为备份。"
                    self.message = self.storageDescription
                    self.setRecordingLoadFailure(nil)
                    self.setRecordingSaveFailure(nil)
                    completedRecovery = recoveringFromLoadFailure
                case .failure(is ICloudDownloadPending):
                    self.resumeAfterDirectoryMigration(recovering: recoveringFromLoadFailure)
                    self.waitForDirectoryDownload(change, delay: retryDelay)
                    return
                case .failure(is DirectoryTargetChanged):
                    self.resumeAfterDirectoryMigration(recovering: recoveringFromLoadFailure)
                    self.directoryStatus = "目标目录有更新，正在重新检查。当前继续使用原目录。"
                    self.checkDirectoryChange(change, retryDelay: retryDelay)
                    return
                case .failure(let error): self.directoryStatus = "切换失败：\(error.localizedDescription)。仍使用原目录。"
                }
                self.directoryChangeID = nil
                self.changingDataDirectory = false; self.endTemporaryPause()
                if completedRecovery { self.resumeDeferredInitialStart() }
                else if !recoveringFromLoadFailure { self.save() }
            }
        }
    }
    func pollDirectory(force: Bool = false, usesSync: @escaping (URL) -> Bool = DataDirectory.usesSync) {
        guard !ephemeral, !recordingSafetyPaused, !changingDataDirectory, !importingPaste, !syncChecking, !savePending else { return }
        syncChecking = true
        if isICloudDirectory { directorySyncInProgress = true }
        let folder = root, local = syncBaseline, generation = directoryMutation
        let previousStamp = syncStamp, retry = needsDirectorySync
        persistenceQueue.async {
            let result = Result { () throws -> (SyncSnapshot, String, Bool)? in
                guard usesSync(folder) else { return nil }
                let files = try DataDirectory.manifests(folder)
                let stamp = try DataDirectory.stamp(folder, manifestFiles: files)
                if stamp == previousStamp && !retry && !force { return nil }
                let remote = try DataDirectory.load(folder, manifestFiles: files)
                let merged = try self.cacheSyncedSnapshot(DataDirectory.merge(remote, local), at: folder)
                if merged.index != remote.index { try DataDirectory.write(merged, root: folder, device: self.deviceIDForPersistence()) }
                // Remember the listing from before the read. A manifest arriving
                // during this pass still needs to be checked by the next poll.
                return (merged, stamp, merged.index != local.index)
            }
            DispatchQueue.main.async {
                defer {
                    self.syncChecking = false
                    if self.directorySyncInProgress { self.directorySyncInProgress = false }
                }
                guard self.root == folder, !self.changingDataDirectory, !self.importingPaste,
                      self.directoryMutation == generation else { return }
                switch result {
                case .success(let update):
                    if let (snapshot, stamp, historyChanged) = update {
                        self.usesSharedDirectory = true
                        self.installSyncedSnapshot(snapshot, updateArchive: historyChanged)
                        self.syncStamp = stamp
                        self.setDirectorySyncChecked()
                    }
                case .failure(let error):
                    self.setDirectorySyncWaiting(error)
                }
            }
        }
    }
}

#if OPENPASTE_TESTING
func runDataDirectoryTests() {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("OpenPaste-directory-tests-\(UUID())")
    defer { try? fm.removeItem(at: sandbox) }
    var passed = 0
    func check(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL: \(label)"); exit(1) }
        passed += 1; print("PASS: \(label)")
    }
    func clip(_ text: String) -> Clip { Clip(source: "Fixture", sourceID: "test.fixture", kind: "文字", title: text, text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]]) }
    do {
        let source = sandbox.appendingPathComponent("original"), destination = sandbox.appendingPathComponent("chosen")
        let a = clip("源目录内容"), b = clip("目标目录已有内容")
        try HistoryStorage.write(Archive(clips: [a]), to: source.appendingPathComponent("history.json"))
        try HistoryStorage.write(Archive(clips: [b]), to: destination.appendingPathComponent("history.json"))
        let migrated = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: destination, device: "A")
        check(migrated.archive.clips.count == 2, "迁移合并目标目录已有历史")
        check(try HistoryStorage.read(from: source.appendingPathComponent("history.json")).clips.count == 1, "源目录完整保留")
        check(try DataDirectory.load(destination).archive.clips.count == 2, "重新加载迁移目录")
        check(try fm.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix("before-directory-change-") }, "目标原索引已备份")
        check(migrated.archive.clips.first { $0.id == a.id }?.parts.first?.first?.data == Data(a.text.utf8), "附件内容校验")
        do { _ = try DataDirectory.migrate(migrated.archive, from: source, to: source.appendingPathComponent("nested"), device: "A"); check(false, "拒绝嵌套目录") } catch { check(true, "拒绝嵌套目录") }
        let broken = sandbox.appendingPathComponent("broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(to: broken.appendingPathComponent("history.json"))
        do { _ = try DataDirectory.migrate(migrated.archive, from: source, to: broken, device: "A"); check(false, "失败不切换") } catch { check(try HistoryStorage.read(from: source.appendingPathComponent("history.json")).clips.count == 1, "目标损坏时原历史仍完好") }
        let enumerationFailureTarget = sandbox.appendingPathComponent("enumeration-failure")
        let enumerationTargetClip = clip("枚举失败时必须保留")
        let enumerationManifest = enumerationFailureTarget.appendingPathComponent("history.json")
        try HistoryStorage.write(Archive(clips: [enumerationTargetClip]), to: enumerationManifest)
        let enumerationFilesBefore = try fm.subpathsOfDirectory(atPath: enumerationFailureTarget.path).sorted()
        let enumerationManifestHash = HistoryStorage.digest(try Data(contentsOf: enumerationManifest))
        do {
            _ = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: enumerationFailureTarget, device: "A", manifestEnumerator: { _ in
                throw PasteImport.failure("fixture manifest enumeration failed")
            })
            check(false, "缓存判定枚举错误必须抛出")
        } catch {
            check(error.localizedDescription.contains("fixture manifest enumeration failed"), "缓存判定不吞瞬时枚举错误")
        }
        let enumerationFilesAfter = try fm.subpathsOfDirectory(atPath: enumerationFailureTarget.path).sorted()
        let enumerationManifestHashAfter = HistoryStorage.digest(try Data(contentsOf: enumerationManifest))
        check(enumerationManifestHashAfter == enumerationManifestHash && enumerationFilesAfter == enumerationFilesBefore,
              "枚举错误发生在写入前且保留目标目录原文件")
        let shared = sandbox.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let empty = DataDirectory.baseline(Archive())
        let board = Board(name: "收藏", color: "blue")
        var pinned = a; pinned.boards = [board.id]
        let deviceA = DataDirectory.changes(Archive(clips: [pinned], boards: [board]), from: empty, at: 10)
        let deviceB = DataDirectory.changes(Archive(clips: [b]), from: empty, at: 11)
        try DataDirectory.write(deviceA, root: shared, device: "A")
        try DataDirectory.write(deviceB, root: shared, device: "B")
        let both = try DataDirectory.load(shared)
        check(both.archive.clips.count == 2 && both.archive.boards.count == 1, "两台设备独立索引合并历史与收藏")
        let cacheMergeTarget = sandbox.appendingPathComponent("migration-cache-merge")
        let cacheTargetClip = clip("目标同步历史")
        let cachedTargetClip = clip("目标缓存历史")
        try DataDirectory.write(DataDirectory.changes(Archive(clips: [cacheTargetClip]), from: empty, at: 12), root: cacheMergeTarget, device: "target")
        try DataDirectory.cache(DataDirectory.changes(Archive(clips: [cachedTargetClip]), from: empty, at: 13), root: cacheMergeTarget)
        defer { try? fm.removeItem(at: DataDirectory.cacheURL(cacheMergeTarget).deletingLastPathComponent()) }
        let cacheMergedMigration = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: cacheMergeTarget, device: "migrating")
        check(Set(cacheMergedMigration.archive.clips.map(\.id)) == Set([a.id, cacheTargetClip.id, cachedTargetClip.id]),
              "迁移保留并合并目标同步历史与本地缓存")
        let deleted = DataDirectory.changes(Archive(clips: [b], boards: []), from: both, at: 20)
        try DataDirectory.write(deleted, root: shared, device: "A")
        let afterDelete = try DataDirectory.load(shared)
        check(afterDelete.archive.clips.map(\.id) == [b.id] && afterDelete.archive.boards.isEmpty, "删除标记阻止旧设备恢复已删内容")
        let staleNew = clip("离线新增")
        var staleArchive = both.archive; staleArchive.clips.append(staleNew)
        let stale = DataDirectory.changes(staleArchive, from: both, at: 21)
        try DataDirectory.write(stale, root: shared, device: "B")
        let offline = try DataDirectory.load(shared)
        check(Set(offline.archive.clips.map(\.id)) == Set([b.id, staleNew.id]), "离线新增保留，同时不复活已删除条目")
        let undone = DataDirectory.changes(Archive(clips: [a, b, staleNew]), from: offline, at: 30)
        try DataDirectory.write(undone, root: shared, device: "A")
        check(try DataDirectory.load(shared).archive.clips.count == 3, "显式撤销可重新恢复条目")
        var edited = b; edited.text = "修改后的内容"; edited.userLabel = "重命名"
        let newer = DataDirectory.changes(Archive(clips: [edited, a, staleNew]), from: try DataDirectory.load(shared), at: 40)
        try DataDirectory.write(newer, root: shared, device: "B")
        check(try DataDirectory.load(shared).archive.clips.first { $0.id == b.id }?.userLabel == "重命名", "编辑与重命名传播")
        check(DataDirectory.merge(deviceA, deviceB).index.clips == DataDirectory.merge(deviceB, deviceA).index.clips, "合并顺序不影响结果")
        let live = Store(root: shared)
        let rapid = clip("快速复制再删除")
        live.ingest(rapid); live.delete(rapid.id); live.flush()
        check(try DataDirectory.load(shared).archive.clips.allSatisfy { $0.id != rapid.id }, "连续保存与快速删除不会复活条目")
        let cachedHistory = try DataDirectory.cached(shared)
        check(cachedHistory?.index.clips[rapid.id.uuidString]?.deleted == true, "离线缓存保留尚待上传的删除标记")
        let offlineRoot = sandbox.appendingPathComponent("offline-cache")
        let offlineOriginal = clip("离线之前已有的内容")
        try DataDirectory.write(DataDirectory.baseline(Archive(clips: [offlineOriginal])), root: offlineRoot, device: "remote")
        let cacheFolder = DataDirectory.cacheURL(offlineRoot).deletingLastPathComponent()
        defer { try? fm.removeItem(at: cacheFolder) }
        let offlineStore = Store(root: offlineRoot)
        let unavailableBlob = offlineRoot.appendingPathComponent("blobs").appendingPathComponent(HistoryStorage.digest(offlineOriginal.parts[0][0].data))
        let originalBlob = try Data(contentsOf: unavailableBlob)
        try fm.removeItem(at: unavailableBlob)
        let offlineClip = clip("iCloud 不可读期间保存在本机")
        offlineStore.ingest(offlineClip)
        offlineStore.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(offlineStore.needsDirectorySync && !offlineStore.recordingSafetyPaused, "本机缓存提交后，远端读取失败只延迟同步")
        let reopenedOffline = Store(root: offlineRoot)
        check(reopenedOffline.canModifyHistory && reopenedOffline.needsDirectorySync && reopenedOffline.archive.clips.contains { $0.id == offlineClip.id },
              "远端持续不可读时重启，加载完整本机缓存并允许继续记录")
        try originalBlob.write(to: unavailableBlob, options: .atomic)
        reopenedOffline.retryDirectorySync()
        reopenedOffline.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let recoveredOffline = try DataDirectory.load(offlineRoot)
        check(!reopenedOffline.needsDirectorySync && recoveredOffline.archive.clips.contains { $0.id == offlineClip.id },
              "重新读取远端后，手动重试会发布本机缓存中的离线内容")
        let brokenCacheRoot = sandbox.appendingPathComponent("broken-cache")
        try DataDirectory.write(DataDirectory.baseline(Archive(clips: [offlineOriginal])), root: brokenCacheRoot, device: "remote")
        let brokenCacheFolder = DataDirectory.cacheURL(brokenCacheRoot).deletingLastPathComponent()
        defer { try? fm.removeItem(at: brokenCacheFolder) }
        try Data().write(to: brokenCacheFolder)
        let brokenCacheStore = Store(root: brokenCacheRoot)
        let blockedClip = clip("本机缓存失败时保留在内存中")
        brokenCacheStore.ingest(blockedClip)
        brokenCacheStore.pollDirectory()
        check(!brokenCacheStore.syncChecking, "未完成的本机保存先于轮询，远端结果不会覆盖内存变更")
        brokenCacheStore.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(brokenCacheStore.recordingSafetyPaused && brokenCacheStore.archive.clips.contains { $0.id == blockedClip.id },
              "本机缓存写入失败仍暂停记录，并保留内存变更")
        try fm.removeItem(at: brokenCacheFolder)
        brokenCacheStore.pollDirectory()
        check(!brokenCacheStore.syncChecking, "本机缓存保存失败时，轮询须等待本机保存恢复")
        brokenCacheStore.retryDirectorySync()
        brokenCacheStore.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let recoveredCache = try DataDirectory.cached(brokenCacheRoot)
        check(!brokenCacheStore.recordingSafetyPaused && recoveredCache?.archive.clips.contains { $0.id == blockedClip.id } == true,
              "本机缓存恢复后重试保存，先持久化之前的内存变更")
        let legacyRoot = sandbox.appendingPathComponent("legacy-poll")
        let legacyManifest = legacyRoot.appendingPathComponent("history.json")
        try HistoryStorage.write(Archive(clips: [a]), to: legacyManifest)
        let legacyStore = Store(root: legacyRoot)
        let legacyStamp = try DataDirectory.stamp(legacyRoot, manifestFiles: [])
        check(!legacyStamp.isEmpty, "尚无设备清单时，轮询版本包含旧格式历史")
        try HistoryStorage.write(Archive(clips: [a, b]), to: legacyManifest)
        legacyStore.pollDirectory(usesSync: { _ in true })
        legacyStore.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        defer { try? fm.removeItem(at: DataDirectory.cacheURL(legacyRoot).deletingLastPathComponent()) }
        check(Set(legacyStore.archive.clips.map(\.id)) == Set([a.id, b.id]), "首次轮询读取旧格式历史中的新增内容")
        let localRoot = sandbox.appendingPathComponent("store-original"), newRoot = sandbox.appendingPathComponent("store-new")
        let migratingStore = Store(root: localRoot); migratingStore.ingest(clip("真实迁移工作流")); migratingStore.flush()
        migratingStore.changeDataDirectory(to: newRoot)
        var deadline = Date().addingTimeInterval(8)
        while migratingStore.directoryChangeInProgress && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        migratingStore.flush()
        check(migratingStore.root.path == newRoot.path && !migratingStore.directoryChangeInProgress, "Store 异步迁移后切换目录")
        check(Store(root: newRoot).archive.clips.count == 1, "Store 重启读取新目录")
        migratingStore.changeDataDirectory(to: broken)
        deadline = Date().addingTimeInterval(8)
        while migratingStore.directoryChangeInProgress && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        migratingStore.flush()
        check(migratingStore.root.path == newRoot.path && migratingStore.directoryStatus.hasPrefix("切换失败"), "Store 迁移失败恢复原目录与状态")
        let pollRoot = sandbox.appendingPathComponent("poll-local")
        let pollStore = Store(root: pollRoot)
        let pollStarted = DispatchSemaphore(value: 0), releasePoll = DispatchSemaphore(value: 0)
        let pollLock = NSLock()
        var pollCalls = 0, pollRanOffMain = true, coalescedProbeCalls = 0
        let pollContentsBefore = try fm.subpathsOfDirectory(atPath: pollRoot.path)
        let pollBegan = ProcessInfo.processInfo.systemUptime
        pollStore.pollDirectory(usesSync: { _ in
            pollLock.lock(); pollCalls += 1; pollRanOffMain = pollRanOffMain && !Thread.isMainThread; pollLock.unlock()
            pollStarted.signal(); releasePoll.wait()
            return false
        })
        check(ProcessInfo.processInfo.systemUptime - pollBegan < 0.05, "目录同步判定不阻塞主线程")
        check(pollStarted.wait(timeout: .now() + 1) == .success, "目录同步判定进入持久化后台队列")
        pollStore.pollDirectory(usesSync: { _ in pollLock.lock(); coalescedProbeCalls += 1; pollLock.unlock(); return false })
        releasePoll.signal()
        deadline = Date().addingTimeInterval(1)
        while pollStore.syncChecking && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        pollLock.lock(); let finalPollCalls = pollCalls, finalPollOffMain = pollRanOffMain, finalCoalescedCalls = coalescedProbeCalls; pollLock.unlock()
        check(finalPollCalls == 1 && finalPollOffMain && finalCoalescedCalls == 0 && !pollStore.syncChecking, "慢目录判定期间的重复轮询被合并且正确收尾")
        check(try fm.subpathsOfDirectory(atPath: pollRoot.path) == pollContentsBefore && pollStore.archive.clips.isEmpty, "普通目录轮询不进入同步读写分支")
        let acceptanceProfile = UUID()
        let acceptanceWorkingDirectory = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let acceptanceRoot = acceptanceWorkingDirectory.appendingPathComponent("build/acceptance/\(acceptanceProfile.uuidString)")
        defer { try? fm.removeItem(at: acceptanceRoot) }
        let acceptanceSuite = "io.github.SwallOwDili.OpenPaste.acceptance.\(acceptanceProfile.uuidString.lowercased())"
        let acceptanceEnvironment = try AppEnvironment.resolve(
            arguments: ["OpenPaste", AppEnvironment.acceptanceArgument, acceptanceProfile.uuidString],
            environment: [AppEnvironment.acceptanceRootVariable: acceptanceRoot.path],
            fileManager: fm,
            currentDirectory: acceptanceWorkingDirectory
        )
        defer { acceptanceEnvironment.defaults.removePersistentDomain(forName: acceptanceSuite) }
        let acceptanceSource = acceptanceEnvironment.defaultDataRoot
        let outsideAcceptance = sandbox.appendingPathComponent("outside-acceptance")
        let acceptanceStore = Store(root: acceptanceSource)
        acceptanceStore.changeDataDirectory(to: outsideAcceptance, environment: acceptanceEnvironment)
        deadline = Date().addingTimeInterval(2)
        while acceptanceStore.directoryChangeInProgress && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(acceptanceStore.root == acceptanceSource && !acceptanceStore.directoryChangeInProgress && acceptanceStore.directoryStatus.hasPrefix("切换失败"), "验收目录越界失败时不切换 Store 根目录")
        do {
            _ = try DataDirectory.migrate(Archive(), from: acceptanceSource, to: outsideAcceptance, device: "A", environment: acceptanceEnvironment)
            check(false, "迁移入口拒绝验收根目录外目标")
        } catch {
            check(!fm.fileExists(atPath: outsideAcceptance.path), "迁移越界在写入前失败")
        }
        defer { try? fm.removeItem(at: DataDirectory.cacheURL(shared).deletingLastPathComponent()) }
        let benchmark = Archive(clips: (0..<7500).map { clip("性能测试 \($0)") })
        let benchmarkBaseline = DataDirectory.baseline(benchmark)
        let began = Date()
        _ = DataDirectory.changes(benchmark, from: benchmarkBaseline)
        print(String(format: "7500 条索引比较耗时 %.3f 秒", Date().timeIntervalSince(began)))
        let manifest = shared.appendingPathComponent("device-A.json")
        check(try HistoryStorage.syncIndex(from: manifest)?.clips[a.id.uuidString] != nil, "同步索引可持久化")
        let id = HistoryStorage.digest(a.parts[0][0].data)
        try fm.removeItem(at: shared.appendingPathComponent("blobs").appendingPathComponent(id))
        do { _ = try DataDirectory.load(shared); check(false, "缺失附件阻止覆盖") } catch { check(fm.fileExists(atPath: manifest.path), "缺失附件阻止空历史覆盖") }

        func placeholder(_ item: URL) -> URL {
            item.deletingLastPathComponent().appendingPathComponent(".\(item.lastPathComponent).icloud")
        }
        func expectDownload(_ read: () throws -> Void, _ label: String) throws {
            do { try read(); check(false, label) }
            catch is ICloudDownloadPending { check(true, label) }
        }
        let pendingRoot = sandbox.appendingPathComponent("directory-placeholder")
        let rootStub = placeholder(pendingRoot)
        try Data().write(to: rootStub)
        let pendingRootReadiness: DataDirectory.ReadinessCheck = { try DataDirectory.ready($0, requestDownload: { _ in }) }
        try expectDownload({
            _ = try DataDirectory.loadRecoveryTarget(pendingRoot, readiness: pendingRootReadiness)
        }, "恢复目标识别整个数据目录占位文件")
        try expectDownload({
            _ = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: pendingRoot, device: "A", readiness: pendingRootReadiness)
        }, "迁移不会创建仍在下载的目标目录")
        check(fm.fileExists(atPath: rootStub.path) && !fm.fileExists(atPath: pendingRoot.path), "目标目录占位保持完好")
        try expectDownload({
            _ = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: pendingRoot.appendingPathComponent("child"), device: "A", readiness: pendingRootReadiness)
        }, "创建子目录前检查其尚未下载的父目录")
        try expectDownload({
            try DataDirectory.ready(pendingRoot) { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUnavailableError) }
        }, "其他设备尚未上传的占位仍处于等待状态")
        do {
            try DataDirectory.ready(pendingRoot) { _ in throw POSIXError(.EACCES) }
            check(false, "下载请求的权限错误必须终止切换")
        } catch let error as POSIXError {
            check(error.code == .EACCES, "下载请求的权限错误必须终止切换")
        }
        do {
            _ = try DataDirectory.loadRecoveryTarget(sandbox.appendingPathComponent("absent-cloud-target"), cloud: true)
            check(false, "消失的 iCloud 目录不能按空目录切换")
        } catch {
            check(!(error is ICloudDownloadPending) && error.localizedDescription.contains("无法读取目标目录"),
                  "无下载证据时消失的 iCloud 目录是明确失败")
        }

        let batchRoot = sandbox.appendingPathComponent("download-batch")
        let items = [clip("批量附件一"), clip("批量附件二"), clip("批量附件三")]
        try DataDirectory.write(DataDirectory.baseline(Archive(clips: Array(items.prefix(2)))), root: batchRoot, device: "ready-a")
        try DataDirectory.write(DataDirectory.baseline(Archive(clips: Array(items.suffix(1)))), root: batchRoot, device: "ready-b")
        let pendingManifests = ["pending-a", "pending-b"].map { batchRoot.appendingPathComponent("device-\($0).json") }
        for url in pendingManifests { try Data().write(to: placeholder(url)) }
        let blobsFolder = batchRoot.appendingPathComponent("blobs", isDirectory: true)
        let pendingBlobs = items.map { blobsFolder.appendingPathComponent(HistoryStorage.digest($0.parts[0][0].data)) }
        for url in pendingBlobs { try fm.moveItem(at: url, to: placeholder(url)) }
        var requests: [String] = []
        let captureDownloadRequest: DataDirectory.ReadinessCheck = { url in
            try DataDirectory.ready(url) { requests.append($0.path) }
        }
        try expectDownload({
            _ = try DataDirectory.load(batchRoot, manifestFiles: DataDirectory.manifests(batchRoot), readiness: captureDownloadRequest)
        }, "任一清单或附件待下载时不返回部分历史")
        check(requests.count == 5 && Set(requests) == Set((pendingManifests + pendingBlobs).map(\.path)),
              "同一轮请求所有已知设备清单及附件的下载")
        try fm.removeItem(at: placeholder(pendingBlobs[0]))
        do {
            _ = try DataDirectory.load(batchRoot, manifestFiles: DataDirectory.manifests(batchRoot), readiness: captureDownloadRequest)
            check(false, "有其他等待项时也不能掩盖无占位的缺失附件")
        } catch {
            check(!(error is ICloudDownloadPending) && error.localizedDescription.contains("历史内容文件缺失或损坏"),
                  "有其他等待项时也不能掩盖无占位的缺失附件")
        }
        let folderStub = placeholder(blobsFolder)
        try fm.moveItem(at: blobsFolder, to: folderStub)
        try expectDownload({
            _ = try HistoryStorage.read(from: batchRoot.appendingPathComponent("device-ready-a.json"), readiness: captureDownloadRequest)
        }, "附件目录占位不会当成附件损坏或空历史")
        try expectDownload({
            _ = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: batchRoot, device: "A", readiness: captureDownloadRequest)
        }, "迁移不会创建仍在下载的附件目录")
        check(!fm.fileExists(atPath: blobsFolder.path), "迁移等待期间不会覆盖附件目录占位")

        let materializingRoot = sandbox.appendingPathComponent("materializing")
        try fm.createDirectory(at: materializingRoot, withIntermediateDirectories: true)
        let materializingManifest = materializingRoot.appendingPathComponent("device-remote.json")
        let materializingStub = placeholder(materializingManifest)
        try Data().write(to: materializingStub)
        let materializingFiles = try DataDirectory.manifests(materializingRoot)
        let materialized = try DataDirectory.load(materializingRoot, manifestFiles: materializingFiles, readiness: { url in
            try DataDirectory.ready(url) { url in
                guard url == materializingManifest else { throw PasteImport.failure("unexpected fixture download") }
                try DataDirectory.write(DataDirectory.baseline(Archive(clips: [b])), root: materializingRoot, device: "remote")
                try fm.removeItem(at: materializingStub)
                throw CocoaError(.fileReadNoSuchFile)
            }
        })
        check(materialized.archive.clips.map(\.id) == [b.id], "枚举占位、读取前转正的清单仍会完整合并")
        try Data().write(to: materializingStub)
        check(try DataDirectory.manifests(materializingRoot).map(\.path) == [materializingManifest.path],
              "同批枚举的占位和实际清单只计一次")

        let emptyTargetWithBlobStub = sandbox.appendingPathComponent("empty-index-pending-blobs")
        try fm.createDirectory(at: emptyTargetWithBlobStub, withIntermediateDirectories: true)
        try Data().write(to: placeholder(emptyTargetWithBlobStub.appendingPathComponent("blobs", isDirectory: true)))
        try expectDownload({
            _ = try DataDirectory.loadRecoveryTarget(emptyTargetWithBlobStub, readiness: pendingRootReadiness)
        }, "没有索引时也识别附件目录的占位")

        let compatibilityTarget = sandbox.appendingPathComponent("legacy-migration")
        try fm.createDirectory(at: compatibilityTarget, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(clips: [b])).write(to: compatibilityTarget.appendingPathComponent("history.json"))
        let compatibilityMigration = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: compatibilityTarget, device: "A")
        check(Set(compatibilityMigration.archive.clips.map(\.id)) == Set([a.id, b.id]), "目录切换兼容内嵌附件的旧格式索引")

        for name in ["device-remote.json", "history.json"] {
            let disappearing = sandbox.appendingPathComponent("temporarily-missing-\(name)")
            let listed = disappearing.appendingPathComponent(name)
            try HistoryStorage.write(Archive(clips: [b]), to: listed, sync: DataDirectory.baseline(Archive(clips: [b])).index)
            let observed = DirectoryTargetHistory()
            _ = try DataDirectory.loadTarget(disappearing, cloud: false, readiness: DataDirectory.ready, observed: observed)
            try fm.removeItem(at: listed)
            do {
                _ = try DataDirectory.migrateSnapshot(Archive(clips: [a]), from: source, to: disappearing, device: { "A" },
                                                     environment: .current, destinationIsCloud: false, readiness: DataDirectory.ready,
                                                     observed: observed, progress: nil)
                check(false, "清单暂时消失时拒绝迁移 \(name)")
            } catch {
                check(!fm.fileExists(atPath: listed.path) && !fm.fileExists(atPath: disappearing.appendingPathComponent("device-A.json").path),
                      "已见 \(name) 消失后不会按空历史发布")
            }
        }
        try expectDownload({
            _ = try DataDirectory.loadTarget(materializingRoot, cloud: false, readiness: DataDirectory.ready, manifestEnumerator: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                    NSUnderlyingErrorKey: NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.serverUnreachable.rawValue)
                ])
            })
        }, "目录枚举报告服务暂不可达时进入等待，即使路径当前可用")

        let datalessRoot = sandbox.appendingPathComponent("dataless-items")
        try DataDirectory.write(DataDirectory.baseline(Archive(clips: [a, b])), root: datalessRoot, device: "downloaded-index")
        try DataDirectory.write(DataDirectory.baseline(Archive()), root: datalessRoot, device: "dataless-index")
        let datalessIndex = datalessRoot.appendingPathComponent("device-dataless-index.json").path
        let datalessBlobs = [a, b].map {
            datalessRoot.appendingPathComponent("blobs").appendingPathComponent(HistoryStorage.digest($0.parts[0][0].data)).path
        }
        let datalessItems = Set([datalessIndex] + datalessBlobs)
        var datalessRequests = Set<String>()
        try expectDownload({
            _ = try DataDirectory.loadTarget(datalessRoot, cloud: true, readiness: { url in
                try DataDirectory.ready(url, downloadStatus: { (datalessItems.contains($0.path), false) }) {
                    datalessRequests.insert($0.path)
                }
            })
        }, "有实际路径的 File Provider 文件仍需等待下载")
        check(datalessRequests == datalessItems, "同一轮请求没有 .icloud 扩展名的清单及所有已知附件")

        let stagingTarget = sandbox.appendingPathComponent("migration-staging-race")
        let stagingHistory = stagingTarget.appendingPathComponent("history.json")
        let stagingRemote = stagingTarget.appendingPathComponent("device-late.json")
        let stagingPlaceholder = placeholder(stagingRemote)
        try HistoryStorage.write(Archive(clips: [b]), to: stagingHistory)
        let stagingHash = HistoryStorage.digest(try Data(contentsOf: stagingHistory))
        var wrotePlaceholder = false
        try expectDownload({
            _ = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: stagingTarget, device: "A",
                                           readiness: captureDownloadRequest, progress: { progress in
                if progress.phase == "迁移历史与附件", !wrotePlaceholder {
                    do { try Data().write(to: stagingPlaceholder); wrotePlaceholder = true }
                    catch { print("FAIL: 创建迁移期间新到的占位 \(error)"); exit(1) }
                }
            })
        }, "写入暂存数据时到达的新占位触发重新等待")
        let finalStagingHash = HistoryStorage.digest(try Data(contentsOf: stagingHistory))
        check(wrotePlaceholder && finalStagingHash == stagingHash,
              "最终复核发现新占位后不覆盖原活动索引")
        print("Data directory: \(passed) checks passed")
    } catch { print("FAIL: \(error)"); exit(1) }
}
#endif
