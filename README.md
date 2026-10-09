# dictate

ホットキーを押している間の発話を、前面アプリのカーソル位置に入れる macOS 常駐アプリ。
認識は Apple SpeechTranscriber のライブ認識で、音声は端末の外に出ない。

A push-to-talk dictation app for macOS (Japanese). Hold a hotkey, speak, and the text is inserted at the cursor of the frontmost app. Recognition runs on-device with Apple's SpeechTranscriber. The documentation is in Japanese.

設計と判断理由は `docs/design.md` にある。

## 状態

作者が自分で使うために作った試作で、次の前提で動く。

- 日本語専用。認識のロケール、読み辞書、末尾コマンド、フィラーの規則が日本語に固定されている。
- 配布用のバイナリは無い。自分で組んで、自分の Mac で署名する。
- 計測は作者 1 人の声と 1 台の Mac でのもの（肉声 20 文で CER 2.7%、キーを離してから確定まで中央値 0.10 秒）。
- 認識誤りの自動補正はしない。読み辞書で直す（理由と、試して退けた方式は `docs/design.md` の ADR-10）。
- 未確認の事項と既知の限界は `docs/design.md` の §9 にある。

## 必要なもの

- macOS 26 以降、Apple Silicon
- Swift 6.2 以降（Xcode は不要。Command Line Tools で足りる）
- 日本語の音声認識モデル（システム設定 > キーボード > 音声入力で日本語を追加）

## 組み立てと起動

```sh
scripts/bundle.sh          # build/Dictate.app を組んで署名する
open build/Dictate.app
```

初回の起動で、マイクとアクセシビリティの許可を求める。

署名は、キーチェーンに自己署名の証明書「Dictate Dev」があればそれを使い、無ければアドホック署名になる。
アドホック署名では、組み直すたびに OS が別のアプリとして扱うので、許可を付け直す必要がある。
その場合、一覧の Dictate はオンに見えても効かない。次で消してから付け直す。

```sh
tccutil reset Accessibility com.rererr.dictate
```

証明書を作っておくと、組み直しても許可が保たれる。

```sh
# 作る（この Mac の中だけで有効な、コード署名用の自己署名証明書）
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=Dictate Dev" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Dictate Dev" -out id.p12 -passout pass:一時的なパスワード
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P 一時的なパスワード -T /usr/bin/codesign
rm key.pem cert.pem id.p12

# 消す
security delete-identity -c "Dictate Dev"
```

メニューバーのマイクのアイコンから、現在の設定、ホットキーの登録、設定と辞書の再読み込み、直前の発話のコピー、終了を選べる。

## 使い方

既定のホットキーは ⌃⌥⌘D。
押している間だけ録音し、離すと確定して挿入する。
0.3 秒未満で離した押下は、誤操作として何もしない。

ホットキーは、メニューの「ホットキーを登録…」で変えられる。
出てきた窓の上で、キーの組み合わせか、マウスの中ボタンかサイドボタンを押して保存する。
macOS 自体のショートカットと重なる組み合わせには警告が出る。
他のアプリのホットキーとの重なりは検出できないので、保存した後に一度押して確かめる。
マウスボタンを登録した場合は、その受け取りにアクセシビリティの許可を使う。
話している途中の文は画面下の字幕に出て、入力欄には確定した文だけが入る。
挿入できたときは字幕が閉じるだけで、何も知らせない。
挿入できなかったときや、整形を採用しなかったときだけ、同じ場所に理由のトーストが出る。
発話の末尾を「送信して」で終えると、その語を除いて挿入した後に Return を送る。
「改行して」で終えると、Shift+Return を送る（チャットの入力欄で、送信せずに改行する）。
どちらも末尾のときだけ効き、文中の同じ語は本文として入る。

メニューの「発話の後に改行する」をオンにすると、コマンドを言わなくても、挿入のたびに Shift+Return を送る。
押して離すまでの 1 回の発話が 1 行になる。

## 設定

`~/Library/Application Support/Dictate/` に置く。どれも無ければ既定値で動く。

| ファイル | 内容 |
|---|---|
| `config.json` | ホットキー、LLM 整形、履歴、常に貼り付けで挿入するアプリ |
| `dictionary.tsv` | 読み辞書。`表記<TAB>読み`（読みは省略可）。例は `eval/dictionary.tsv` |
| `history.jsonl` | 履歴（追記専用）。生テキスト、挿入した文、経路、所要時間 |

`config.json` の全項目と既定値:

```json
{
  "hotkey": { "type": "key", "code": 2, "modifiers": ["control", "option", "command"] },
  "formatter": {
    "enabled": false,
    "endpoint": "http://127.0.0.1:8124/v1",
    "model": "mlx-community/Qwen3-8B-4bit",
    "budgetSeconds": 1.0,
    "temperature": 0,
    "maxTokens": 512,
    "enableThinking": false,
    "systemPrompt": null
  },
  "history": { "enabled": true },
  "alwaysPasteBundleIds": [],
  "newlineAfterUtterance": false
}
```

`hotkey` は登録の窓が書く。手で書く場合、`code` は仮想キーコードで、マウスボタンは `{ "type": "mouse", "button": 3, "modifiers": [] }` の形になる（2 が中ボタン、3 以降がサイドボタン）。

書式が壊れていると、既定値には読み替えず、箇所を示して停止する。
直してからメニューの「設定と辞書を再読み込み」を選ぶ。

メニューの「設定ファイルを開く」を選ぶと、全項目を現在の値で書き出してから `config.json` を開く。
違うところだけ直して保存し、「設定と辞書を再読み込み」を選ぶ。

LLM 整形（フィラーの除去と句読点）を使うときは、サーバを自分で立ててから、メニューの「LLM で整える（フィラーと句読点）」をオンにする。
`budgetSeconds` 以内に結果が届かなければ、整形前の文を挿入する。遅いモデルを使うなら、この値を延ばす。
`systemPrompt` を書くと組み込みのプロンプトを置き換える。ただし、挿入されるのは「フィラーの削除と句読点の変更だけ」の検証を通った出力に限られ、それ以外の書き換えは捨てて整形前の文を挿入する。

```sh
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8124 --chat-template-args '{"enable_thinking": false}'
```

## 字幕とトーストだけを確認する

```sh
open build/Dictate.app --args --demo
```

マイクも認識も使わず、メニューから選んだ場面（成功、整形の時間切れ、許可なし等）の表示を再生する。許可は要らない。

## テスト

```sh
scripts/test.sh
```

素の `swift test` は、Command Line Tools だけの環境でテスト用マクロのプラグインを見つけられずに失敗することがある。
`scripts/test.sh` はプラグインの場所を明示する。

## 評価

`eval/sheet.html` を Chrome で開き、20 文を読み上げて書き出し、`eval/score.py` に渡す。
手順と指標は `docs/design.md` の §7 にある。

```sh
swiftc -O -o eval/yomi eval/yomi.swift   # 読み正規化後の CER に使う。無くても他の指標は出る
python3 eval/score.py ~/Downloads/dictate-eval.json
```

台本の組は 3 つある。`eval/stability.html` は同じ語を 5 回ずつ話す 25 文、`eval/collision.html` は同じ読みの語の衝突と言い換えを見る 40 文を開く。
この 2 つは `score.py` の対象ではなく、履歴の生の認識結果を目で数える。

音声は保存しない。採点に使うのは、評価シートの書き出しと `history.jsonl` だけである。

## 共通核 SpeechCore

`Packages/SpeechCore` は独立した Swift パッケージで、マイクの取り込み、ライブ認識、読み辞書を持つ。
他のプロジェクトからは次のように取り込む。

```swift
.package(path: "../dictate/Packages/SpeechCore")
```

## ライセンス

MIT License。`LICENSE` を参照。
