import Foundation

public struct Config: Sendable, Equatable, Codable {
    public struct Hotkey: Sendable, Equatable, Codable {
        public enum Modifier: String, Sendable, Codable, CaseIterable {
            case control, option, shift, command

            public var symbol: String {
                switch self {
                case .control: "⌃"
                case .option: "⌥"
                case .shift: "⇧"
                case .command: "⌘"
                }
            }
        }

        public enum Trigger: Sendable, Equatable {
            /// 仮想キーコード。
            case key(code: UInt32)
            /// 0 が左、1 が右、2 が中ボタン、3 以降がサイドボタン。
            case mouse(button: Int)
        }

        public enum Problem: Error, LocalizedError, Equatable {
            case primaryMouseButton
            case modifierKeyAlone
            case needsModifier

            public var errorDescription: String? {
                switch self {
                case .primaryMouseButton: "左クリックと右クリックは登録できません。クリックができなくなります。"
                case .modifierKeyAlone: "修飾キーだけの登録はできません。他のキーかマウスボタンと組み合わせてください。"
                case .needsModifier: "このキーには ⌃、⌥、⌘ のどれかが要ります。単独で登録すると、その文字が打てなくなります。"
                }
            }
        }

        public var trigger = Trigger.key(code: 2)
        public var modifiers: [Modifier] = [.control, .option, .command]

        public init() {}

        public init(trigger: Trigger, modifiers: [Modifier]) {
            self.trigger = trigger
            // 表示と保存の順をそろえる
            self.modifiers = Modifier.allCases.filter(modifiers.contains)
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case type, code, button, modifiers }
        private enum Kind: String, Codable { case key, mouse }

        public init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, known: CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let trigger: Trigger = switch try container.decode(Kind.self, forKey: .type) {
            case .key: .key(code: try container.decode(UInt32.self, forKey: .code))
            case .mouse: .mouse(button: try container.decode(Int.self, forKey: .button))
            }
            self.init(trigger: trigger, modifiers: try container.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? [])
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch trigger {
            case .key(let code):
                try container.encode(Kind.key, forKey: .type)
                try container.encode(code, forKey: .code)
            case .mouse(let button):
                try container.encode(Kind.mouse, forKey: .type)
                try container.encode(button, forKey: .button)
            }
            try container.encode(modifiers, forKey: .modifiers)
        }

        /// 登録できない理由。登録の窓と設定の読み込みで同じ規則を使う。
        public var problem: Problem? {
            switch trigger {
            case .mouse(let button):
                return button < 2 ? .primaryMouseButton : nil
            case .key(let code):
                if Self.modifierKeyCodes.contains(code) { return .modifierKeyAlone }
                // ⇧ だけでは大文字や記号が打てなくなる
                let hasCommandModifier = modifiers.contains { $0 != .shift }
                return hasCommandModifier || Self.functionKeyCodes.contains(code) ? nil : .needsModifier
            }
        }

        public var displayName: String {
            let prefix = modifiers.map(\.symbol).joined()
            switch trigger {
            case .key(let code): return prefix + (Self.keyNames[code] ?? "キーコード \(code)")
            case .mouse(let button): return prefix + (button == 2 ? "中ボタン" : "マウスボタン \(button + 1)")
            }
        }

        static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        static let functionKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

        /// ANSI 配列の仮想キーコードの呼び名。表に無いキーも登録でき、番号で表示する。
        static let keyNames: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
            14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
            39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Forward Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            102: "英数", 104: "かな",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
    }

    public struct Formatter: Sendable, Equatable, Codable {
        public var enabled = false
        public var endpoint = URL(string: "http://127.0.0.1:8124/v1")!
        public var model = "mlx-community/Qwen3-8B-4bit"
        /// 確定からこの秒数以内に検証済みの結果が届かなければ、整形前の文を挿入する。
        public var budgetSeconds = 1.0
        public var temperature = 0.0
        public var maxTokens = 512
        /// Qwen3 など、思考を出力するモデルで思考を止める指定を付ける。
        public var enableThinking = false
        /// nil なら組み込みのプロンプトを使う。変えても、検証を通るのはフィラーの削除と句読点の変更だけ。
        public var systemPrompt: String?
        /// 整形をオンにしたときに接続できなければ、アプリがこのコマンドでサーバを起動する（ログインシェルで実行）。
        /// nil なら起動せず、接続できないと知らせるだけ。
        public var startCommand: String?

        public init() {}

        public init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, known: CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
            endpoint = try container.decodeIfPresent(URL.self, forKey: .endpoint) ?? endpoint
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
            budgetSeconds = try container.decodeIfPresent(Double.self, forKey: .budgetSeconds) ?? budgetSeconds
            temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
            maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? maxTokens
            enableThinking = try container.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? enableThinking
            systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            startCommand = try container.decodeIfPresent(String.self, forKey: .startCommand)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(enabled, forKey: .enabled)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(model, forKey: .model)
            try container.encode(budgetSeconds, forKey: .budgetSeconds)
            try container.encode(temperature, forKey: .temperature)
            try container.encode(maxTokens, forKey: .maxTokens)
            try container.encode(enableThinking, forKey: .enableThinking)
            // 項目があることが設定ファイルから分かるように、未設定でも null で書き出す
            try container.encode(systemPrompt, forKey: .systemPrompt)
            try container.encode(startCommand, forKey: .startCommand)
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case enabled, endpoint, model, budgetSeconds, temperature, maxTokens, enableThinking, systemPrompt, startCommand
        }

        var problem: String? {
            if !(budgetSeconds > 0 && budgetSeconds <= 30) { return "formatter.budgetSeconds が範囲外です（現在 \(budgetSeconds)）。0 より大きく 30 以下にしてください。" }
            if !(temperature >= 0 && temperature <= 2) { return "formatter.temperature が範囲外です（現在 \(temperature)）。0 以上 2 以下にしてください。" }
            if !(1...4096).contains(maxTokens) { return "formatter.maxTokens が範囲外です（現在 \(maxTokens)）。1 以上 4096 以下にしてください。" }
            if let startCommand, startCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "formatter.startCommand が空です。使わないなら null にしてください。" }
            return nil
        }
    }

    public struct History: Sendable, Equatable, Codable {
        public var enabled = true

        public init() {}

        public init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, known: CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case enabled }
    }

    public var hotkey = Hotkey()
    public var formatter = Formatter()
    public var history = History()
    public var alwaysPasteBundleIds: [String] = []
    /// 挿入のたびに Shift+Return を送る。1 回の発話を 1 行にする。
    public var newlineAfterUtterance = false

    public init() {}

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? hotkey
        formatter = try container.decodeIfPresent(Formatter.self, forKey: .formatter) ?? formatter
        history = try container.decodeIfPresent(History.self, forKey: .history) ?? history
        alwaysPasteBundleIds = try container.decodeIfPresent([String].self, forKey: .alwaysPasteBundleIds) ?? alwaysPasteBundleIds
        newlineAfterUtterance = try container.decodeIfPresent(Bool.self, forKey: .newlineAfterUtterance) ?? newlineAfterUtterance
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case hotkey, formatter, history, alwaysPasteBundleIds, newlineAfterUtterance }

    public enum LoadError: Error, LocalizedError, Equatable {
        case unreadable(path: String, detail: String)
        case invalid(path: String, detail: String)
        case hotkey(Hotkey.Problem)
        case formatter(String)

        public var errorDescription: String? {
            func name(_ path: String) -> String { URL(filePath: path).lastPathComponent }
            return switch self {
            case .unreadable(let path, let detail): "\(name(path)) を読めません。\(detail)"
            case .invalid(let path, let detail): "\(name(path)) の書式が正しくありません。該当の項目は \(detail)"
            case .hotkey(let problem): "config.json の hotkey は使えません。\(problem.localizedDescription)"
            case .formatter(let problem): problem
            }
        }
    }

    /// ファイルが無ければ既定値。壊れていれば既定値に読み替えず、箇所を示して失敗する。
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(path: url.path, detail: error.localizedDescription)
        }
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch let error as DecodingError {
            throw LoadError.invalid(path: url.path, detail: describe(error))
        } catch {
            throw LoadError.invalid(path: url.path, detail: error.localizedDescription)
        }
        if let problem = config.hotkey.problem { throw LoadError.hotkey(problem) }
        if let problem = config.formatter.problem { throw LoadError.formatter(problem) }
        return config
    }

    /// 設定を読み、変更を加えて、全項目を書き出す。メニューと登録の窓からの変更に使う。
    /// 書き出すと全項目が現在の値で並ぶので、手で直すときは違うところだけ直せばよい。
    /// 既存のファイルが壊れているときは上書きせずに失敗する（本人が書いた内容を消さない）。
    public static func update(at url: URL, _ change: (inout Config) -> Void = { _ in }) throws {
        var config = try load(from: url)
        change(&config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // .prettyPrinted は空の配列を "[\n\n  ]" と書く。手で直すファイルなので "[]" に潰す
        let json = String(decoding: try encoder.encode(config), as: UTF8.self)
            .replacing(/\[\s+\]/, with: "[]")
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).joined(separator: ".")
            return keys.isEmpty ? context.debugDescription : "\(keys): \(context.debugDescription)"
        }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
            return path(context)
        @unknown default:
            return "\(error)"
        }
    }
}

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// キー名の打ち間違いを既定値に読み替えない。
private func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(_ decoder: Decoder, known: Keys.Type) throws {
    let container = try decoder.container(keyedBy: AnyKey.self)
    let names = Set(Keys.allCases.map(\.stringValue))
    guard let unknown = container.allKeys.first(where: { !names.contains($0.stringValue) }) else { return }
    throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath + [unknown],
        debugDescription: "知らない項目です。使える項目は \(names.sorted().joined(separator: ", ")) です。"
    ))
}

public enum AppPaths {
    public static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Dictate", directoryHint: .isDirectory)
    }
    public static var config: URL { directory.appending(path: "config.json") }
    public static var dictionary: URL { directory.appending(path: "dictionary.tsv") }
    public static var history: URL { directory.appending(path: "history.jsonl") }
    public static var formatterLog: URL { directory.appending(path: "formatter.log") }
}
