import Foundation

public struct Run: Sendable, Equatable {
    public let text: String
    /// 部分結果には付かない。確定結果でも認識器が返さない run では nil。
    public let confidence: Double?
    public let timeRange: ClosedRange<TimeInterval>?

    public init(text: String, confidence: Double?, timeRange: ClosedRange<TimeInterval>?) {
        self.text = text
        self.confidence = confidence
        self.timeRange = timeRange
    }
}

public struct FinalSegment: Sendable, Equatable {
    public let runs: [Run]

    public init(runs: [Run]) {
        self.runs = runs
    }

    public var text: String { runs.map(\.text).joined() }
}

public enum TranscriptEvent: Sendable, Equatable {
    case volatile(String)
    case final(FinalSegment)
}

/// 1 回の発話で届くイベントを「いまの全文」に畳む。確定は区間ごとに複数届く。
public struct TranscriptAccumulator: Sendable, Equatable {
    public private(set) var finals: [FinalSegment] = []
    public private(set) var volatile = ""

    public init() {}

    public mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .volatile(let text):
            volatile = text
        case .final(let segment):
            finals.append(segment)
            volatile = ""
        }
    }

    public var finalText: String { finals.map(\.text).joined() }
    public var text: String { finalText + volatile }
    public var runs: [Run] { finals.flatMap(\.runs) }
}

public enum SpeechCoreError: Error, LocalizedError, Equatable {
    case modelNotInstalled(localeIdentifier: String)
    case noCompatibleAudioFormat
    case converterUnavailable(from: String, to: String)
    case conversionFailed(String)
    case microphoneUnavailable
    /// 入力が 1 つも届かずに終わった（キーを一瞬だけ押した場合など）。
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let id):
            "音声認識モデル（\(id)）が導入されていません。システム設定 > キーボード > 音声入力で、言語を追加してください。"
        case .noCompatibleAudioFormat:
            "認識器が受け取れる音声形式を取得できません。"
        case .converterUnavailable(let from, let to):
            "音声形式を変換できません（\(from) → \(to)）。"
        case .conversionFailed(let detail):
            "音声形式の変換に失敗しました。\(detail)"
        case .noAudio:
            "音声が届く前に入力が終わりました。"
        case .microphoneUnavailable:
            "マイクの入力形式を取得できません。入力機器が接続されているか確認してください。"
        }
    }
}
