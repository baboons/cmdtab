import AppKit
import ScreenCaptureKit

/// Captures and caches downscaled window previews.
///
/// Captures run concurrently off the main thread and results stream back one
/// by one, so the switcher shows instantly with cached (or icon) previews
/// and sharpens as fresh captures arrive.
final class ThumbnailService {
    static let shared = ThumbnailService()

    /// Main thread: called whenever a fresh thumbnail is ready.
    var onUpdate: ((CGWindowID, CGImage) -> Void)?

    private var cache: [CGWindowID: CGImage] = [:]
    private var inFlight = Set<CGWindowID>()
    /// Last capture attempt per window; avoids re-capturing on every keystroke
    /// (and hammering windows that can't be captured, like minimized ones).
    private var attempted: [CGWindowID: CFAbsoluteTime] = [:]
    private static let minInterval: CFAbsoluteTime = 1.5
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "CmdTab.thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func thumbnail(for id: CGWindowID) -> CGImage? {
        cache[id]
    }

    func inject(_ image: CGImage, for id: CGWindowID) {
        cache[id] = image
    }

    func evict(_ ids: [CGWindowID]) {
        for id in ids {
            cache.removeValue(forKey: id)
            attempted.removeValue(forKey: id)
        }
    }

    /// Requests fresh captures for `ids` (in priority order), each scaled to
    /// fit `maxPixels`.
    func refresh(_ ids: [CGWindowID], maxPixels: CGSize) {
        guard hasPermission else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let todo = ids.filter { id in
            id != 0 && !inFlight.contains(id) && now - (attempted[id] ?? 0) > Self.minInterval
        }
        inFlight.formUnion(todo)
        for id in todo { attempted[id] = now }
        for id in todo {
            queue.addOperation { [self] in
                let image = Self.capture(id).flatMap { Self.downscale($0, toFit: maxPixels) }
                DispatchQueue.main.async { [self] in
                    inFlight.remove(id)
                    guard let image else { return }
                    cache[id] = image
                    onUpdate?(id, image)
                }
            }
        }
    }

    // MARK: - Capture

    private static func capture(_ id: CGWindowID) -> CGImage? {
        if Private.canCaptureWindows {
            if let image = Private.captureWindow(id), image.width > 1, image.height > 1 { return image }
            return nil
        }
        return ScreenCaptureFallback.capture(id)
    }

    private static func downscale(_ image: CGImage, toFit box: CGSize) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(box.width / w, box.height / h, 1)
        if scale >= 0.98 { return image }
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage() ?? image
    }
}

/// Public-API capture path, used only if the private one is unavailable.
private enum ScreenCaptureFallback {
    private static let lock = NSLock()
    private static var content: SCShareableContent?
    private static var fetchedAt = Date.distantPast

    static func capture(_ id: CGWindowID) -> CGImage? {
        guard let window = shareableWindow(id) else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return wait { done in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in done(image) }
        }
    }

    private static func shareableWindow(_ id: CGWindowID) -> SCWindow? {
        lock.lock()
        let stale = content == nil || Date().timeIntervalSince(fetchedAt) > 2
        lock.unlock()
        if stale {
            let fresh: SCShareableContent? = wait { done in
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { c, _ in done(c) }
            }
            lock.lock()
            content = fresh
            fetchedAt = Date()
            lock.unlock()
        }
        lock.lock()
        defer { lock.unlock() }
        return content?.windows.first { $0.windowID == id }
    }

    private static func wait<T>(_ body: (@escaping (T?) -> Void) -> Void) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        body { value in
            result = value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
        return result
    }
}
