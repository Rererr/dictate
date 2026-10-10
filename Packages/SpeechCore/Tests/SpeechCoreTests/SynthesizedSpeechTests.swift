@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import SpeechCore

/// 合成音声を LiveTranscriber に流し、認識から確定までが通ることを確かめる。
/// 音源は OS の `say`（日本語の声）で、音声ファイルはリポジトリに置かない。
/// 日本語の認識モデルか日本語の声が無い Mac では走らせない（導入の条件であって、コードの不具合ではない）。
@Suite(.serialized) struct 合成音声の認識 {
    static let voice = "Kyoko"

    static func hasJapaneseVoice() -> Bool {
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "?"]
        let output = Pipe()
        say.standardOutput = output
        say.standardError = FileHandle.nullDevice
        guard (try? say.run()) != nil else { return false }
        say.waitUntilExit()
        let voices = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return voices.split(separator: "\n").contains { $0.hasPrefix(voice) && $0.contains("ja_JP") }
    }

    static func synthesize(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictate-say-\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw SpeechCoreError.conversionFailed("say が \(say.terminationStatus) で終了") }
        return url
    }

    /// ファイルをマイクと同じ大きさに小分けにする。
    static func buffers(of url: URL) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let frames: AVAudioFrameCount = 2048
        var chunks: [AudioChunk] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            chunks.append(AudioChunk(buffer))
        }
        return chunks
    }

    /// 小分けにしたものを流し、終える（キーを離したのと同じ）。
    static func chunks(of url: URL) throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        for chunk in try buffers(of: url) { continuation.yield(chunk) }
        continuation.finish()
        return stream
    }

    static func transcribe(_ text: String) async throws -> TranscriptAccumulator {
        let url = try synthesize(text)
        defer { try? FileManager.default.removeItem(at: url) }
        var accumulator = TranscriptAccumulator()
        for try await event in try await LiveTranscriber().start(input: try chunks(of: url)) {
            accumulator.apply(event)
        }
        return accumulator
    }

    /// 表記の揺れ（句読点、送り仮名、数字の書き方）を読みに畳んで比べる。
    static func reading(_ text: String) -> String {
        let stripped = text.filter { !$0.isPunctuation && !$0.isWhitespace }
        return YomiDictionary.reading(of: stripped)
    }

    @Test(
        .enabled(if: hasJapaneseVoice(), "日本語の声（\(voice)）が無い"),
        .enabled("日本語の認識モデルが未導入") { await LiveTranscriber().isModelInstalled() },
        .timeLimit(.minutes(2)),
        arguments: ["今日は晴れです", "明日の朝一でレビューをお願いします", "ステージングで再現できました"]
    )
    func 合成音声を流すと同じ読みの文が確定する(text: String) async throws {
        let accumulator = try await Self.transcribe(text)
        #expect(accumulator.finals.count >= 1)
        #expect(accumulator.volatile.isEmpty, "確定の後に部分結果が残らない")
        #expect(Self.reading(accumulator.finalText) == Self.reading(text), "認識: \(accumulator.finalText)")
        #expect(accumulator.runs.allSatisfy { $0.timeRange != nil }, "確定結果の run には時刻が付く")
    }

    @Test(
        .enabled(if: hasJapaneseVoice(), "日本語の声（\(voice)）が無い"),
        .enabled("日本語の認識モデルが未導入") { await LiveTranscriber().isModelInstalled() },
        .timeLimit(.minutes(2))
    )
    func 結果の消費をやめると入力の消費も止まる() async throws {
        let url = try Self.synthesize("この文は最後まで読まれません")
        defer { try? FileManager.default.removeItem(at: url) }
        // 入力は終えない（キーを押したまま）。結果を手放したときに、入力の側の待ちが取り消されることを見る
        let (input, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let inputTerminated = Mutex(false)
        continuation.onTermination = { _ in inputTerminated.withLock { $0 = true } }
        for chunk in try Self.buffers(of: url) { continuation.yield(chunk) }
        do {
            let results = try await LiveTranscriber().start(input: input)
            var iterator = results.makeAsyncIterator()
            _ = try await iterator.next()
        }
        // results と iterator を手放した。onTermination で認識のタスクが取り消され、入力の読み取りも終わる
        for _ in 0..<50 where !inputTerminated.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(inputTerminated.withLock { $0 }, "結果を手放しても入力を読み続けている（取り消しが伝わっていない）")
    }
}
