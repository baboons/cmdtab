import Foundation

/// A thread with its own CFRunLoop, used to host AXObserver sources and to
/// serialize all Accessibility work away from the main thread.
final class RunLoopThread: Thread {
    private(set) var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    init(name: String, qos: QualityOfService) {
        super.init()
        self.name = name
        self.qualityOfService = qos
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop alive before any AX sources are attached.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            CFRunLoopRun()
        }
    }

    func startAndWait() {
        start()
        ready.wait()
    }

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func perform(after delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.perform(block)
        }
    }
}
