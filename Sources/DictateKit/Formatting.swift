import Foundation

/// 数値の区間を印に置き換える。LLM に数値と、数値に挟まれた記号を見せない。
public struct NumberMask: Sendable, Equatable {
    public let masked: String
    let originals: [String]

    public init(_ text: String) {
        var masked = ""
        var originals: [String] = []
        var cursor = text.startIndex
        let number = /[0-9０-９]+(?:[.,:\/\-．，：／][0-9０-９]+)*/
        for match in text.matches(of: number) {
            masked += text[cursor..<match.range.lowerBound]
            originals.append(String(match.output))
            masked += Self.placeholder(originals.count)
            cursor = match.range.upperBound
        }
        masked += text[cursor...]
        self.masked = masked
        self.originals = originals
    }

    static func placeholder(_ number: Int) -> String { "<N\(number)>" }

    /// 隣り合う数値の間が記号と空白だけなら、出力でも同じ並びであること。
    /// 句読点と空白の変更は許しているので、これが無いと「3、4人」が「34人」になる出力が通る。
    func keepsSeparators(in output: String) -> Bool {
        func gaps(_ text: String) -> [Substring]? {
            var result: [Substring] = []
            var rest = Substring(text)
            for index in originals.indices {
                guard let range = rest.range(of: Self.placeholder(index + 1)) else { return nil }
                if index > 0 { result.append(rest[..<range.lowerBound]) }
                rest = rest[range.upperBound...]
            }
            return result
        }
        guard let before = gaps(masked), let after = gaps(output) else { return false }
        return zip(before, after).allSatisfy { input, output in
            !input.allSatisfy { $0.isPunctuation || $0.isSymbol || $0.isWhitespace } || input == output
        }
    }

    /// 印が欠けた、増えた、順序が変わった出力は nil。
    public func unmask(_ output: String) -> String? {
        var result = ""
        var rest = Substring(output)
        for (index, original) in originals.enumerated() {
            guard let range = rest.range(of: Self.placeholder(index + 1)) else { return nil }
            result += rest[..<range.lowerBound]
            result += original
            rest = rest[range.upperBound...]
        }
        result += rest
        return result.contains(/<N[0-9]+>/) ? nil : result
    }
}

/// 禁止文では LLM の補完と脱落を止められないので、出力の側を構造で縛る。
/// 入力と出力の差分が句読点と空白の変更だけであることを確かめる（ADR-6）。
/// フィラーの削除は認めない。フィラーは規則が消し、LLM の役割は句読点と空白に限る（ADR-14）。
public enum FormatVerifier {
    static let punctuation: Set<Character> = ["、", "。", "，", "．", "！", "？", " ", "　", "\n", "\r", "\r\n", "\t"]

    public static func accepts(input: String, output: String) -> Bool {
        input.filter { !punctuation.contains($0) } == output.filter { !punctuation.contains($0) }
    }
}

public enum FormatStatus: String, Sendable, Codable, Equatable {
    case adopted
    case timedOut = "timed_out"
    case rejected
    case unreachable
}

public struct FormatResult: Sendable, Equatable {
    public let status: FormatStatus
    /// adopted なら検証と復元を済ませた文、rejected なら LLM の出力そのまま。
    public let output: String?
    public let detail: String?
    public let seconds: Double
    /// unreachable のうち、サーバが要求を 4xx で拒んだもの（鍵の失効、モデル名の誤り）。待っても直らないので、次の発話では試みない（ADR-16）。
    public let requestRejected: Bool

    public init(status: FormatStatus, output: String?, detail: String?, seconds: Double, requestRejected: Bool = false) {
        self.status = status
        self.output = output
        self.detail = detail
        self.seconds = seconds
        self.requestRejected = requestRejected
    }

    /// 予算内に届かなかった結果は採用しない。
    public func afterBudget() -> FormatResult {
        status == .adopted ? FormatResult(status: .timedOut, output: output, detail: nil, seconds: seconds) : self
    }
}

/// マスク → LLM → 差分検証 → 復元。検証を通らない出力は採用しない。
public func formatVerified(_ text: String, using llm: @Sendable (String) async throws -> String) async -> FormatResult {
    let clock = ContinuousClock()
    let started = clock.now
    func elapsed() -> Double { (clock.now - started).seconds }

    let mask = NumberMask(text)
    let output: String
    do {
        output = try await llm(mask.masked).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        let rejected = (error as? LLMClient.ClientError)?.isRequestRejected ?? false
        return FormatResult(status: .unreachable, output: nil, detail: error.localizedDescription, seconds: elapsed(), requestRejected: rejected)
    }
    guard FormatVerifier.accepts(input: mask.masked, output: output), mask.keepsSeparators(in: output),
          let restored = mask.unmask(output),
          // 句読点と空白だけの入力を空にした出力は採用しない（挿入するものが無くなる）
          restored.contains(where: { !FormatVerifier.punctuation.contains($0) })
    else {
        return FormatResult(status: .rejected, output: output, detail: nil, seconds: elapsed())
    }
    return FormatResult(status: .adopted, output: restored, detail: nil, seconds: elapsed())
}

/// 予算内に終われば結果を返し、超えれば nil を返す。超えても task は止めない（遅れた結果を履歴に残すため）。
/// TaskGroup で競わせると、`task.value` の待ちは取り消しに応じないので、グループが task の完了まで抜けない。
/// 先に届いた方だけを読んで戻る形にする（実測: 2 秒かかる task に予算 0.1 秒で、0.10 秒で nil が返る）。
public func outcome<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
    let race = AsyncStream<T?> { continuation in
        let value = Task { continuation.yield(await task.value) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            continuation.yield(nil)
        }
        continuation.onTermination = { _ in
            value.cancel()
            timer.cancel()
        }
    }
    for await first in race { return first }
    return nil
}

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// OpenAI 互換の chat completions を 1 発話 1 リクエストで呼ぶ。
public struct LLMClient: Sendable {
    public let settings: Config.Formatter

    public init(_ settings: Config.Formatter) {
        self.settings = settings
    }

    public enum ClientError: Error, LocalizedError, Equatable {
        /// message は応答の error.message（OpenAI 互換の形）。無ければ nil。
        case http(status: Int, message: String?)
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status, let message): "整形サーバが HTTP \(status) を返しました" + (message.map { "（\($0)）" } ?? "")
            case .malformedResponse(let detail): "整形サーバの応答を読めません: \(detail)"
            }
        }

        /// 4xx は要求の側の誤り（鍵、モデル名、項目）で、待っても直らない。モデルの読み込み中の失敗（5xx や接続の失敗）と分ける。
        /// 408（タイムアウト）と 429（レート制限）は時間がたてば直るので、拒否に数えない。
        public var isRequestRejected: Bool {
            if case .http(let status, _) = self { (400..<500).contains(status) && status != 408 && status != 429 } else { false }
        }

        /// 応答の本文から error.message を取り出す。`{"error": {"message": ...}}` と `{"error": "..."}` の両方を読む。
        static func http(status: Int, body: Data) -> ClientError {
            struct Body: Decodable {
                enum Detail: Decodable {
                    case object(message: String), text(String)
                    init(from decoder: Decoder) throws {
                        let container = try decoder.singleValueContainer()
                        if let text = try? container.decode(String.self) { self = .text(text); return }
                        struct Object: Decodable { let message: String }
                        self = .object(message: try container.decode(Object.self).message)
                    }
                    var message: String {
                        switch self {
                        case .object(let message), .text(let message): message
                        }
                    }
                }
                let error: Detail
            }
            return .http(status: status, message: (try? JSONDecoder().decode(Body.self, from: body))?.error.message)
        }
    }

    public static let defaultSystemPrompt = """
        あなたは音声入力の整形担当です。入力は音声認識の生テキストです。\
        句読点と空白を整えます。語は一字も変えず、消しません。<N1> のような印はそのまま残します。出力は本文だけ。
        """

    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        /// nil は項目ごと送らない（synthesized な Encodable は nil を省く）
        let temperature: Double?
        let max_tokens: Int
        let stream = false
        let chat_template_kwargs: [String: Bool]?
        let messages: [Message]
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    /// 整形の要求。鍵があれば Authorization に付ける。
    /// chat_template_kwargs（Qwen3 の思考の指定）は enableThinking が null なら送らない（ADR-16）
    func makeRequest(_ text: String) throws -> URLRequest {
        var request = URLRequest(url: settings.endpoint.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(Request(
            model: settings.model, temperature: settings.temperature, max_tokens: settings.maxTokens,
            chat_template_kwargs: settings.enableThinking.map { ["enable_thinking": $0] },
            messages: [
                .init(role: "system", content: settings.systemPrompt ?? Self.defaultSystemPrompt),
                .init(role: "user", content: text),
            ]
        ))
        return request
    }

    /// OpenAI 互換の口は Bearer を読む。Anthropic の /v1/models は本来の API で x-api-key を読む（鍵なしで 401 を実測）ので、同じ鍵を両方に付ける
    private func authorize(_ request: inout URLRequest) {
        guard let apiKey = settings.apiKey else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    }

    public func format(_ text: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: try makeRequest(text))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(status: http.statusCode, body: data)
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ClientError.malformedResponse("\(error)")
        }
        guard let content = decoded.choices.first?.message.content else {
            throw ClientError.malformedResponse("choices が空です")
        }
        return content
    }

    /// 設定の表示用。到達できるかだけを見る。
    /// 200 を求めるのは、この Mac のポートを別の HTTP サーバが使っているときに「到達」と見なさないため（起動コマンドが Address already in use で失敗し、原因が分かる）。
    /// 外の接続先は TLS の往復に 0.3〜0.5 秒かかる（実測）ので、待ちを長くする
    public func isReachable() async -> Bool {
        var request = URLRequest(url: settings.endpoint.appending(path: "models"))
        request.timeoutInterval = settings.isLocal ? 1 : 5
        authorize(&request)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
