@preconcurrency import AVFoundation
import Foundation
import Speech

/// SpeechTranscriber のライブ認識。音源を問わず、任意の形式のバッファ列を受ける。
public struct LiveTranscriber: Sendable {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: "ja-JP")) {
        self.locale = locale
    }

    /// 入力ストリームが終わると確定まで進み、結果ストリームも終わる。
    /// 結果ストリームの消費をやめると認識も打ち切る。
    public func start(input: AsyncStream<AudioChunk>) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // .fastResults が無いと部分結果は文末までまとめて届く
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        // 未導入のときに取得を要求しない。ダウンロードは利用者の承認事項。
        guard await isModelInstalled() else {
            throw SpeechCoreError.modelNotInstalled(localeIdentifier: locale.identifier)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechCoreError.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (analyzerInput, analyzerInputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: analyzerInput)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await result in transcriber.results {
                                continuation.yield(Self.event(from: result))
                            }
                        }
                        group.addTask {
                            defer { analyzerInputContinuation.finish() }
                            var converter = BufferConverter(to: format)
                            var received = 0
                            for await chunk in input {
                                analyzerInputContinuation.yield(AnalyzerInput(buffer: try converter.convert(chunk.buffer)))
                                received += 1
                            }
                            analyzerInputContinuation.finish()
                            try Task.checkCancellation()
                            // 音声を 1 つも渡さずに確定させると、認識器の結果ストリームが終わらない
                            guard received > 0 else { throw SpeechCoreError.noAudio }
                            try await analyzer.finalizeAndFinishThroughEndOfInput()
                        }
                        // waitForAll は片方が失敗しても残りを待ち続ける。最初の失敗で抜けて残りを取り消す
                        while try await group.next() != nil {}
                    }
                    continuation.finish()
                } catch {
                    await analyzer.cancelAndFinishNow()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// このロケールの認識モデルが端末に入っているか。
    /// AssetInventory.status は導入済みで認識できる状態でも .supported を返すので使わない。
    public func isModelInstalled() async -> Bool {
        let target = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == target }
    }

    private static func event(from result: SpeechTranscriber.Result) -> TranscriptEvent {
        guard result.isFinal else {
            return .volatile(String(result.text.characters))
        }
        let runs = result.text.runs.map { run in
            Run(
                text: String(result.text[run.range].characters),
                confidence: run.transcriptionConfidence,
                timeRange: run.audioTimeRange.map { $0.start.seconds...max($0.start.seconds, $0.end.seconds) }
            )
        }
        return .final(FinalSegment(runs: runs))
    }
}

/// 音声バッファの受け渡し単位。AVAudioPCMBuffer は Sendable でないので、
/// 流した後は書き換えない約束で包む。
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private struct BufferConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to target: AVAudioFormat) {
        self.target = target
    }

    mutating func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format {
            guard let created = AVAudioConverter(from: buffer.format, to: target) else {
                throw SpeechCoreError.converterUnavailable(from: "\(buffer.format)", to: "\(target)")
            }
            converter = created
        }
        guard let converter else { preconditionFailure("converter is set above") }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SpeechCoreError.conversionFailed("出力バッファを確保できません（\(capacity) フレーム）")
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw SpeechCoreError.conversionFailed(conversionError.localizedDescription)
        }
        return output
    }
}
