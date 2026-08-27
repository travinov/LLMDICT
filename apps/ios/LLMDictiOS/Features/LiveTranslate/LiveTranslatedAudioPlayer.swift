import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class LiveTranslatedAudioPlayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?

    private(set) var isPlaying = false

    func play(pcm16: Data, sampleRate: Int = 24_000) async throws {
        guard pcm16.isEmpty == false else { return }

        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let wav = Self.wavData(pcm16: pcm16, sampleRate: sampleRate)
        let player = try AVAudioPlayer(data: wav)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            throw LiveTranslateError.playbackFailed
        }

        self.player = player
        isPlaying = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func playFile(url: URL) async throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            throw LiveTranslateError.playbackFailed
        }

        self.player = player
        isPlaying = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        continuation?.resume()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }

    private static func wavData(pcm16: Data, sampleRate: Int) -> Data {
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let subchunk2Size = UInt32(pcm16.count)
        let chunkSize = UInt32(36 + pcm16.count)

        var data = Data()
        data.append("RIFF")
        data.append(chunkSize.littleEndianData)
        data.append("WAVE")
        data.append("fmt ")
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(byteRate).littleEndianData)
        data.append(blockAlign.littleEndianData)
        data.append(bitsPerSample.littleEndianData)
        data.append("data")
        data.append(subchunk2Size.littleEndianData)
        data.append(pcm16)
        return data
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
