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

/// 整形の出力が「句読点と空白の変更」と「フィラーの削除」だけでできているかを確かめる。
/// 禁止文では LLM の補完と脱落を止められないので、出力の側を構造で縛る。
public enum FormatVerifier {
    static let punctuation: Set<Character> = ["、", "。", "，", "．", "！", "？", " ", "　", "\n", "\r", "\r\n", "\t"]
    static let fillers = ["えっと", "えーっと", "えーと", "ええと", "えー", "あのー"]
    /// 連体詞や副詞としても使う語。生テキストで直後に読点があるときだけフィラーとみなす。
    static let fillersBeforeComma = ["あの", "その", "まあ", "なんか"]

    public static func accepts(input: String, output: String) -> Bool {
        let source = Array(input)
        // 句読点と空白を除いた文字と、その生テキスト上の位置
        let kept = source.indices.filter { !punctuation.contains(source[$0]) }
        let target = output.filter { !punctuation.contains($0) }.map { $0 }
        var memo: [[Bool?]] = Array(repeating: Array(repeating: nil, count: target.count + 1), count: kept.count + 1)

        func deletableLength(at i: Int, _ filler: String, requiresComma: Bool) -> Int? {
            let characters = Array(filler)
            guard i + characters.count <= kept.count else { return nil }
            for (offset, character) in characters.enumerated() {
                let position = kept[i + offset]
                // フィラーは生テキスト上で連続していること（句読点をまたがない）
                if source[position] != character || position != kept[i] + offset { return nil }
            }
            if requiresComma {
                let next = kept[i] + characters.count
                guard next < source.count, source[next] == "、" || source[next] == "，" else { return nil }
            }
            return characters.count
        }

        func matches(_ i: Int, _ j: Int) -> Bool {
            if let known = memo[i][j] { return known }
            var result = false
            if i == kept.count {
                result = j == target.count
            } else {
                if j < target.count, source[kept[i]] == target[j] { result = matches(i + 1, j + 1) }
                if !result {
                    // 同じ位置で当たるフィラーは最も長いものだけを認める。
                    // 短い方も認めると「えーと」の「えー」だけを削って「と」を残す出力が通る
                    let candidates = fillers.map { ($0, false) } + fillersBeforeComma.map { ($0, true) }
                    let longest = candidates.compactMap { deletableLength(at: i, $0.0, requiresComma: $0.1) }.max()
                    if let longest { result = matches(i + longest, j) }
                }
            }
            memo[i][j] = result
            return result
        }
        return matches(0, 0)
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
        return FormatResult(status: .unreachable, output: nil, detail: error.localizedDescription, seconds: elapsed())
    }
    guard FormatVerifier.accepts(input: mask.masked, output: output), mask.keepsSeparators(in: output),
          let restored = mask.unmask(output),
          // フィラーだけの発話を空にした出力は採用しない（挿入するものが無くなる）
          restored.contains(where: { !FormatVerifier.punctuation.contains($0) })
    else {
        return FormatResult(status: .rejected, output: output, detail: nil, seconds: elapsed())
    }
    return FormatResult(status: .adopted, output: restored, detail: nil, seconds: elapsed())
}

/// 予算内に終われば結果を返す。超えても task は止めない（遅れた結果を履歴に残すため）。
public func outcome<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await task.value }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        defer { group.cancelAll() }
        return await group.next() ?? nil
    }
}

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// OpenAI 互換の chat completions を 1 発話 1 リクエストで呼ぶ。
public struct LLMClient: Sendable {
    public let endpoint: URL
    public let model: String

    public init(endpoint: URL, model: String) {
        self.endpoint = endpoint
        self.model = model
    }

    public enum ClientError: Error, LocalizedError {
        case http(status: Int)
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status): "整形サーバが HTTP \(status) を返しました"
            case .malformedResponse(let detail): "整形サーバの応答を読めません: \(detail)"
            }
        }
    }

    static let systemPrompt = """
        あなたは音声入力の整形担当です。入力は音声認識の生テキストです。\
        フィラー（えっと、えー、あのー、あの、その、まあ、なんか）を取り除き、句読点を整えます。\
        それ以外の語は一字も変えません。<N1> のような印はそのまま残します。出力は本文だけ。
        """

    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let temperature = 0
        let max_tokens = 512
        let stream = false
        let chat_template_kwargs = ["enable_thinking": false]
        let messages: [Message]
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    public func format(_ text: String) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: [
            .init(role: "system", content: Self.systemPrompt),
            .init(role: "user", content: text),
        ]))
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(status: http.statusCode)
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
    public func isReachable() async -> Bool {
        var request = URLRequest(url: endpoint.appending(path: "models"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
