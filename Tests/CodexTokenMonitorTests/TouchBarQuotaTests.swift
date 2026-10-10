import Foundation
import AppKit
import ImageIO
import Testing
@testable import CodexTokenMonitor

@Test(arguments: [(0, TouchBarCatActivity.sleepy), (19, .sleepy), (20, .calm),
                  (49, .calm), (50, .playful), (79, .playful), (80, .energetic), (100, .energetic)])
func catActivityFollowsRemainingQuota(remaining: Int, expected: TouchBarCatActivity) {
    let window = QuotaWindow(name: "", budget: 100, used: 100 - remaining, resetsAt: .now)
    #expect(TouchBarCatActivity(fiveHour: window, weekly: nil, status: .live) == expected)
    #expect(TouchBarCatActivity(fiveHour: nil, weekly: window, status: .live) == expected)
}

@Test func catActivityUsesLowerAccountQuotaAndDoesNotInventMissingData() {
    let high = QuotaWindow(name: "", budget: 100, used: 5, resetsAt: .now)
    let low = QuotaWindow(name: "", budget: 100, used: 90, resetsAt: .now)
    #expect(TouchBarCatActivity(fiveHour: high, weekly: low, status: .live) == .sleepy)
    #expect(TouchBarCatActivity(fiveHour: nil, weekly: nil, status: .live) == .unknown)
    #expect(TouchBarCatActivity(fiveHour: high, weekly: high, status: .unavailable) == .unknown)
    #expect(TouchBarCatActivity(fiveHour: high, weekly: high, status: .loading) == .unknown)
    #expect(TouchBarCatActivity(fiveHour: high, weekly: high, status: .manual) == .energetic)
    #expect(TouchBarCatActivity.energetic.cycleDuration < TouchBarCatActivity.playful.cycleDuration)
    #expect(TouchBarCatActivity.playful.cycleDuration < TouchBarCatActivity.calm.cycleDuration)
    #expect(TouchBarCatActivity.calm.cycleDuration < TouchBarCatActivity.sleepy.cycleDuration)
}

@Test @MainActor func monitorControllerProvidesTouchBarItems() throws {
    _ = NSApplication.shared
    let controller = MonitorHostingController(rootView: MonitorView(
        model: UsageModel(), onQuit: {}, onWriteBackSettingsVisibilityChanged: { _ in }
    ))
    controller.loadView()
    controller.view.layoutSubtreeIfNeeded()
    let bar = try #require(controller.touchBar)
    #expect(bar.defaultItemIdentifiers.map(\.rawValue) == [
        "codex.quota.cat", "codex.quota.fiveHour", "codex.quota.weekly", "codex.quota.refresh"
    ])
    for identifier in bar.defaultItemIdentifiers {
        #expect(bar.item(forIdentifier: identifier) != nil)
    }
}

@Test @MainActor func nativeTouchBarUpdatesValuesAndRefreshAvailability() throws {
    _ = NSApplication.shared
    let model = UsageModel()
    let controller = MonitorHostingController(rootView: MonitorView(
        model: model, onQuit: {}, onWriteBackSettingsVisibilityChanged: { _ in }
    ))
    let bar = try #require(controller.touchBar)
    let refresh = try #require(bar.item(forIdentifier: .init("codex.quota.refresh")) as? NSButtonTouchBarItem)
    #expect(refresh.title == "读取中")
    #expect(!refresh.isEnabled)

    let window = QuotaWindow(name: "", budget: 100, used: 40, resetsAt: .now)
    model.useManualValues(fiveHour: window, weekly: window)
    controller.updateQuotaTouchBar()

    let item = try #require(bar.item(forIdentifier: .init("codex.quota.fiveHour")) as? NSCustomTouchBarItem)
    let chart = try #require(item.view as? TouchBarQuotaChartView)
    #expect(chart.content?.title == "5小时 60%（手动）")
    #expect(chart.content?.remainingFraction == 0.6)
    #expect(refresh.title == "刷新")
    #expect(refresh.isEnabled)
    #expect(refresh.target === controller)
    #expect(refresh.action != nil)
    #expect(controller.touchBar === bar)
    let catItem = try #require(bar.item(forIdentifier: .init("codex.quota.cat")) as? NSCustomTouchBarItem)
    let cat = try #require(catItem.view as? TouchBarRainbowCatView)
    #expect(cat.activity == .playful)
}

@Test(arguments: [0, 20, 50, 80, 100])
func touchBarChartUsesRealRemainingFraction(remaining: Int) {
    let window = QuotaWindow(name: "", budget: 100, used: 100 - remaining, resetsAt: .now)
    let content = TouchBarQuotaContent(label: "5小时", window: window, status: .live, includesDate: false)
    #expect(content.remainingFraction == Double(remaining) / 100)
    let missing = TouchBarQuotaContent(label: "5小时", window: nil, status: .live, includesDate: false)
    #expect(missing.remainingFraction == nil)
    let loading = TouchBarQuotaContent(label: "5小时", window: window, status: .loading, includesDate: false)
    #expect(loading.remainingFraction == nil)
}

@Test @MainActor func rainbowCatStopsWhenHiddenOrReducedMotionIsEnabled() {
    let cat = TouchBarRainbowCatView(frame: NSRect(x: 0, y: 0, width: 92, height: 30))
    cat.update(activity: .energetic, visible: true, reducedMotion: false)
    #expect(cat.isAnimating)
    cat.update(activity: .energetic, visible: false, reducedMotion: false)
    #expect(!cat.isAnimating)
    cat.update(activity: .energetic, visible: true, reducedMotion: true)
    #expect(!cat.isAnimating)
    cat.update(activity: .unknown, visible: true, reducedMotion: false)
    #expect(!cat.isAnimating)
}

@Test @MainActor func quotaChangesRetuneRealCatAnimation() throws {
    let cat = TouchBarRainbowCatView(frame: NSRect(x: 0, y: 0, width: 92, height: 30))
    defer { cat.update(activity: .unknown, visible: false, reducedMotion: false) }
    for activity in [TouchBarCatActivity.energetic, .playful, .calm, .sleepy] {
        cat.update(activity: activity, visible: true, reducedMotion: false)
        #expect(cat.isAnimating)
        #expect(cat.frames.count == 12)
        #expect(cat.activity == activity)
        let frames = cat.frames
        let first = try #require(frames[0].dataProvider?.data)
        let moving = try #require(frames[3].dataProvider?.data)
        #expect(first != moving)
    }
}

@Test @MainActor func rendersRunningCatAnimation() throws {
    let cat = TouchBarRainbowCatView(frame: NSRect(x: 0, y: 0, width: 92, height: 30))
    cat.update(activity: .energetic, visible: true, reducedMotion: false)
    defer { cat.update(activity: .unknown, visible: false, reducedMotion: false) }
    let frames = cat.frames
    let pixels = try frames.map { try #require($0.dataProvider?.data) as Data }
    #expect(Set(pixels).count == 12)
    guard let path = ProcessInfo.processInfo.environment["TOUCH_BAR_ANIMATION_PREVIEW_PATH"] else { return }
    let destination = try #require(CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "com.compuserve.gif" as CFString, frames.count, nil
    ))
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFLoopCount: 0
    ]] as CFDictionary)
    for frame in frames {
        let context = try #require(CGContext(data: nil, width: 368, height: 120, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 368, height: 120))
        context.interpolationQuality = .none
        context.draw(frame, in: CGRect(x: 0, y: 0, width: 368, height: 120))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: cat.activity.cycleDuration / Double(frames.count)]
        ] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    // Contact sheet uses the exact production frames for checking paws, ears and eyes.
    let sheet = try #require(CGContext(data: nil, width: 1104, height: 480, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    sheet.setFillColor(NSColor.black.cgColor)
    sheet.fill(CGRect(x: 0, y: 0, width: 1104, height: 480))
    sheet.interpolationQuality = .none
    for (index, frame) in frames.enumerated() {
        sheet.draw(frame, in: CGRect(x: (index % 3) * 368, y: (3 - index / 3) * 120, width: 368, height: 120))
    }
    let bitmap = NSBitmapImageRep(cgImage: try #require(sheet.makeImage()))
    let sheetURL = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png")
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: sheetURL)
}

@MainActor private func catRegion(frame: Int, rect: CGRect) throws -> CGImage {
    let image = try #require(TouchBarRainbowCatView.makeFrame(activity: .energetic, frame: frame))
    let scale = CGFloat(image.width) / 92
    return try #require(image.cropping(to: CGRect(x: rect.minX * scale,
        y: (30 - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale)))
}

@Test @MainActor func catPushesBackwardOnGroundAndRecoversForwardInAir() throws {
    // Both frames have zero body bounce. For a right-facing cat, phase 3 is
    // the backward ground stroke; phase 9 is the lifted forward recovery.
    func pawPixels(frame: Int) throws -> Int {
        let image = try catRegion(frame: frame, rect: CGRect(x: 40, y: 2, width: 6, height: 2))
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.alphaComponent > 0.9 && (0.7...0.85).contains(color.redComponent)
                    && abs(color.redComponent - color.greenComponent) < 0.02 {
                    count += 1
                }
            }
        }
        return count
    }
    #expect(try pawPixels(frame: 3) > pawPixels(frame: 9))
}

@Test @MainActor func catFaceMovesIndependentlyOfBodyBounce() throws {
    // Frames 0 and 3 have the same body height: a rigidly attached face fails this check.
    let rect = CGRect(x: 60, y: 11, width: 20, height: 11)
    let first = try #require(NSBitmapImageRep(cgImage: catRegion(frame: 0, rect: rect))
        .representation(using: .png, properties: [:]))
    let next = try #require(NSBitmapImageRep(cgImage: catRegion(frame: 3, rect: rect))
        .representation(using: .png, properties: [:]))
    #expect(first != next)
}

@Test @MainActor func visibleCatProducesNewAppKitFramesOverTime() throws {
    let cat = TouchBarRainbowCatView(frame: NSRect(x: 0, y: 0, width: 92, height: 30))
    cat.update(activity: .energetic, visible: true, reducedMotion: false)
    defer { cat.update(activity: .energetic, visible: false, reducedMotion: false) }
    func capture() throws -> Data {
        let bitmap = try #require(cat.bitmapImageRepForCachingDisplay(in: cat.bounds))
        cat.cacheDisplay(in: cat.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    let first = try capture()
    cat.needsDisplay = false
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.14))
    // AppKit may already have serviced needsDisplay; compare rendered pixels, not that transient flag.
    #expect(try capture() != first)
    cat.update(activity: .energetic, visible: false, reducedMotion: false)
    let stopped = try capture()
    cat.needsDisplay = false
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.14))
    #expect(!cat.needsDisplay)
    #expect(try capture() == stopped)
}

@Test @MainActor func closingTouchBarStopsCatAnimation() throws {
    _ = NSApplication.shared
    let controller = MonitorHostingController(rootView: MonitorView(
        model: UsageModel(), onQuit: {}, onWriteBackSettingsVisibilityChanged: { _ in }
    ))
    let bar = try #require(controller.touchBar)
    let item = try #require(bar.item(forIdentifier: .init("codex.quota.cat")) as? NSCustomTouchBarItem)
    let cat = try #require(item.view as? TouchBarRainbowCatView)
    cat.update(activity: .energetic, visible: true, reducedMotion: false)
    controller.setTouchBarVisible(false)
    #expect(!cat.isAnimating)
}

@Test @MainActor func rendersTouchBarArtwork() throws {
    _ = NSApplication.shared
    let image = NSImage(size: NSSize(width: 888, height: 92))
    image.lockFocus()
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: 888, height: 92).fill()
    let transform = NSAffineTransform()
    transform.scale(by: 2)
    transform.translateX(by: 8, yBy: 8)
    transform.concat()
    let catFrame = try #require(TouchBarRainbowCatView.makeFrame(activity: .playful, frame: 0))
    NSImage(cgImage: catFrame, size: NSSize(width: 92, height: 30)).draw(in: NSRect(x: 0, y: 0, width: 92, height: 30))
    let reset = try #require(Calendar.current.date(from: DateComponents(
        year: 2026, month: 10, day: 12, hour: 18, minute: 5
    )))
    for (label, width, used, date) in [("5小时", 146.0, 40, false), ("每周", 180.0, 12, true)] {
        let shift = NSAffineTransform()
        shift.translateX(by: date ? 154 : 100, yBy: 0)
        shift.concat()
        let chart = TouchBarQuotaChartView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        chart.content = TouchBarQuotaContent(label: label, window: QuotaWindow(
            name: "", budget: 100, used: used, resetsAt: reset
        ), status: .live, includesDate: date)
        chart.draw(chart.bounds)
    }
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(!png.isEmpty)
    if let path = ProcessInfo.processInfo.environment["TOUCH_BAR_PREVIEW_PATH"] {
        try png.write(to: URL(fileURLWithPath: path))
    }
}

@Test @MainActor func touchBarShowsRemainingQuotaAndWeeklyResetDate() throws {
    let reset = try #require(Calendar.current.date(from: DateComponents(
        year: 2026, month: 10, day: 12, hour: 18, minute: 5
    )))
    let window = QuotaWindow(name: "", budget: 100, used: 40, resetsAt: reset)
    let hourly = TouchBarQuotaContent(label: "5小时", window: window, status: .live, includesDate: false)
    let weekly = TouchBarQuotaContent(label: "每周", window: window, status: .live, includesDate: true)

    #expect(hourly.title == "5小时 60%")
    #expect(hourly.detail == "重置 18:05")
    #expect(weekly.title == "每周 60%")
    #expect(weekly.detail == "重置 10月12日 18:05")
}

@Test @MainActor func rendersTouchBarReadmeAnimation() throws {
    _ = NSApplication.shared
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, "com.compuserve.gif" as CFString, 12, nil
    ))
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFLoopCount: 0
    ]] as CFDictionary)
    let reset = try #require(Calendar.current.date(from: DateComponents(
        year: 2026, month: 10, day: 12, hour: 18, minute: 5
    )))
    // Match the lower of the two displayed example quotas (60%): playful, not energetic.
    for frame in 0..<12 {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 92,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 92).fill()
        let transform = NSAffineTransform()
        transform.scale(by: 2)
        transform.translateX(by: 8, yBy: 8)
        transform.concat()
        let cat = try #require(TouchBarRainbowCatView.makeFrame(activity: .playful, frame: frame))
        NSImage(cgImage: cat, size: NSSize(width: 92, height: 30))
            .draw(in: NSRect(x: 0, y: 0, width: 92, height: 30))
        for (label, width, used, date) in [("5小时", 146.0, 40, false), ("每周", 180.0, 12, true)] {
            let shift = NSAffineTransform()
            shift.translateX(by: date ? 154 : 100, yBy: 0)
            shift.concat()
            let chart = TouchBarQuotaChartView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
            chart.content = TouchBarQuotaContent(label: label, window: QuotaWindow(
                name: "", budget: 100, used: used, resetsAt: reset
            ), status: .live, includesDate: date)
            chart.draw(chart.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        CGImageDestinationAddImage(destination, try #require(bitmap.cgImage), [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: TouchBarCatActivity.playful.cycleDuration / 12]
        ] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    let source = try #require(CGImageSourceCreateWithData(data, nil))
    #expect(CGImageSourceGetCount(source) == 12)
    if let path = ProcessInfo.processInfo.environment["TOUCH_BAR_README_GIF_PATH"] {
        try (data as Data).write(to: URL(fileURLWithPath: path))
    }
}

@Test @MainActor func touchBarUsesPlaceholdersForMissingWindows() {
    let view = TouchBarQuotaContent(label: "5小时", window: nil, status: .live, includesDate: false)
    #expect(view.title == "5小时 —")
    #expect(view.detail == "未提供此窗口")
}

@Test(arguments: [RateLimitStatus.loading, .unavailable])
@MainActor func touchBarDoesNotPresentOldValuesAsCurrent(status: RateLimitStatus) {
    let window = QuotaWindow(name: "", budget: 100, used: 40, resetsAt: .now)
    let view = TouchBarQuotaContent(label: "每周", window: window, status: status, includesDate: true)
    #expect(view.title == "每周 —")
    #expect(view.detail == (status == .loading ? "读取中…" : "暂不可用"))
}

@Test @MainActor func touchBarMarksManualValues() {
    let window = QuotaWindow(name: "", budget: 100, used: 100, resetsAt: .now)
    let view = TouchBarQuotaContent(label: "5小时", window: window, status: .manual, includesDate: false)
    #expect(view.title == "5小时 0%（手动）")
}
