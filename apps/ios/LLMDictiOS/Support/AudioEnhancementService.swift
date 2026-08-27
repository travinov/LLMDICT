import Accelerate
import AVFoundation
import Foundation

struct AudioEnhancementReport: Sendable, Equatable {
    let inputRMSDecibels: Double
    let outputRMSDecibels: Double
    let outputPeakDecibels: Double
    let normalizationGainDecibels: Double
}

enum AudioEnhancementError: LocalizedError {
    case emptyAudio
    case unsupportedAudio
    case processingFailed(stage: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "Аудиофайл не содержит звука. Исходная запись сохранена."
        case .unsupportedAudio:
            return "Формат аудио не поддерживает локальную обработку. Исходная запись сохранена."
        case let .processingFailed(stage, reason):
            return "Не удалось выполнить этап «\(stage)»: \(reason). Исходная запись сохранена."
        }
    }
}

/// Offline, bounded-memory speech enhancement. The original file is never modified.
actor AudioEnhancementService {
    private static let targetRMS = amplitude(decibels: -18)
    // Extra sample-peak headroom protects against inter-sample peaks after 16-bit export.
    private static let peakCeiling = amplitude(decibels: -4)
    // Spectral cleanup can remove steady energy before normalization; keep enough headroom
    // to return quiet microphone speech to the target loudness. The limiter remains final.
    private static let maximumMakeupGain = amplitude(decibels: 24)
    private let framesPerChunk: AVAudioFrameCount = 8_192
    private let spectralFrameSize = 512
    private let spectralHopSize = 256

    func enhance(
        sourceURL: URL,
        destinationURL: URL,
        denoiseStrength: Double = 0.5
    ) throws -> AudioEnhancementReport {
        let fileManager = FileManager.default
        let workingDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let identifier = UUID().uuidString
        let denoisedURL = workingDirectory.appendingPathComponent(".enhancement-\(identifier)-denoised.wav")
        let intermediateURL = workingDirectory.appendingPathComponent(".enhancement-\(identifier)-stage.wav")
        let candidateURL = workingDirectory.appendingPathComponent(".enhancement-\(identifier)-result.wav")
        defer {
            try? fileManager.removeItem(at: denoisedURL)
            try? fileManager.removeItem(at: intermediateURL)
            try? fileManager.removeItem(at: candidateURL)
        }

        let inputAnalysis: Analysis
        do {
            inputAnalysis = try analyze(url: sourceURL)
        } catch let error as AudioEnhancementError {
            throw error
        } catch {
            throw AudioEnhancementError.processingFailed(stage: "анализ", reason: error.localizedDescription)
        }
        guard inputAnalysis.sampleCount > 0 else { throw AudioEnhancementError.emptyAudio }

        do {
            let spectralNoisePower = try estimateSpectralNoise(url: sourceURL)
            try spectralDenoise(
                sourceURL: sourceURL,
                destinationURL: denoisedURL,
                noisePower: spectralNoisePower,
                strength: min(1, max(0, denoiseStrength))
            )
            try preprocess(
                sourceURL: denoisedURL,
                destinationURL: intermediateURL,
                noiseFloor: inputAnalysis.noiseFloor
            )
        } catch let error as AudioEnhancementError {
            throw error
        } catch {
            throw AudioEnhancementError.processingFailed(stage: "фильтрация", reason: error.localizedDescription)
        }

        let processedAnalysis: Analysis
        do {
            processedAnalysis = try analyze(url: intermediateURL)
        } catch let error as AudioEnhancementError {
            throw error
        } catch {
            throw AudioEnhancementError.processingFailed(stage: "контроль уровня", reason: error.localizedDescription)
        }
        guard processedAnalysis.sampleCount > 0 else { throw AudioEnhancementError.emptyAudio }

        let rmsGain = processedAnalysis.rms > 0 ? Self.targetRMS / processedAnalysis.rms : 1
        let normalizationGain = min(rmsGain, Self.maximumMakeupGain)

        do {
            try normalizeAndLimit(
                sourceURL: intermediateURL,
                destinationURL: candidateURL,
                gain: normalizationGain
            )
        } catch let error as AudioEnhancementError {
            throw error
        } catch {
            throw AudioEnhancementError.processingFailed(stage: "нормализация", reason: error.localizedDescription)
        }

        let outputAnalysis = try analyze(url: candidateURL)
        do {
            try install(candidateURL: candidateURL, at: destinationURL)
        } catch {
            throw AudioEnhancementError.processingFailed(stage: "сохранение", reason: error.localizedDescription)
        }

        return AudioEnhancementReport(
            inputRMSDecibels: Self.decibels(amplitude: inputAnalysis.rms),
            outputRMSDecibels: Self.decibels(amplitude: outputAnalysis.rms),
            outputPeakDecibels: Self.decibels(amplitude: outputAnalysis.peak),
            normalizationGainDecibels: Self.decibels(amplitude: normalizationGain)
        )
    }

    private func estimateSpectralNoise(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              format.isInterleaved == false,
              format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk),
              let setup = vDSP_DFT_zop_CreateSetup(
                  nil,
                  vDSP_Length(spectralFrameSize),
                  vDSP_DFT_Direction.FORWARD
              ) else {
            throw AudioEnhancementError.unsupportedAudio
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        let histogramBinCount = 72
        let positiveBinCount = (spectralFrameSize / 2) + 1
        var histograms = Array(
            repeating: [Int](repeating: 0, count: histogramBinCount),
            count: positiveBinCount
        )
        let window = spectralWindow()
        var realInput = [Float](repeating: 0, count: spectralFrameSize)
        var imaginaryInput = [Float](repeating: 0, count: spectralFrameSize)
        var realOutput = [Float](repeating: 0, count: spectralFrameSize)
        var imaginaryOutput = [Float](repeating: 0, count: spectralFrameSize)
        var pending: [Float] = []
        pending.reserveCapacity(Int(framesPerChunk) + spectralFrameSize)
        var pendingStart = 0
        var frameCount = 0

        func collectFrame(start: Int) {
            for index in 0..<spectralFrameSize {
                realInput[index] = pending[start + index] * window[index]
                imaginaryInput[index] = 0
            }
            vDSP_DFT_Execute(setup, realInput, imaginaryInput, &realOutput, &imaginaryOutput)
            let inverseFrameSize = 1 / Float(spectralFrameSize)
            for bin in 0..<positiveBinCount {
                let real = realOutput[bin] * inverseFrameSize
                let imaginary = imaginaryOutput[bin] * inverseFrameSize
                let power = max((real * real) + (imaginary * imaginary), 1e-12)
                let decibels = max(-120, min(0, 10 * log10(Double(power))))
                let scaled = (decibels + 120) / 120
                let histogramIndex = min(
                    histogramBinCount - 1,
                    max(0, Int((scaled * Double(histogramBinCount - 1)).rounded()))
                )
                histograms[bin][histogramIndex] += 1
            }
            frameCount += 1
        }

        while file.framePosition < file.length {
            try Task.checkCancellation()
            let readCount = AVAudioFrameCount(
                min(AVAudioFramePosition(framesPerChunk), file.length - file.framePosition)
            )
            try file.read(into: buffer, frameCount: readCount)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw AudioEnhancementError.unsupportedAudio
            }
            for frame in 0..<count {
                var mixed: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    mixed += channels[channel][frame]
                }
                pending.append(mixed / Float(format.channelCount))
            }
            while pending.count - pendingStart >= spectralFrameSize {
                collectFrame(start: pendingStart)
                pendingStart += spectralHopSize
            }
            if pendingStart > 0 {
                pending.removeFirst(pendingStart)
                pendingStart = 0
            }
        }

        if frameCount == 0 || pending.isEmpty == false {
            pending.append(contentsOf: repeatElement(0, count: max(0, spectralFrameSize - pending.count)))
            collectFrame(start: 0)
        }

        let percentileTarget = max(1, Int(ceil(Double(frameCount) * 0.2)))
        return histograms.map { histogram in
            var cumulative = 0
            var selectedIndex = 0
            for (index, count) in histogram.enumerated() {
                cumulative += count
                if cumulative >= percentileTarget {
                    selectedIndex = index
                    break
                }
            }
            let decibels = -120 + (120 * Double(selectedIndex) / Double(histogramBinCount - 1))
            return Float(pow(10, decibels / 10))
        }
    }

    private func spectralDenoise(
        sourceURL: URL,
        destinationURL: URL,
        noisePower: [Float],
        strength: Double
    ) throws {
        try autoreleasepool {
            let input = try AVAudioFile(forReading: sourceURL)
            let inputFormat = input.processingFormat
            guard inputFormat.commonFormat == .pcmFormatFloat32,
                  inputFormat.isInterleaved == false,
                  inputFormat.channelCount > 0,
                  noisePower.count == (spectralFrameSize / 2) + 1,
                  let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerChunk),
                  let monoFormat = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: inputFormat.sampleRate,
                      channels: 1,
                      interleaved: false
                  ),
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: framesPerChunk),
                  let forwardSetup = vDSP_DFT_zop_CreateSetup(
                      nil,
                      vDSP_Length(spectralFrameSize),
                      vDSP_DFT_Direction.FORWARD
                  ),
                  let inverseSetup = vDSP_DFT_zop_CreateSetup(
                      forwardSetup,
                      vDSP_Length(spectralFrameSize),
                      vDSP_DFT_Direction.INVERSE
                  ) else {
                throw AudioEnhancementError.unsupportedAudio
            }
            defer {
                vDSP_DFT_DestroySetup(inverseSetup)
                vDSP_DFT_DestroySetup(forwardSetup)
            }

            let output = try makeWaveFile(url: destinationURL, processingFormat: monoFormat)
            let window = spectralWindow()
            let positiveBinCount = (spectralFrameSize / 2) + 1
            let floorGain = Float(Self.amplitude(decibels: -18 * strength))
            let oversubtraction = Float(0.8 + (1.4 * strength))

            var realInput = [Float](repeating: 0, count: spectralFrameSize)
            var imaginaryInput = [Float](repeating: 0, count: spectralFrameSize)
            var realSpectrum = [Float](repeating: 0, count: spectralFrameSize)
            var imaginarySpectrum = [Float](repeating: 0, count: spectralFrameSize)
            var inverseReal = [Float](repeating: 0, count: spectralFrameSize)
            var inverseImaginary = [Float](repeating: 0, count: spectralFrameSize)
            var rawGains = [Float](repeating: 1, count: positiveBinCount)
            var smoothedGains = [Float](repeating: 1, count: positiveBinCount)
            var previousGains = [Float](repeating: 1, count: positiveBinCount)
            var overlap = [Float](repeating: 0, count: spectralFrameSize)
            var pending = [Float](repeating: 0, count: spectralHopSize)
            pending.reserveCapacity(Int(framesPerChunk) + spectralFrameSize)
            var pendingStart = 0
            var timelinePosition = -spectralHopSize
            var outputBufferCount = 0
            var writtenSampleCount: AVAudioFramePosition = 0
            let requiredSampleCount = input.length
            let inverseFrameSize = 1 / Float(spectralFrameSize)

            func flushOutputBuffer() throws {
                guard outputBufferCount > 0 else { return }
                outputBuffer.frameLength = AVAudioFrameCount(outputBufferCount)
                try output.write(from: outputBuffer)
                outputBufferCount = 0
            }

            func appendOutput(_ sample: Float) throws {
                guard let outputChannel = outputBuffer.floatChannelData?[0] else {
                    throw AudioEnhancementError.unsupportedAudio
                }
                outputChannel[outputBufferCount] = sample
                outputBufferCount += 1
                writtenSampleCount += 1
                if outputBufferCount == Int(framesPerChunk) {
                    try flushOutputBuffer()
                }
            }

            func processFrame(start: Int) throws {
                for index in 0..<spectralFrameSize {
                    realInput[index] = pending[start + index] * window[index]
                    imaginaryInput[index] = 0
                }
                vDSP_DFT_Execute(forwardSetup, realInput, imaginaryInput, &realSpectrum, &imaginarySpectrum)

                for bin in 0..<positiveBinCount {
                    let real = realSpectrum[bin] * inverseFrameSize
                    let imaginary = imaginarySpectrum[bin] * inverseFrameSize
                    let power = max((real * real) + (imaginary * imaginary), 1e-12)
                    let speechToNoise = max(0, power / max(noisePower[bin], 1e-12) - 1)
                    rawGains[bin] = max(
                        floorGain,
                        speechToNoise / (speechToNoise + oversubtraction)
                    )
                }

                for bin in 0..<positiveBinCount {
                    var sum: Float = 0
                    var count: Float = 0
                    for neighbor in max(0, bin - 2)...min(positiveBinCount - 1, bin + 2) {
                        sum += rawGains[neighbor]
                        count += 1
                    }
                    let frequencySmoothed = sum / count
                    let timeCoefficient: Float = frequencySmoothed < previousGains[bin] ? 0.72 : 0.35
                    smoothedGains[bin] = (timeCoefficient * previousGains[bin])
                        + ((1 - timeCoefficient) * frequencySmoothed)
                }
                previousGains = smoothedGains

                for bin in 0..<positiveBinCount {
                    realSpectrum[bin] *= smoothedGains[bin]
                    imaginarySpectrum[bin] *= smoothedGains[bin]
                    if bin > 0, bin < spectralFrameSize / 2 {
                        let mirror = spectralFrameSize - bin
                        realSpectrum[mirror] *= smoothedGains[bin]
                        imaginarySpectrum[mirror] *= smoothedGains[bin]
                    }
                }

                vDSP_DFT_Execute(
                    inverseSetup,
                    realSpectrum,
                    imaginarySpectrum,
                    &inverseReal,
                    &inverseImaginary
                )
                for index in 0..<spectralFrameSize {
                    overlap[index] += inverseReal[index] * inverseFrameSize * window[index]
                }

                for index in 0..<spectralHopSize {
                    if timelinePosition >= 0, writtenSampleCount < requiredSampleCount {
                        try appendOutput(overlap[index])
                    }
                    timelinePosition += 1
                }
                for index in 0..<spectralHopSize {
                    overlap[index] = overlap[index + spectralHopSize]
                    overlap[index + spectralHopSize] = 0
                }
            }

            while input.framePosition < input.length {
                try Task.checkCancellation()
                let readCount = AVAudioFrameCount(
                    min(AVAudioFramePosition(framesPerChunk), input.length - input.framePosition)
                )
                try input.read(into: inputBuffer, frameCount: readCount)
                let count = Int(inputBuffer.frameLength)
                guard count > 0 else { break }
                guard let channels = inputBuffer.floatChannelData else {
                    throw AudioEnhancementError.unsupportedAudio
                }
                for frame in 0..<count {
                    var mixed: Float = 0
                    for channel in 0..<Int(inputFormat.channelCount) {
                        mixed += channels[channel][frame]
                    }
                    pending.append(mixed / Float(inputFormat.channelCount))
                }
                while pending.count - pendingStart >= spectralFrameSize {
                    try processFrame(start: pendingStart)
                    pendingStart += spectralHopSize
                }
                if pendingStart > 0 {
                    pending.removeFirst(pendingStart)
                    pendingStart = 0
                }
            }

            while writtenSampleCount < requiredSampleCount {
                if pending.count < spectralFrameSize {
                    pending.append(contentsOf: repeatElement(0, count: spectralFrameSize - pending.count))
                }
                try processFrame(start: 0)
                pending.removeFirst(min(spectralHopSize, pending.count))
            }
            try flushOutputBuffer()
        }
    }

    private func spectralWindow() -> [Float] {
        (0..<spectralFrameSize).map { index in
            sqrt(Float(0.5 - (0.5 * cos((2 * Double.pi * Double(index)) / Double(spectralFrameSize)))))
        }
    }

    private func analyze(url: URL) throws -> Analysis {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              format.isInterleaved == false,
              format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk) else {
            throw AudioEnhancementError.unsupportedAudio
        }

        var sumOfSquares = 0.0
        var peak = 0.0
        var sampleCount = 0
        var noiseHistogram = [Int](repeating: 0, count: 121)
        var blockCount = 0

        while file.framePosition < file.length {
            try Task.checkCancellation()
            let readCount = AVAudioFrameCount(
                min(AVAudioFramePosition(framesPerChunk), file.length - file.framePosition)
            )
            try file.read(into: buffer, frameCount: readCount)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw AudioEnhancementError.unsupportedAudio
            }

            var blockSquares = 0.0
            for frame in 0..<frameCount {
                var sample: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    sample += channels[channel][frame]
                }
                sample /= Float(format.channelCount)
                let value = Double(sample)
                blockSquares += value * value
                peak = max(peak, abs(value))
            }

            sumOfSquares += blockSquares
            sampleCount += frameCount
            let blockRMS = sqrt(blockSquares / Double(frameCount))
            let blockDecibels = max(-120, min(0, Self.decibels(amplitude: blockRMS)))
            noiseHistogram[Int(blockDecibels + 120)] += 1
            blockCount += 1
        }

        let rms = sampleCount > 0 ? sqrt(sumOfSquares / Double(sampleCount)) : 0
        let noiseFloor: Double
        if blockCount == 0 {
            noiseFloor = 0
        } else {
            let percentileIndex = max(1, blockCount / 5)
            var cumulativeCount = 0
            var selectedBin = 0
            for (bin, count) in noiseHistogram.enumerated() {
                cumulativeCount += count
                if cumulativeCount >= percentileIndex {
                    selectedBin = bin
                    break
                }
            }
            noiseFloor = Self.amplitude(decibels: Double(selectedBin) - 120)
        }
        return Analysis(rms: rms, peak: peak, noiseFloor: noiseFloor, sampleCount: sampleCount)
    }

    private func preprocess(sourceURL: URL, destinationURL: URL, noiseFloor: Double) throws {
        try autoreleasepool {
            let input = try AVAudioFile(forReading: sourceURL)
            let inputFormat = input.processingFormat
            guard inputFormat.commonFormat == .pcmFormatFloat32,
                  inputFormat.isInterleaved == false,
                  inputFormat.channelCount > 0,
                  let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerChunk),
                  let monoFormat = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: inputFormat.sampleRate,
                      channels: 1,
                      interleaved: false
                  ),
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: framesPerChunk) else {
                throw AudioEnhancementError.unsupportedAudio
            }

            let output = try makeWaveFile(url: destinationURL, processingFormat: monoFormat)
            let sampleRate = inputFormat.sampleRate
            let highPassAlpha = Self.highPassAlpha(cutoff: 80, sampleRate: sampleRate)
            let expanderThreshold = min(
                max(noiseFloor * 2.5, Self.amplitude(decibels: -54)),
                Self.amplitude(decibels: -38)
            )
            let expanderFloor = Self.amplitude(decibels: -15)
            let expanderAttack = Self.smoothingCoefficient(seconds: 0.006, sampleRate: sampleRate)
            let expanderRelease = Self.smoothingCoefficient(seconds: 0.16, sampleRate: sampleRate)
            let compressorThresholdDB = -24.0
            let compressorRatio = 3.0
            let compressorAttack = Self.smoothingCoefficient(seconds: 0.008, sampleRate: sampleRate)
            let compressorRelease = Self.smoothingCoefficient(seconds: 0.18, sampleRate: sampleRate)

            var previousInput = 0.0
            var previousHighPassed = 0.0
            var expanderEnvelope = 0.0
            var compressorEnvelope = 0.0

            while input.framePosition < input.length {
                try Task.checkCancellation()
                let readCount = AVAudioFrameCount(
                    min(AVAudioFramePosition(framesPerChunk), input.length - input.framePosition)
                )
                try input.read(into: inputBuffer, frameCount: readCount)
                let frameCount = Int(inputBuffer.frameLength)
                guard frameCount > 0 else { break }
                guard let inputChannels = inputBuffer.floatChannelData,
                      let outputChannel = outputBuffer.floatChannelData?[0] else {
                    throw AudioEnhancementError.unsupportedAudio
                }

                outputBuffer.frameLength = AVAudioFrameCount(frameCount)
                for frame in 0..<frameCount {
                    var mixed: Float = 0
                    for channel in 0..<Int(inputFormat.channelCount) {
                        mixed += inputChannels[channel][frame]
                    }
                    mixed /= Float(inputFormat.channelCount)

                    let currentInput = Double(mixed)
                    let highPassed = highPassAlpha * (previousHighPassed + currentInput - previousInput)
                    previousInput = currentInput
                    previousHighPassed = highPassed

                    let magnitude = abs(highPassed)
                    expanderEnvelope = Self.followEnvelope(
                        current: magnitude,
                        previous: expanderEnvelope,
                        attack: expanderAttack,
                        release: expanderRelease
                    )
                    let expanderPosition = min(1, expanderEnvelope / expanderThreshold)
                    let expanderGain = expanderFloor + ((1 - expanderFloor) * expanderPosition * expanderPosition)
                    let expanded = highPassed * expanderGain

                    compressorEnvelope = Self.followEnvelope(
                        current: abs(expanded),
                        previous: compressorEnvelope,
                        attack: compressorAttack,
                        release: compressorRelease
                    )
                    let envelopeDB = Self.decibels(amplitude: compressorEnvelope)
                    let compressionDB = envelopeDB > compressorThresholdDB
                        ? -(envelopeDB - compressorThresholdDB) * (1 - (1 / compressorRatio))
                        : 0
                    let compressed = expanded * Self.amplitude(decibels: compressionDB)
                    outputChannel[frame] = Float(compressed)
                }
                try output.write(from: outputBuffer)
            }
        }
    }

    private func normalizeAndLimit(sourceURL: URL, destinationURL: URL, gain: Double) throws {
        try autoreleasepool {
            let input = try AVAudioFile(forReading: sourceURL)
            let format = input.processingFormat
            guard format.commonFormat == .pcmFormatFloat32,
                  format.isInterleaved == false,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk) else {
                throw AudioEnhancementError.unsupportedAudio
            }
            let output = try makeWaveFile(url: destinationURL, processingFormat: format)
            let limiterRelease = Self.smoothingCoefficient(seconds: 0.08, sampleRate: format.sampleRate)
            var limiterGain = 1.0

            while input.framePosition < input.length {
                try Task.checkCancellation()
                let readCount = AVAudioFrameCount(
                    min(AVAudioFramePosition(framesPerChunk), input.length - input.framePosition)
                )
                try input.read(into: buffer, frameCount: readCount)
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { break }
                guard let channel = buffer.floatChannelData?[0] else {
                    throw AudioEnhancementError.unsupportedAudio
                }

                for frame in 0..<frameCount {
                    let amplified = Double(channel[frame]) * gain
                    let requiredGain = abs(amplified) > Self.peakCeiling
                        ? Self.peakCeiling / abs(amplified)
                        : 1
                    if requiredGain < limiterGain {
                        limiterGain = requiredGain
                    } else {
                        limiterGain = (limiterRelease * limiterGain) + ((1 - limiterRelease) * 1)
                    }
                    let limited = amplified * limiterGain
                    channel[frame] = Float(max(-Self.peakCeiling, min(Self.peakCeiling, limited)))
                }
                try output.write(from: buffer)
            }
        }
    }

    private func makeWaveFile(url: URL, processingFormat: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: Int(processingFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        return try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    private func install(candidateURL: URL, at destinationURL: URL) throws {
        let fileManager = FileManager.default
        let backupURL = destinationURL.appendingPathExtension("backup")
        try? fileManager.removeItem(at: backupURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.moveItem(at: destinationURL, to: backupURL)
        }

        do {
            try fileManager.moveItem(at: candidateURL, to: destinationURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            throw error
        }
    }

    private struct Analysis {
        let rms: Double
        let peak: Double
        let noiseFloor: Double
        let sampleCount: Int
    }

    private static func highPassAlpha(cutoff: Double, sampleRate: Double) -> Double {
        let timeConstant = 1 / (2 * Double.pi * cutoff)
        let sampleInterval = 1 / sampleRate
        return timeConstant / (timeConstant + sampleInterval)
    }

    private static func smoothingCoefficient(seconds: Double, sampleRate: Double) -> Double {
        exp(-1 / (seconds * sampleRate))
    }

    private static func followEnvelope(
        current: Double,
        previous: Double,
        attack: Double,
        release: Double
    ) -> Double {
        let coefficient = current > previous ? attack : release
        return (coefficient * previous) + ((1 - coefficient) * current)
    }

    private static func amplitude(decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    private static func decibels(amplitude: Double) -> Double {
        20 * log10(max(amplitude, 0.000_000_001))
    }
}
