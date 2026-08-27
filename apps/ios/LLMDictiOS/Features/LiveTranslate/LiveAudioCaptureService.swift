import AVFoundation
import Foundation

final class LiveAudioCaptureService: @unchecked Sendable {
    private static let targetSampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let levelLock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var startedAt: Date?
    private var maxDurationTask: Task<Void, Never>?
    private var currentMicLevel: Double = 0

    private(set) var isCapturing = false

    var micLevel: Double {
        levelLock.withLock { currentMicLevel }
    }

    func start(maxDuration: TimeInterval) async throws -> AsyncThrowingStream<Data, Error> {
        guard isCapturing == false else {
            throw LiveTranslateError.microphoneUnavailable
        }

        guard try await requestPermission() else {
            throw LiveTranslateError.microphoneUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            self.continuation = continuation
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_400, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let pcm = Self.pcm16Data(from: buffer, targetSampleRate: Self.targetSampleRate)
            let level = Self.normalizedLevel(from: buffer)
            self.setMicLevel(level)
            if pcm.isEmpty == false {
                self.continuation?.yield(pcm)
            }
        }

        engine.prepare()
        try engine.start()
        startedAt = .now
        isCapturing = true
        startDurationLimit(maxDuration)
        return stream
    }

    func stop() async {
        await stop(gracePeriod: .milliseconds(420))
    }

    private func stop(gracePeriod: Duration) async {
        guard isCapturing else { return }
        try? await Task.sleep(for: gracePeriod)
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        startedAt = nil
        setMicLevel(0)
        isCapturing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func cancel() async {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish(throwing: CancellationError())
        continuation = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        startedAt = nil
        setMicLevel(0)
        isCapturing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setMicLevel(_ value: Double) {
        levelLock.withLock {
            currentMicLevel = value
        }
    }

    private func startDurationLimit(_ maxDuration: TimeInterval) {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            let nanoseconds = UInt64(max(1, maxDuration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self?.stop()
        }
    }

    private func requestPermission() async throws -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    nonisolated private static func pcm16Data(from buffer: AVAudioPCMBuffer, targetSampleRate: Double) -> Data {
        guard let channelData = buffer.floatChannelData else { return Data() }
        let channel = channelData[0]
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }

        let sourceSampleRate = buffer.format.sampleRate
        let outputFrames = max(1, Int((Double(frames) * targetSampleRate / sourceSampleRate).rounded()))
        var data = Data(capacity: outputFrames * MemoryLayout<Int16>.size)

        for outputIndex in 0..<outputFrames {
            let sourcePosition = Double(outputIndex) * sourceSampleRate / targetSampleRate
            let lowerIndex = min(frames - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upperIndex = min(frames - 1, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            let interpolated = channel[lowerIndex] + ((channel[upperIndex] - channel[lowerIndex]) * fraction)
            let clamped = max(-1, min(1, interpolated))
            var sample = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }

        return data
    }

    nonisolated private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channel = channelData[0]
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frames {
            sum += channel[index] * channel[index]
        }

        let rms = sqrt(sum / Float(frames))
        return Double(max(0, min(1, pow(rms * 7.5, 0.72))))
    }
}
