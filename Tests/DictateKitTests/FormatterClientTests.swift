import Foundation
import Testing
@testable import DictateKit

/// 整形の要求の組み立て。サーバを立てずに、ヘッダと本文だけを見る（ADR-16）。
@Suite struct 整形の要求 {
    func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func このMacのサーバには鍵を付けずtemperatureと思考の指定を送る() throws {
        let request = try LLMClient(Config.Formatter()).makeRequest("本文")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try body(of: request)
        #expect(body["temperature"] as? Double == 0)
        #expect((body["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect(body["model"] as? String == Config.Formatter.smallModel)
    }

    @Test func オンラインのAPIには鍵を付けnullのtemperatureと思考の指定は送らない() throws {
        var settings = Config.Formatter()
        settings.endpoint = URL(string: "https://api.anthropic.com/v1")!
        settings.model = "claude-haiku-5-5"
        settings.apiKey = "sk-test"
        settings.temperature = nil
        settings.enableThinking = nil
        let request = try LLMClient(settings).makeRequest("本文")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        let body = try body(of: request)
        #expect(body["temperature"] == nil)
        #expect(body["chat_template_kwargs"] == nil)
        #expect(body["model"] as? String == "claude-haiku-5-5")
    }

    @Test func 応答のerrorのmessageを読み4xxは要求の誤りと分かる() {
        let object = LLMClient.ClientError.http(status: 400, body: Data(#"{"error": {"message": "temperature: must be 1", "type": "invalid_request_error"}}"#.utf8))
        #expect(object == .http(status: 400, message: "temperature: must be 1"))
        #expect(object.localizedDescription == "整形サーバが HTTP 400 を返しました（temperature: must be 1）")
        #expect(object.isRequestRejected)
        let text = LLMClient.ClientError.http(status: 401, body: Data(#"{"error": "invalid x-api-key"}"#.utf8))
        #expect(text == .http(status: 401, message: "invalid x-api-key"))
        let unknown = LLMClient.ClientError.http(status: 503, body: Data("loading".utf8))
        #expect(unknown == .http(status: 503, message: nil))
        #expect(unknown.localizedDescription == "整形サーバが HTTP 503 を返しました")
        #expect(!unknown.isRequestRejected)
        #expect(LLMClient.ClientError.http(status: 404, body: Data("<html>not found</html>".utf8)) == .http(status: 404, message: nil))
    }

    @Test(arguments: [(400, true), (401, true), (403, true), (404, true), (408, false), (429, false), (499, true), (500, false)])
    func 待っても直らないのは408と429を除く4xx(status: Int, rejected: Bool) {
        #expect(LLMClient.ClientError.http(status: status, message: nil).isRequestRejected == rejected)
    }

    @Test func 拒まれた要求は整形の結果に印が付き他の失敗には付かない() async {
        let rejected = await formatVerified("本文") { _ in throw LLMClient.ClientError.http(status: 401, message: "invalid x-api-key") }
        #expect(rejected.status == .unreachable)
        #expect(rejected.requestRejected)
        #expect(rejected.detail == "整形サーバが HTTP 401 を返しました（invalid x-api-key）")
        let loading = await formatVerified("本文") { _ in throw LLMClient.ClientError.http(status: 503, message: nil) }
        #expect(loading.status == .unreachable)
        #expect(!loading.requestRejected)
        let down = await formatVerified("本文") { _ in throw URLError(.cannotConnectToHost) }
        #expect(!down.requestRejected)
    }
}
