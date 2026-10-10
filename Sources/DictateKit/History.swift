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

        public init(method: InsertionMethod, reason: String?) {
            self.method = method
            self.reason = reason
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

    public init(
        id: String, startedAt: Date, recordingSeconds: Double, raw: String, runs: [Run], post: Postprocessed,
        inserted: String, insertion: Insertion, app: String?, timings: Timings
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
