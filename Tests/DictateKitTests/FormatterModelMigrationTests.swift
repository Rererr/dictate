import Foundation
import Testing
@testable import DictateKit

/// テストごとに作り、後始末で一時の設定の場所を消す
@Suite final class 以前の既定の整形モデルからの移行 {
    static let legacyCommand = #"mlx_lm.server --model mlx-community/Qwen3-4B-4bit --port 8124 --chat-template-args '{\"enable_thinking\": false}'"#
    static let largeCommand = #"mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8124 --chat-template-args '{\"enable_thinking\": false}'"#
    static let currentCommand = #"mlx_lm.server --model mlx-community/Qwen3.5-4B-MLX-4bit --port 8124 --chat-template-args '{\"enable_thinking\": false}'"#

    /// v0.2.0 がメニューの切り替えで書き出した形（全項目、apiKey と recognizer はまだ無い）。model と startCommand と endpoint だけを差し替える
    static func v020(model: String = "mlx-community/Qwen3-4B-4bit", startCommand: String = legacyCommand, endpoint: String = "http://127.0.0.1:8124/v1") -> String {
        """
        {
          "alwaysPasteBundleIds" : [],
          "editor" : null,
          "formatter" : {
            "budgetSeconds" : 1.5,
            "enableThinking" : false,
            "enabled" : true,
            "endpoint" : "\(endpoint)",
            "maxTokens" : 512,
            "model" : "\(model)",
            "startCommand" : "\(startCommand)",
            "systemPrompt" : null,
            "temperature" : 0
          },
          "history" : { "enabled" : true, "maxMegabytes" : 20 },
          "hotkey" : { "code" : 120, "modifiers" : [], "type" : "key" },
          "newlineAfterUtterance" : true,
          "removeFillers" : false
        }
        """
    }

    let root = FileManager.default.temporaryDirectory.appending(path: "dictate-migration-\(UUID().uuidString)")
    var directory: URL { root.appending(path: "Dictate") }
    var url: URL { directory.appending(path: "config.json") }
    var marker: URL { directory.appending(path: FormatterModelMigration.markerName) }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ json: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    func contents() throws -> Data { try Data(contentsOf: url) }
    var marked: Bool { FileManager.default.fileExists(atPath: marker.path) }

    @Test func 以前の既定の組は今の既定の組に書き換え他の項目は残す() throws {
        try write(Self.v020())
        var expected = try Config.load(from: url)
        expected.formatter.model = Config.Formatter.smallModel
        expected.formatter.startCommand = Config.Formatter.defaultStartCommand(model: Config.Formatter.smallModel)
        #expect(try FormatterModelMigration.run(config: url) == expected.formatter)
        let config = try Config.load(from: url)
        #expect(config == expected)
        #expect(config.formatter.usesDefaultServer)
        #expect(marked)
    }

    @Test(arguments: [
        ("8B の組（以前の版で上げた、公開前の既定、手で 8B にした）", v020(model: "mlx-community/Qwen3-8B-4bit", startCommand: largeCommand)),
        ("本人が書いた起動コマンド", v020(startCommand: "my_server --port 8124")),
        ("起動しない（空文字）", v020(startCommand: "")),
        ("この Mac 以外の接続先", v020(endpoint: "http://192.168.1.10:8124/v1")),
        ("モデルだけ Qwen3-4B（起動コマンドは今の既定）", v020(startCommand: currentCommand)),
        ("すでに今の既定の組", v020(model: "mlx-community/Qwen3.5-4B-MLX-4bit", startCommand: currentCommand)),
    ])
    func 本人が変えた設定と今の組には触らず確かめた印だけ付ける(_ case: String, json: String) throws {
        try write(json)
        let before = try contents()
        #expect(try FormatterModelMigration.run(config: url) == nil, "\(`case`)")
        #expect(try contents() == before, "\(`case`)")
        #expect(marked, "\(`case`)")
    }

    @Test func 設定ファイルが無ければ何も作らない() throws {
        #expect(try FormatterModelMigration.run(config: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "設定の場所も印も作らない")
    }

    @Test func 一度確かめたらQwen3の4Bに戻した設定を書き換え直さない() throws {
        try write(Self.v020())
        #expect(try FormatterModelMigration.run(config: url) != nil)
        // 本人が手引きどおりに Qwen3-4B へ戻した
        try write(Self.v020())
        let reverted = try contents()
        #expect(try FormatterModelMigration.run(config: url) == nil)
        #expect(try contents() == reverted)
    }

    @Test func 印を消すと確かめ直す() throws {
        try write(Self.v020())
        #expect(try FormatterModelMigration.run(config: url) != nil)
        try write(Self.v020())
        try FileManager.default.removeItem(at: marker)
        #expect(try FormatterModelMigration.run(config: url) != nil)
    }

    @Test func 読めない設定は書き換えず印も付けない() throws {
        try write(#"{"formatter": {"model": "#)
        let before = try contents()
        #expect(throws: Config.LoadError.self) { try FormatterModelMigration.run(config: url) }
        #expect(try contents() == before)
        #expect(!marked)
        // 直した後の起動で確かめ直す
        try write(Self.v020())
        #expect(try FormatterModelMigration.run(config: url) != nil)
    }

    @Test func 書き戻せなければ印を付けず次で確かめ直す() throws {
        try write(Self.v020())
        let before = try contents()
        // 場所は書けるまま、config.json だけを置き換えられなくする（印は書ける状態で、印を付けないことを見る）
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        // 途中で抜けても外す（残すと後始末の削除が黙って失敗し、一時の場所に消しにくいファイルが残る）
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        #expect(throws: (any Error).self) { try FormatterModelMigration.run(config: url) }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        #expect(try contents() == before)
        #expect(!marked)
        #expect(try FormatterModelMigration.run(config: url) != nil)
    }
}
