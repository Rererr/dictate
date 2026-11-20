import Foundation
import SpeechCore

public enum InsertionMethod: String, Sendable, Codable, Equatable {
    case ax, paste, none
}

public struct UtteranceRecord: Sendable, Codable, Equatable {
    public struct RunRecord: Sendable, Codable, Equatable {
        public let text: String
        public let confidence: Double?
        public let start: Double?
        public let end: Double?

        public init(_ run: Run) {
            text = run.text
            confidence = run.confidence
            start = run.timeRange?.lowerBound
            end = run.timeRange?.upperBound
        }
    }

    public struct ReplacementRecord: Sendable, Codable, Equatable {
        public let original: String
        public let surface: String
    }

    public struct Insertion: Sendable, Codable, Equatable {
        public let method: InsertionMethod
        public let reason: String?
        /// 貼り付けの後に入力欄が変わったか（paste のみ）。nil は読めなかった、または貼り付けでない。
        /// false なら入ったと確かめられず、Return は送らない（§5）。
        public let pasteConfirmed: Bool?
        /// 確認にかかった時間や、届かなかった回の手がかり。人が読むためのもので、判定には使わない。
        public let detail: String?

        public init(method: InsertionMethod, reason: String?, pasteConfirmed: Bool? = nil, detail: String? = nil) {
            self.method = method
            self.reason = reason
            self.pasteConfirmed = pasteConfirmed
            self.detail = detail
        }
    }

    /// 秒。キーを離す → 確定 → 後処理の完了 → 挿入の完了。
    public struct Timings: Sendable, Codable, Equatable {
        public let releaseToFinal: Double
        public let postprocess: Double
        public let insert: Double

        public init(releaseToFinal: Double, postprocess: Double, insert: Double) {
            self.releaseToFinal = releaseToFinal
            self.postprocess = postprocess
            self.insert = insert
        }
    }

    public private(set) var type = "utterance"
    public let id: String
    public let startedAt: Date
    public let recordingSeconds: Double
    public let raw: String
    public let runs: [RunRecord]
    public let afterDictionary: String
    public let replacements: [ReplacementRecord]
    public let command: VoiceCommand?
    public let inserted: String
    public let insertion: Insertion
    public let app: String?
    public let timings: Timings
    /// 認識器（ADR-19）。§7.2 の再計測で、どちらの認識器の発話かを履歴から分けるため。古い履歴には無い
    public let recognizer: LiveTranscriber.Engine?

    public init(
        id: String, startedAt: Date, recordingSeconds: Double, raw: String, runs: [Run], post: Postprocessed,
        inserted: String, insertion: Insertion, app: String?, timings: Timings, recognizer: LiveTranscriber.Engine? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.recordingSeconds = recordingSeconds
        self.raw = raw
        self.runs = runs.map(RunRecord.init)
        self.afterDictionary = post.afterDictionary
        self.replacements = post.replacements.map { ReplacementRecord(original: $0.original, surface: $0.surface) }
        self.command = post.command
        self.inserted = inserted
        self.insertion = insertion
        self.app = app
        self.timings = timings
        self.recognizer = recognizer
    }
}

public struct FormatRecord: Sendable, Codable, Equatable {
    public private(set) var type = "format"
    public let utteranceId: String
    public let status: FormatStatus
    public let output: String?
    public let detail: String?
    public let seconds: Double

    public init(utteranceId: String, result: FormatResult) {
        self.utteranceId = utteranceId
        status = result.status
        output = result.output
        detail = result.detail
        seconds = result.seconds
    }
}

/// 履歴の読み取り。辞書の行を提案するときに、読みの出現を数えるためだけに読む。
public enum HistoryReader {
    private struct Line: Decodable {
        let type: String
        let inserted: String?
    }

    /// 挿入した文を、今のファイルと繰り越し分（`.1`）から集める。読めない行は飛ばす（履歴は本人の文で、1 行の崩れで全体を止めない）。
    public static func insertedTexts(at url: URL) -> [String] {
        [url.appendingPathExtension("1"), url].flatMap { file -> [String] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            return data.split(separator: 0x0A).compactMap { line in
                guard let record = try? JSONDecoder().decode(Line.self, from: line), record.type == "utterance" else { return nil }
                return record.inserted
            }
        }
    }
}

/// 1 行 1 イベントの追記専用。行の書き換えと削除はしない。
/// 上限を超えたらファイルごと `.1` に繰り越す（話した全文が無期限に溜まらないように）。
public struct HistoryWriter: Sendable {
    public let url: URL
    /// この大きさ（バイト）を超えていたら、書く前に繰り越す。nil なら上限なし。
    public let rotateAtBytes: UInt64?

    public init(url: URL, rotateAtBytes: UInt64? = nil) {
        self.url = url
        self.rotateAtBytes = rotateAtBytes
    }

    /// 繰り越し先。前の繰り越し分は上書きで消える。
    public var rotatedURL: URL { url.appendingPathExtension("1") }

    public func append(_ record: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let limit = rotateAtBytes,
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64, size >= limit {
            if FileManager.default.fileExists(atPath: rotatedURL.path) { try FileManager.default.removeItem(at: rotatedURL) }
            try FileManager.default.moveItem(at: url, to: rotatedURL)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
