@preconcurrency import AVFoundation

/// マイクを機器の形式のまま流す。形式の変換は LiveTranscriber が持つ。
@MainActor
public final class MicrophoneCapture {
    // 発話の間に入力機器が変わると、古い形式のままタップを付け直すことになる。発話ごとに作り直す
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    public init() {}

    public func start() throws -> AsyncStream<AudioChunk> {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechCoreError.microphoneUnavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        Self.installTap(on: input, format: format, yieldingTo: continuation)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        self.engine = engine
        self.continuation = continuation
        return stream
    }

    /// タップの処理は音声用のスレッドから呼ばれる。このクラス（メインアクター）のメソッドの中で installTap に
    /// クロージャを直接渡すと、メインアクターで呼ばれる前提の実行時検査が差し込まれ、最初のバッファで強制終了する。
    nonisolated static func installTap(on node: AVAudioNode, format: AVAudioFormat?, yieldingTo continuation: AsyncStream<AudioChunk>.Continuation) {
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            continuation.yield(AudioChunk(buffer))
        }
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
    }
}
