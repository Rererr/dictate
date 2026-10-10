import Foundation
import Testing
@testable import DictateKit

/// 実際の mlx_lm.server を、アプリと同じ経路（FormatterServer で起動 → 接続確認 → 温め → 整形 → 停止 → 接続不可）で通す。
/// モデルの読み込みに数秒から数分かかり、mlx-lm とモデルのキャッシュが要るので、環境変数 DICTATE_LLM_E2E=1 のときだけ走る。
/// 動作中の Dictate が使うポート（8124）には触らず、別のポートで自分のサーバを立てる。
@Suite(.serialized) struct 整形サーバの実機 {
    static let optedIn = ProcessInfo.processInfo.environment["DICTATE_LLM_E2E"] == "1"
    static let port = 8130

    static func settings() -> Config.Formatter {
        var formatter = Config.Formatter()
        formatter.endpoint = URL(string: "http://127.0.0.1:\(port)/v1")!
        formatter.startCommand = Config.Formatter.defaultStartCommand(model: Config.Formatter.smallModel)
            .replacingOccurrences(of: "--port 8124", with: "--port \(port)")
        return formatter
    }

    @MainActor @Test(
        .enabled(if: optedIn, "DICTATE_LLM_E2E=1 のときだけ走る"),
        .enabled("mlx_lm.server が無い") { await FormatterServer.isExecutableAvailable(settings().startCommand ?? "") },
        .timeLimit(.minutes(5))
    )
    func 起動から整形と停止までがアプリと同じ経路で通る() async throws {
        let settings = Self.settings()
        let client = LLMClient(settings)
        #expect(await !client.isReachable(), "テスト用のポートが空いていること（前回の残りがあれば止める）")

        let log = FileManager.default.temporaryDirectory.appending(path: "dictate-llm-e2e-\(UUID().uuidString)/formatter.log")
        let server = FormatterServer(logURL: log)
        try server.start(command: try #require(settings.startCommand))
        defer { server.stop() }

        // 待ち受けが開くまで（アプリは 60 秒で諦める）
        var opened = false
        for _ in 0..<60 where !opened {
            try await Task.sleep(for: .seconds(1))
            opened = await client.isReachable()
        }
        #expect(opened, "60 秒以内に待ち受けが開く。ログ: \(log.path)")
        server.markRunning()

        // 温め: 読み込みが終わるまで短い要求を繰り返す（アプリは 10 秒おき）
        var warm = false
        for _ in 0..<30 where !warm {
            warm = (try? await client.format("えっと、準備です")) != nil
            if !warm { try await Task.sleep(for: .seconds(5)) }
        }
        #expect(warm, "モデルの読み込みが終わり、整形の要求が通る")

        // 整形: 本物のモデルで、検証を通るか棄却されるかのどちらか（届かないことは無い）
        let result = await formatVerified("えっと、本番デプロイは15時からでいいですか", using: client.format)
        #expect(result.status == .adopted || result.status == .rejected, "出力: \(result.output ?? "nil") 詳細: \(result.detail ?? "")")
        if result.status == .adopted {
            #expect(result.output?.contains("15時") == true, "数値は印から元に戻る")
            #expect(result.output?.contains("えっと") == false, "フィラーが消える")
        }
        #expect(result.seconds < 10, "温まった状態の所要（\(result.seconds) 秒）")

        // 停止: 戻った時点で届かず、整形は接続不可になる
        await server.stopAndWait()
        #expect(server.state == .stopped)
        #expect(await !client.isReachable())
        let afterStop = await formatVerified("了解です", using: client.format)
        #expect(afterStop.status == .unreachable)
    }
}
