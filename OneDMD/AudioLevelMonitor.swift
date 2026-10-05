import AVFoundation
import Observation
import QuartzCore

struct AudioSample: Equatable {
    let time: CFTimeInterval
    let level: Float
}

@MainActor
@Observable
final class AudioLevelMonitor {
    var samples: [AudioSample] = []
    var isRunning = false

    private let engine = AVAudioEngine()
    private let historySize = 400
    private let emitInterval: CFTimeInterval = 1.0 / 20.0
    private var lastEmit: CFTimeInterval = 0
    private var peakSinceEmit: Float = 0

    private var displayLink: CADisplayLink?
    private var proxy: DisplayLinkProxy?

    private let lock = NSLock()
    nonisolated(unsafe) private var pendingLevel: Float = 0.02

    func start() {
        guard !isRunning else { return }
        samples = []
        startEngine()
    }

    func resume() {
        guard !isRunning else { return }
        startEngine()
    }

    func pause() {
        guard isRunning else { return }
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func startEngine() {
        lastEmit = 0
        peakSinceEmit = 0

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [])
        try? session.setActive(true, options: [])
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(frames))
            let shaped = pow(rms, 0.5) * 1.6
            let level = min(1, max(0.02, shaped))
            self.lock.lock()
            self.pendingLevel = level
            self.lock.unlock()
        }

        do {
            try engine.start()
            #if os(iOS)
            let proxy = DisplayLinkProxy { [weak self] in self?.tick() }
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire))
            link.add(to: .main, forMode: .common)
            self.proxy = proxy
            self.displayLink = link
            #endif
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard isRunning else { return }
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    fileprivate func tick() {
        lock.lock()
        let level = pendingLevel
        lock.unlock()

        if level > peakSinceEmit { peakSinceEmit = level }
        let now = CACurrentMediaTime()

        if lastEmit == 0 {
            lastEmit = now
            return
        }

        let nextEmit = lastEmit + emitInterval
        if now - nextEmit > emitInterval * 3 {
            lastEmit = now
            peakSinceEmit = 0
            return
        }
        guard now >= nextEmit else { return }

        samples.append(AudioSample(time: nextEmit, level: peakSinceEmit))
        if samples.count > historySize { samples.removeFirst(samples.count - historySize) }
        lastEmit = nextEmit
        peakSinceEmit = 0
    }
}

final class DisplayLinkProxy: NSObject {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    @objc func fire() { callback() }
}
