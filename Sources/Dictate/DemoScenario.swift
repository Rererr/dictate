import DictateKit
import SpeechCore

/// 字幕とトーストの目視確認用。実動作と同じ文言を、台本どおりの間隔で出す。
struct DemoScenario {
    enum Action {
        case caption(Overlay.CaptionKind, String)
        case closeCaption
        case toast(String)
    }

    struct Step {
        let after: Duration
        let action: Action
    }

    let title: String
    let steps: [Step]

    private static let utterance = "さっきの件、明日の朝一でレビューお願いできますか。本番デプロイは15時からの予定なので、それまでに見てもらえると助かります"

    /// 0.1 秒ごとに数文字ずつ伸びる部分結果と、キーを離した後の「確定中」。
    private static var speaking: [Step] {
        var steps = [Step(after: .zero, action: .caption(.recording, Messages.listening))]
        var end = utterance.startIndex
        while end < utterance.endIndex {
            end = utterance.index(end, offsetBy: 3, limitedBy: utterance.endIndex) ?? utterance.endIndex
            steps.append(Step(after: .milliseconds(100), action: .caption(.recording, String(utterance[..<end]))))
        }
        return steps + [Step(after: .milliseconds(400), action: .caption(.working, Messages.finalizing))]
    }

    private static let formatting = [Step(after: .milliseconds(100), action: .caption(.working, Messages.formatting))]

    /// 字幕を閉じ、理由があればトーストを出す。
    private static func ending(_ toast: String? = nil, after: Duration = .milliseconds(100)) -> [Step] {
        [Step(after: after, action: .closeCaption)] + (toast.map { [Step(after: .zero, action: .toast($0))] } ?? [])
    }

    static let all: [DemoScenario] = [
        .init(title: "デモ: 話して挿入（成功。字幕が閉じるだけ）", steps: speaking + ending()),
        .init(title: "デモ: 整形あり（0.6 秒で成功）", steps: speaking + formatting + ending(after: .milliseconds(600))),
        .init(title: "デモ: 整形が 1 秒に間に合わない", steps: speaking + formatting + ending(Messages.formatSkipped(.timedOut), after: .seconds(1))),
        .init(title: "デモ: 整形を検証で棄却", steps: speaking + formatting + ending(Messages.formatSkipped(.rejected), after: .milliseconds(700))),
        .init(title: "デモ: 整形サーバに接続できない", steps: speaking + formatting + ending(Messages.formatSkipped(.unreachable), after: .milliseconds(50))),
        .init(title: "デモ: 挿入を確認できない", steps: speaking + ending(Messages.unverified)),
        .init(title: "デモ: 挿入を確認できず送信を見送り", steps: speaking + ending(Messages.unverifiedNotSent)),
        .init(title: "デモ: アクセシビリティの許可なし", steps: speaking + ending(Messages.accessibilityDenied)),
        .init(title: "デモ: マイクの許可なし", steps: [Step(after: .zero, action: .toast(Messages.microphoneDenied))]),
        toast("デモ: 起動時に認識モデルが未導入", Messages.modelNotInstalled),
        toast("デモ: 整形をオンにしたが接続できない", Messages.formatterUnreachable),
        toast("デモ: 整形サーバを起動中", Messages.formatterStarting),
        toast("デモ: mlx-lm が入っていない", Messages.formatterCommandMissing("mlx_lm.server")),
        toast("デモ: 起動コマンドが見つからない", Messages.formatterCommandMissing("my_server")),
        toast("デモ: 整形サーバに接続できた（モデルを読み込み中）", Messages.formatterConnected),
        toast("デモ: 整形の準備ができた", Messages.formatterReady),
        toast("デモ: この Mac では整形が予算に入らない（4B）", Messages.formatterSlow(seconds: 2.3, budget: 1.0, canDowngrade: false)),
        toast("デモ: この Mac では整形が予算に入らない（8B。4B に替えられる）", Messages.formatterSlow(seconds: 1.2, budget: 1.0, canDowngrade: true)),
        toast("デモ: この Mac では LLM 整形を使えない", Messages.formatterUnsupported(gpuMemoryGB: 5.3)),
        toast("デモ: 8B に上げられる", Messages.formatterCanUpgrade(seconds: 0.3)),
        toast("デモ: 整形サーバの起動に失敗", Messages.formatterExited("サーバの起動に失敗（終了コード 127）")),
        toast("デモ: 整形サーバが動作中に止まった", Messages.formatterExited("サーバが動作中に終了（シグナル 9）")),
        toast("デモ: 整形サーバの起動コマンドを実行できない", Messages.formatterStartFailed("“/bin/zsh”を開けませんでした。")),
        toast("デモ: 整形サーバの待ち受けが開かない", Messages.formatterStartTimedOut),
        toast("デモ: アクセシビリティの許可を付け直した", Messages.accessibilityReset),
        toast("デモ: アクセシビリティの許可を消せない", Messages.accessibilityResetFailed("No such bundle identifier \"com.rererr.dictate\"")),
        toast("デモ: 起動し直せない", Messages.relaunchFailed("“/bin/sh”を開けませんでした。")),
        .init(title: "デモ: セキュア入力中", steps: [Step(after: .zero, action: .toast(Messages.secureInput))]),
        .init(title: "デモ: 話している間にセキュア入力へ", steps: speaking + ending(Messages.secureInputAtInsert)),
        .init(title: "デモ: 処理中に押した（字幕の上にトースト）", steps: speaking + [Step(after: .milliseconds(50), action: .toast(Messages.busy))] + ending(after: .seconds(3))),
        .init(title: "デモ: 警告の直後に次の発話（トーストが上に逃げる）", steps: speaking + ending(Messages.unverified) + [Step(after: .milliseconds(800), action: .caption(.recording, Messages.listening))]
            + speaking.dropFirst() + ending()),
        .init(title: "デモ: 認識結果なし", steps: [Step(after: .zero, action: .caption(.recording, Messages.listening)), Step(after: .seconds(1), action: .caption(.working, Messages.finalizing))]
            + ending(Messages.noResult)),
        .init(title: "デモ: フィラーだけの発話", steps: [Step(after: .zero, action: .caption(.recording, "えっと、")), Step(after: .seconds(1), action: .caption(.working, Messages.finalizing))]
            + ending(Messages.onlyFillers)),
        .init(title: "デモ: 認識の失敗（話している最中）", steps: [Step(after: .zero, action: .caption(.recording, Messages.listening))]
            + ending(Messages.recognitionFailed(SpeechCoreError.modelNotInstalled(localeIdentifier: "ja-JP").localizedDescription), after: .milliseconds(300))),
        toast("デモ: マイクを開けない", Messages.microphoneFailed(SpeechCoreError.microphoneUnavailable.localizedDescription)),
        toast("デモ: 設定の項目名の打ち間違い", Messages.loadFailed(Config.LoadError.invalid(
            path: AppPaths.config.path, detail: "formatter.enable: 知らない項目です。使える項目は budgetSeconds, enabled, endpoint, model です。"
        ).localizedDescription)),
        toast("デモ: 設定のホットキーに修飾キーがない", Messages.loadFailed(Config.LoadError.hotkey(.needsModifier).localizedDescription)),
        toast("デモ: マウスボタンのホットキーで許可がない", Messages.loadFailed(MouseButtonTap.PermissionError().localizedDescription)),
        toast("デモ: 辞書の行を読めない", Messages.loadFailed(YomiDictionary.ParseError.malformedLine(number: 3, content: "Laravel ららべる 余分").localizedDescription)),
        toast("デモ: 履歴に書けない", Messages.historyFailed("“history.jsonl”を保存するためのアクセス権がありません。")),
    ]

    private static func toast(_ title: String, _ message: String) -> DemoScenario {
        .init(title: title, steps: [Step(after: .zero, action: .toast(message))])
    }
}
