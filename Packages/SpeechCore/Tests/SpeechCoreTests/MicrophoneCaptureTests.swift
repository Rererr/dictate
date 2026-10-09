@preconcurrency import AVFoundation
import Testing
@testable import SpeechCore

@Suite struct MicrophoneCaptureTests {
    /// AVAudioEngine はタップの処理を音声用のスレッドから呼ぶ。
    /// メインアクターの検査が差し込まれていると、最初のバッファでテストのプロセスごと落ちる。
    /// マイクを使わずに同じ経路を通すため、オフラインの手動レンダリングでミキサーにタップを付ける。
    @MainActor @Test(.timeLimit(.minutes(1))) func タップの処理は音声用のスレッドから呼ばれても音声を流す() async throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        MicrophoneCapture.installTap(on: engine.mainMixerNode, format: nil, yieldingTo: continuation)
        try engine.start()

        let output = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        for _ in 0..<8 { _ = try engine.renderOffline(4096, to: output) }

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect((first?.buffer.frameLength ?? 0) > 0)
        engine.stop()
    }
}
