import AppKit
import ImageIO
import Testing
@testable import CodexTokenMonitor

@Test @MainActor func unchangedMenuDoesNotPublishAnotherFrameWithoutRotation() {
    var frames = 0
    let animator = MenuBarFlipAnimator { _ in frames += 1 }
    animator.update(first: "5小时 80%", second: "一周 60%", revision: 0, animate: false, retainWidth: false)
    let image = animator.image
    for _ in 0..<60 {
        animator.update(first: "5小时 80%", second: "一周 60%", revision: 0, animate: false, retainWidth: false)
    }
    #expect(frames == 1)
    #expect(animator.image === image)
    animator.update(first: "5小时 79%", second: "一周 60%", revision: 0, animate: false, retainWidth: false)
    #expect(frames == 2)
}

@Test @MainActor func menuFlipOnlyStartsForAutomaticRotation() {
    let animator = MenuBarFlipAnimator(motionAllowed: { true }) { _ in }
    defer { animator.finish() }
    animator.update(first: "Codex 80%", second: "每周 60%", revision: 0, animate: true, retainWidth: true)
    #expect(!animator.isAnimating)
    animator.update(first: "Codex 79%", second: "每周 60%", revision: 0, animate: true, retainWidth: true)
    #expect(!animator.isAnimating)
    animator.update(first: "CL 50%", second: "每周 40%", revision: 1, animate: true, retainWidth: true)
    #expect(animator.isAnimating)
    // The one-second status updater must not restart/cancel an unchanged flip.
    animator.update(first: "CL 50%", second: "每周 40%", revision: 1, animate: true, retainWidth: true)
    #expect(animator.isAnimating)
    animator.update(first: "TR US$85.32", second: "今日 US$1.28", revision: 1, animate: true, retainWidth: true)
    #expect(!animator.isAnimating) // Manual selection, not a rotation event.
}

@Test @MainActor func menuFlipRespectsMotionAndFinishesWithoutChangingWidth() {
    let animator = MenuBarFlipAnimator(motionAllowed: { true }) { _ in }
    defer { animator.finish() }
    animator.update(first: "5小时 80% · 18:00", second: "每周 60% · 10月12日", revision: 0, animate: true, retainWidth: true)
    let width = animator.image?.size.width
    animator.update(first: "TR US$8", second: "今日 US$1", revision: 1, animate: true, retainWidth: true)
    #expect(animator.isAnimating)
    animator.finish() // Click interrupts before AppKit computes the popover anchor.
    #expect(!animator.isAnimating)
    #expect(animator.image?.size.width == width)
    animator.update(first: "CL —", second: "每周 —", revision: 2, animate: false, retainWidth: true)
    #expect(!animator.isAnimating)
    #expect(animator.image?.size.width == width)
    animator.update(first: "CL —", second: "每周 —", revision: 2, animate: false, retainWidth: false)
    #expect(animator.image!.size.width < width!)
}

@Test @MainActor func menuFlipCompletesAndDisposesItsTimer() async throws {
    let animator = MenuBarFlipAnimator(motionAllowed: { true }) { _ in }
    defer { animator.finish() }
    animator.update(first: "Codex", second: "80%", revision: 0, animate: true, retainWidth: true)
    animator.update(first: "Claude", second: "70%", revision: 1, animate: true, retainWidth: true)
    #expect(animator.isAnimating)
    for _ in 0..<100 where animator.isAnimating { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!animator.isAnimating)
    #expect(animator.image?.isTemplate == true)
}

@Test @MainActor func menuFlipStopsWhenReducedMotionIsEnabled() {
    var allowed = false
    let animator = MenuBarFlipAnimator(motionAllowed: { allowed }) { _ in }
    defer { animator.finish() }
    animator.update(first: "Codex", second: "80%", revision: 0, animate: true, retainWidth: true)
    animator.update(first: "Claude", second: "70%", revision: 1, animate: true, retainWidth: true)
    #expect(!animator.isAnimating)
    allowed = true
    animator.update(first: "Warp", second: "60%", revision: 2, animate: true, retainWidth: true)
    #expect(animator.isAnimating)
    allowed = false
    animator.update(first: "Warp", second: "60%", revision: 2, animate: true, retainWidth: true)
    #expect(!animator.isAnimating)
}

@Test @MainActor func automaticRotationRevisionIgnoresPauseAndManualSelection() {
    let name = "flip-rotation-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "antigravityEnabled")
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    defer { store.stop() }
    store.setMenuRotationEnabled(true, now: 0)
    store.setMenuRotationInterval(5, now: 0)
    #expect(store.menuRotationRevision == 0)
    store.advanceMenuRotation(now: 5, paused: true)
    #expect(store.menuRotationRevision == 0)
    store.advanceMenuRotation(now: 10)
    #expect(store.menuRotationRevision == 1)
    store.setMenuSource(.codex)
    store.setMenuRotationEnabled(false)
    #expect(store.menuRotationRevision == 1)
}

@Test @MainActor func menuFlipFramesAreTemplateFixedSizeAndReachBothEndpoints() throws {
    _ = NSApplication.shared
    let old = MenuBarUsageImage.make(firstLine: "5小时 80% · 18:00", secondLine: "每周 60% · 10月12日", minimumWidth: 150)
    let new = MenuBarUsageImage.make(firstLine: "TR US$85.32", secondLine: "今日 US$1.28", minimumWidth: 150)
    func pixels(_ image: NSImage) throws -> Data {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try #require(cg.dataProvider?.data) as Data
    }
    #expect(try pixels(MenuBarFlipImage.make(from: old, to: new, progress: 0)) == pixels(old))
    #expect(try pixels(MenuBarFlipImage.make(from: old, to: new, progress: 1)) == pixels(new))
    let middle = MenuBarFlipImage.make(from: old, to: new, progress: 0.5)
    #expect(try pixels(middle) != pixels(old))
    #expect(try pixels(middle) != pixels(new))
    for step in 0...18 {
        let image = MenuBarFlipImage.make(from: old, to: new, progress: Double(step) / 18)
        #expect(image.isTemplate)
        #expect(image.size == old.size)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MENU_FLIP_PREVIEW_DIR"] != nil))
@MainActor func rendersMenuFlipPreview() throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MENU_FLIP_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lines = [("5小时 80% · 18:00", "一周 60% · 10月12日"),
                 ("CL 5小时 70% · 18:30", "一周 50% · 10月13日"),
                 ("TR 余额 US$85.32", "今日 US$1.28")]
    let images = lines.map { MenuBarUsageImage.make(firstLine: $0.0, secondLine: $0.1, minimumWidth: 160) }
    let frameCount = images.count * 17
    let url = directory.appendingPathComponent("menu-bar-flip.gif")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
        "com.compuserve.gif" as CFString, frameCount, nil))
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for index in images.indices {
        for step in 0...16 {
            let frame = MenuBarFlipImage.make(from: images[index], to: images[(index + 1) % images.count],
                                             progress: Double(step) / 16)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 200,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 800, height: 200).fill()
            let transform = NSAffineTransform()
            transform.scale(by: 2)
            transform.concat()
            "自动轮播 · 翻牌预览".draw(at: NSPoint(x: 20, y: 76), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black])
            "示例数据 · 文字放大 2×".draw(at: NSPoint(x: 20, y: 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray])
            frame.draw(in: NSRect(x: 40, y: 30, width: 320, height: 44))
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(destination, try #require(bitmap.cgImage), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step == 0 ? 4.68 : 0.02]
            ] as CFDictionary)
            if index == 0, step == 0 || step == 8 {
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: directory.appendingPathComponent("menu-flip-frame-\(step).png"))
            }
        }
    }
    #expect(CGImageDestinationFinalize(destination))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    #expect(CGImageSourceGetCount(source) == frameCount)
}
