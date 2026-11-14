#if OPENPASTE_TESTING
import AppKit
import QuartzCore
import Carbon
import SwiftUI
import Vision

@MainActor
private final class StartupPerformanceWindowDelegate: NSObject, NSWindowDelegate {
    let controller: Controller
    init(controller: Controller) { self.controller = controller }
    // Desktop focus changes are external to the submission benchmark.
    func windowDidResignKey(_ notification: Notification) {}
    func windowDidBecomeKey(_ notification: Notification) { controller.windowDidBecomeKey(notification) }
    func windowDidResize(_ notification: Notification) { controller.windowDidResize(notification) }
    func windowWillClose(_ notification: Notification) { controller.windowWillClose(notification) }
}

@MainActor
func prepareStartupPerformanceFixture(_ store: Store) {
    precondition(store.ephemeral, "Startup performance fixtures require an ephemeral store")
    store.networkPreviews = false
    store.resetFilters()
    let sources = ["Fixture Notes", "Fixture Editor", "Fixture Browser"]
    let sourceIDs = [Bundle.main.bundleIdentifier ?? "io.github.SwallOwDili.OpenPaste.performance",
                     "com.apple.finder", "com.apple.TextEdit"]
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    var clips = (0..<1_000).map { index in
        let number = String(format: "%04d", index)
        let text = "OpenPaste performance item \(number)\nGroup \(index % 10). Fixed local text for shelf selection and search.\n这是用于启动性能验收的隔离样例。"
        return Clip(
            id: UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", index + 1))")!,
            created: date.addingTimeInterval(Double(-index)),
            source: sources[index % sources.count], sourceID: sourceIDs[index % sourceIDs.count],
            kind: "文字", title: "Performance item \(number)", text: text,
            parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]])
    }
    var boards: [Board] = []
    if CommandLine.arguments.contains("--startup-performance-interactive") {
        boards = [Board(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!, name: "Fixture Board A", color: "#4175C8"),
                  Board(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!, name: "Fixture Board B", color: "#48A078")]
        let values = ["Interactive text alpha\n用于方向键、选择和预览验收。",
                      "Interactive text beta\n第二条固定文字样例。",
                      "http://127.0.0.1:9/openpaste", "Generated local image", "#4175C8",
                      "struct PerformanceFixture {\n    let title: String\n    func label() -> String { title }\n}"]
        let kinds = ["文字", "文字", "链接", "图片", "颜色", "文字"]
        for index in 0..<6 {
            clips[index].kind = kinds[index]
            clips[index].title = ["Interactive alpha", "Interactive beta", "Private local URL", "Generated image", "Fixture color", "Fixture Swift code"][index]
            clips[index].text = values[index]
            clips[index].parts = [[ClipPart(type: "public.utf8-plain-text", data: Data(values[index].utf8))]]
            clips[index].boards = [boards[index % 2].id]
        }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = image.bitmapData!
        for y in 0..<80 {
            for x in 0..<120 {
                let offset = y * image.bytesPerRow + x * 4
                pixels[offset] = UInt8(40 + x)
                pixels[offset + 1] = UInt8(80 + y)
                pixels[offset + 2] = 200
                pixels[offset + 3] = 255
            }
        }
        clips[3].parts = [[ClipPart(type: "public.png", data: image.representation(using: .png, properties: [:])!)]]
    }
    store.archive = Archive(clips: clips, boards: boards)
    store.currentClipID = nil
    store.selected = clips.first?.id
    store.selection.removeAll()
    store.pasteQueue.removeAll()
}

@MainActor
func runStartupPerformanceTests(controller: Controller) async {
    let store = controller.store
    func emit(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        print("PERF \(json)")
        fflush(stdout)
    }
    guard store.ephemeral, !store.networkPreviews, store.archive.clips.count == 1_000,
          let panel = controller.panel, !panel.isVisible, controller.settingsWindow == nil else {
        emit(["event": "summary", "passed": false, "reason": "requires prepared ephemeral fixture and unopened windows"])
        NSApp.terminate(nil)
        return
    }
    if let observer = controller.activationObserver {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        controller.activationObserver = nil
    }
    if let monitor = controller.outsideClickMonitor {
        NSEvent.removeMonitor(monitor)
        controller.outsideClickMonitor = nil
    }
    if let monitor = controller.keyMonitor {
        NSEvent.removeMonitor(monitor)
        controller.keyMonitor = nil
    }
    if let monitor = controller.wheelMonitor {
        NSEvent.removeMonitor(monitor)
        controller.wheelMonitor = nil
    }
    if let hotkey = controller.hotkey { UnregisterEventHotKey(hotkey); controller.hotkey = nil }
    if let handler = controller.handler { RemoveEventHandler(handler); controller.handler = nil }
    store.timer?.invalidate(); store.timer = nil
    store.syncTimer?.invalidate(); store.syncTimer = nil
    let benchmarkDelegate = StartupPerformanceWindowDelegate(controller: controller)
    panel.delegate = benchmarkDelegate
    let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]) { _ in nil }
    defer {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        withExtendedLifetime(benchmarkDelegate) {}
    }
    panel.ignoresMouseEvents = true

    var passed = true
    var samples = 0
    func drain() async { try? await Task.sleep(nanoseconds: 20_000_000) }
    func submit(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }
    // The first boundary is synchronous. SwiftUI may also schedule work for a later
    // run-loop turn, so report a second submission after an explicit main-actor yield.
    func measure(_ name: String, iteration: Int, expectedFilterPasses: Int, expectedSelection: UUID? = nil,
                 window: () -> NSWindow?, verify: () -> Bool, action: () -> Void) async {
        let before = store.filterPasses
        let selectionBefore = store.selected?.uuidString ?? "none"
        let start = CACurrentMediaTime()
        action()
        let handled = CACurrentMediaTime()
        let destination = window()
        destination?.ignoresMouseEvents = true
        if let destination { submit(destination) }
        let submitted = CACurrentMediaTime()
        let visibleAfterHandler = destination?.isVisible == true
        await drain()
        let settledStart = CACurrentMediaTime()
        if let destination { submit(destination) }
        let settled = CACurrentMediaTime()
        let delta = store.filterPasses - before
        let verificationPassed = verify()
        let visible = destination?.isVisible == true
        let valid = visible && delta == expectedFilterPasses && verificationPassed
        passed = passed && valid
        samples += 1
        emit([
            "event": name, "iteration": iteration, "temperature": iteration == 0 ? "cold" : "warm",
            "handler_ms": (handled - start) * 1_000,
            "render_ms": (submitted - handled) * 1_000,
            "submit_ms": (submitted - start) * 1_000,
            "settle_wait_ms": (settledStart - submitted) * 1_000,
            "settled_render_ms": (settled - settledStart) * 1_000,
            "settled_submit_ms": (settled - start) * 1_000,
            "filter_passes": delta, "expected_filter_passes": expectedFilterPasses,
            "result_count": store.filtered.count, "passed": valid,
            "visible_after_handler": visibleAfterHandler, "window_visible": visible,
            "verification_passed": verificationPassed, "app_active": NSApp.isActive,
            "panel_key": panel.isKeyWindow, "settings": store.settings,
            "selection_before": selectionBefore, "selection_after": store.selected?.uuidString ?? "none",
            "expected_selection": expectedSelection?.uuidString ?? "not_applicable",
            "query": store.query, "shelf_presentation": controller.shelfPresentation,
            "frontmost_is_self": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            "capture_timer_active": store.timer?.isValid == true,
            "sync_timer_active": store.syncTimer?.isValid == true
        ])
    }

    emit(["event": "configuration", "history_count": store.archive.clips.count,
          "source_count": store.sources.count, "network_previews": false,
          "boundary": "layoutSubtreeIfNeeded + displayIfNeeded + CATransaction.flush; not pixel presentation",
          "cold_scope": "first invocation in this process; shelf host already constructed",
          "yield_requested_ms": 20,
          "external_focus_dismissal_isolated": true, "global_shortcut_disabled": true,
          "local_input_blocked": true])
    await drain()
    for iteration in 0...5 {
        await measure("shelf.show", iteration: iteration, expectedFilterPasses: 0,
                      window: { controller.panel }, verify: { store.filtered.count == 1_000 },
                      action: { controller.showShelf() })
        panel.orderOut(nil)
        await drain()
    }
    for iteration in 0...5 {
        await measure("settings.open", iteration: iteration, expectedFilterPasses: 0,
                      window: { controller.settingsWindow }, verify: { store.settings },
                      action: { controller.openSettings() })
        controller.closeSettings()
        await drain()
    }
    controller.showShelf()
    submit(panel)
    await drain()
    if let clip = store.filtered.first {
        for iteration in 0...5 {
            await measure("preview.open", iteration: iteration, expectedFilterPasses: 0,
                          window: { controller.previewWindow },
                          verify: { controller.previewPopover?.isShown == true && controller.previewClipID == clip.id },
                          action: { controller.showPreview(clip) })
            controller.closePreview(animated: false)
            await drain()
        }
    }
    for iteration in 0...5 {
        let expected = store.filtered[iteration + 1].id
        await measure("shelf.selection.visible", iteration: iteration, expectedFilterPasses: 0, expectedSelection: expected,
                      window: { panel }, verify: { store.selected == expected },
                      action: { store.moveSelection(1) })
        await drain()
    }
    for (iteration, query) in ["Group 1.", "Group 2.", "Group 3.", "Group 4.", "Group 5.", "Group 6."].enumerated() {
        await measure("shelf.search", iteration: iteration, expectedFilterPasses: 1,
                      window: { panel }, verify: { store.query == query && store.filtered.count == 100 },
                      action: { store.query = query })
        await drain()
    }
    var iconCacheReused = false
    if let bundleID = Bundle.main.bundleIdentifier,
       let icon = PreviewCache.shared.sourceIcon(bundleID) {
        iconCacheReused = true
        for _ in 0..<100 {
            if PreviewCache.shared.sourceIcon(bundleID) !== icon { iconCacheReused = false }
        }
    }
    passed = passed && iconCacheReused

    func settingsHosts(in view: NSView?) -> [NSHostingView<SettingsPageView>] {
        guard let view else { return [] }
        if let host = view as? NSHostingView<SettingsPageView> { return [host] }
        return view.subviews.flatMap { settingsHosts(in: $0) }
    }
    let defaultPage: SettingsPage = CommandLine.arguments.contains("--about") ? .about : .general
    let routes: [(SettingsPage, () -> Void)] = [
        (defaultPage, { controller.openSettings() }),
        (.privacy, { controller.openPrivacySettings() }),
        (.about, { controller.openSettings(page: .about) })
    ]
    for (target, open) in routes {
        controller.closeSettings()
        controller.settingsWindow = nil
        await drain()
        open()
        guard let window = controller.settingsWindow else {
            passed = false
            emit(["event": "settings.routing", "target": target.rawValue, "passed": false, "reason": "settings window missing"])
            continue
        }
        window.ignoresMouseEvents = true
        submit(window)
        let firstHosts = settingsHosts(in: window.contentView)
        let firstPageMatches = window.isVisible && firstHosts.count == 1 && firstHosts.first?.rootView.page == target

        let alternate: SettingsPage = target == .general ? .privacy : .general
        controller.openSettings(page: alternate)
        await drain()
        submit(window)
        let alternateHosts = settingsHosts(in: window.contentView)
        let warmPageMatches = controller.settingsWindow === window && alternateHosts.count == 1 && alternateHosts.first?.rootView.page == alternate

        controller.closeSettings()
        let closed = !window.isVisible && !store.settings
        controller.openSettings()
        await drain()
        submit(window)
        let reopenedHosts = settingsHosts(in: window.contentView)
        let reopenRetainsPage = controller.settingsWindow === window && window.isVisible &&
            reopenedHosts.count == 1 && reopenedHosts.first === alternateHosts.first

        controller.closeSettings()
        if target == .privacy { controller.openPrivacySettings() }
        else { controller.openSettings(page: target) }
        submit(window)
        let returnedHosts = settingsHosts(in: window.contentView)
        let targetedReopenRetainsHost = controller.settingsWindow === window && window.isVisible &&
            returnedHosts.count == 1 && returnedHosts.first === firstHosts.first

        controller.closeSettings()
        controller.openSettings(page: alternate)
        submit(window)
        let alternateReopenHosts = settingsHosts(in: window.contentView)
        let alternateReopenRetainsHost = controller.settingsWindow === window && window.isVisible &&
            alternateReopenHosts.count == 1 && alternateReopenHosts.first === alternateHosts.first
        let routePassed = firstPageMatches && warmPageMatches && closed && reopenRetainsPage &&
            targetedReopenRetainsHost && alternateReopenRetainsHost
        passed = passed && routePassed
        emit(["event": "settings.routing", "target": target.rawValue,
              "first_pages": firstHosts.map { $0.rootView.page.rawValue },
              "warm_page": alternateHosts.first?.rootView.page.rawValue ?? "none",
              "closed": closed, "reopen_retains_page": reopenRetainsPage,
              "targeted_reopen_retains_host": targetedReopenRetainsHost,
              "alternate_reopen_retains_host": alternateReopenRetainsHost, "passed": routePassed])
    }

    controller.closeSettings()
    controller.settingsWindow = nil
    await drain()
    controller.openSettings(page: .about)
    let rapidWindow = controller.settingsWindow
    controller.openPrivacySettings()
    if let rapidWindow { submit(rapidWindow) }
    let immediatePages = settingsHosts(in: rapidWindow?.contentView).map { $0.rootView.page }
    await drain()
    if let rapidWindow { submit(rapidWindow) }
    let settledPages = settingsHosts(in: rapidWindow?.contentView).map { $0.rootView.page }
    let rapidRoutePassed = controller.settingsWindow === rapidWindow && rapidWindow?.isVisible == true &&
        immediatePages == [.privacy] && settledPages == [.privacy]
    passed = passed && rapidRoutePassed
    emit(["event": "settings.routing.rapid", "first_pages": immediatePages.map(\.rawValue),
          "settled_pages": settledPages.map(\.rawValue), "passed": rapidRoutePassed])

    controller.closeSettings()

    func normalizedSummary(_ text: String) -> String {
        // Vision reads the rendered middle dot as a bullet; counts and labels stay exact.
        String(text.filter { !$0.isWhitespace }).replacingOccurrences(of: "•", with: "·")
    }

    func waitForPreviewFooter(_ expected: String, stage: String) async -> String {
        // A hosting view's first bitmap is transparent until SwiftUI commits a frame.
        await drain()
        let deadline = CACurrentMediaTime() + 2
        var raw = ""
        var lastImage: NSBitmapImageRep?
        while CACurrentMediaTime() < deadline {
            guard let window = controller.previewWindow, window.isVisible,
                  let root = controller.previewHost?.view else { break }
            submit(window)
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { break }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            lastImage = bitmap
            let pixelScale = CGFloat(bitmap.pixelsHigh) / root.bounds.height
            let footerHeight = min(bitmap.pixelsHigh, Int(ceil(PreviewLayout.footer * pixelScale)))
            guard let image = bitmap.cgImage,
                  let footer = image.cropping(to: CGRect(x: 0, y: bitmap.pixelsHigh - footerHeight,
                                                         width: bitmap.pixelsWide, height: footerHeight)) else { break }
            raw = await Task.detached(priority: .userInitiated) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = false
                do {
                    try VNImageRequestHandler(cgImage: footer).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                } catch {
                    return error.localizedDescription
                }
            }.value
            if normalizedSummary(raw) == normalizedSummary(expected) { return raw }
            await drain()
        }

        var diagnostic: [String: Any] = ["event": "preview.footer.diagnostics", "stage": stage, "ocr": raw]
        if AppEnvironment.current.acceptanceMode,
           let png = lastImage?.representation(using: .png, properties: [:]) {
            let snapshot = AppEnvironment.current.defaultDataRoot.appendingPathComponent("preview-footer-\(stage).png")
            do {
                try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: snapshot, options: .atomic)
                diagnostic["snapshot"] = snapshot.path
            } catch {
                diagnostic["snapshot_error"] = error.localizedDescription
            }
        }
        emit(diagnostic)
        return raw
    }

    func testPreviewFooter() async -> Bool {
        func textClip(_ text: String) -> Clip {
            Clip(source: "Preview footer fixture", sourceID: "", kind: "文字", title: "Preview footer fixture",
                 text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]])
        }
        let long = textClip(String(repeating: "word\n", count: 40_000) + "tail")
        let short = textClip("fresh\ntext")
        let shortExpected = "10 个字符 · 2 个词 · 2 行"
        let editedText = "edited three words"
        let editedExpected = "18 个字符 · 3 个词 · 1 行"
        store.resetFilters()
        store.archive = Archive(clips: [long, short])
        controller.showShelf()
        store.choose(short.id)
        submit(panel)
        await drain()

        controller.showPreview(short)
        let initialSummary = await waitForPreviewFooter(shortExpected, stage: "initial")
        controller.closePreview(animated: false)
        guard normalizedSummary(initialSummary) == normalizedSummary(shortExpected) else {
            emit(["event": "preview.footer", "stage": "initial", "ocr": initialSummary, "passed": false])
            return false
        }

        store.choose(long.id)
        controller.showPreview(long)
        guard let window = controller.previewWindow, let popover = controller.previewPopover else {
            emit(["event": "preview.footer", "stage": "open_long", "passed": false])
            return false
        }
        window.ignoresMouseEvents = true
        submit(window)
        await drain()
        store.choose(short.id)
        let switchedSummary = await waitForPreviewFooter(shortExpected, stage: "after-switch")
        let switchedInPlace = controller.previewPopover === popover && controller.previewWindow === window &&
            controller.previewClipID == short.id && normalizedSummary(switchedSummary) == normalizedSummary(shortExpected)

        let saved = store.saveContentEdit(.text(NSAttributedString(string: editedText)), to: .existing(short.id))
        let editedSummary = await waitForPreviewFooter(editedExpected, stage: "after-edit")
        let editedInPlace = saved && controller.previewPopover === popover && controller.previewWindow === window &&
            controller.previewClipID == short.id && normalizedSummary(editedSummary) == normalizedSummary(editedExpected)

        store.choose(long.id)
        await drain()
        controller.closePreview(animated: false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let closed = controller.previewPopover == nil && controller.previewHost == nil &&
            controller.previewWindow == nil && controller.previewClipID == nil && !window.isVisible
        let valid = switchedInPlace && editedInPlace && closed
        emit(["event": "preview.footer", "initial": initialSummary, "after_switch": switchedSummary,
              "after_edit": editedSummary, "switched_in_place": switchedInPlace, "edited_in_place": editedInPlace,
              "closed": closed, "passed": valid])
        return valid
    }

    let previewFooterPassed = await testPreviewFooter()
    passed = passed && previewFooterPassed
    emit(["event": "summary", "passed": passed, "samples": samples,
          "icon_cache_reused": iconCacheReused,
          "boundary": "application submission only; no pixel presentation measurement"])
    NSApp.terminate(nil)
}

@MainActor
func runStartupPerformanceInteractive(controller: Controller) {
    precondition(controller.store.ephemeral && !controller.store.networkPreviews)
    precondition(CommandLine.arguments.contains("--startup-performance-interactive"))
    if let observer = controller.activationObserver {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        controller.activationObserver = nil
    }
    if let monitor = controller.outsideClickMonitor {
        NSEvent.removeMonitor(monitor)
        controller.outsideClickMonitor = nil
    }
    if let hotkey = controller.hotkey { UnregisterEventHotKey(hotkey); controller.hotkey = nil }
    if let handler = controller.handler { RemoveEventHandler(handler); controller.handler = nil }
    controller.store.timer?.invalidate(); controller.store.timer = nil
    controller.store.syncTimer?.invalidate(); controller.store.syncTimer = nil
    controller.showShelf()
    print("PERF {\"event\":\"interactive.ready\",\"history_count\":1000,\"fixture_cards\":6,\"boards\":2,\"network_previews\":false}")
    fflush(stdout)
}
#endif
