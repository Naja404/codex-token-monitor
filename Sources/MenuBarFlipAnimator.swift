import AppKit

enum MenuBarFlipImage {
    static func make(from old: NSImage, to new: NSImage, progress: Double) -> NSImage {
        guard progress > 0 else { return old }
        guard progress < 1 else { return new }
        let image = NSImage(size: new.size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // Preserve the existing two-line layout; each line folds around its own seam.
        for (row, delay) in [(NSRect(x: 0, y: 10, width: new.size.width, height: 12), 0.0),
                             (NSRect(x: 0, y: 0, width: new.size.width, height: 10), 0.12)] {
            let p = min(1, max(0, (progress - delay) / (1 - delay)))
            let upper = NSRect(x: 0, y: row.midY, width: row.width, height: row.height / 2)
            let lower = NSRect(x: 0, y: row.minY, width: row.width, height: row.height / 2)
            new.draw(in: upper, from: upper, operation: .copy, fraction: 1)
            old.draw(in: lower, from: lower, operation: .copy, fraction: 1)
            if p < 0.5 {
                let scale = cos(p * .pi)
                let flap = NSRect(x: 0, y: row.midY, width: row.width, height: upper.height * scale)
                old.draw(in: flap, from: upper, operation: .copy, fraction: 0.65 + 0.35 * scale)
            } else {
                let scale = sin((p - 0.5) * .pi)
                let flap = NSRect(x: 0, y: row.midY - lower.height * scale, width: row.width, height: lower.height * scale)
                if scale > 0 { new.draw(in: flap, from: lower, operation: .copy, fraction: 0.65 + 0.35 * scale) }
            }
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

@MainActor
final class MenuBarFlipAnimator {
    private(set) var image: NSImage?
    private var source: NSImage?
    private var target: NSImage?
    private var lines: (String, String)?
    private var revision: UInt?
    private var timer: Timer?
    private let onFrame: (NSImage) -> Void
    private let motionAllowed: () -> Bool
    var isAnimating: Bool { timer?.isValid == true }

    init(motionAllowed: @escaping () -> Bool = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         onFrame: @escaping (NSImage) -> Void) {
        self.motionAllowed = motionAllowed
        self.onFrame = onFrame
    }

    func update(first: String, second: String, revision: UInt, animate: Bool, retainWidth: Bool) {
        let previous = lines
        let rotated = self.revision != nil && self.revision != revision
        self.revision = revision
        let unchanged = previous?.0 == first && previous?.1 == second
        if unchanged, retainWidth {
            if !animate || !motionAllowed() { finish() }
            return
        }
        finish()
        let width = retainWidth ? image?.size.width ?? 0 : 0
        let next = MenuBarUsageImage.make(firstLine: first, secondLine: second, minimumWidth: width)
        target = next
        lines = (first, second)
        guard rotated, !unchanged, animate, motionAllowed(), let previous else { publish(next); return }
        let old = MenuBarUsageImage.make(firstLine: previous.0, secondLine: previous.1, minimumWidth: next.size.width)
        source = old
        let started = ProcessInfo.processInfo.systemUptime
        publish(old)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                let progress = (ProcessInfo.processInfo.systemUptime - started) / 0.32
                guard progress < 1, self.motionAllowed(), let source = self.source, let target = self.target
                else { self.finish(); return }
                self.publish(MenuBarFlipImage.make(from: source, to: target, progress: progress))
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // Clicks and refreshes interrupt cleanly. Keep the final canvas width so the
    // status button's anchor does not move as its popover opens.
    func finish() {
        timer?.invalidate()
        timer = nil
        source = nil
        if let target, image !== target { publish(target) }
    }

    private func publish(_ frame: NSImage) {
        image = frame
        onFrame(frame)
    }
}
