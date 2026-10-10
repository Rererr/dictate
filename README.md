# dictate

ホットキーを押している間の発話を、前面アプリのカーソル位置に入れる macOS 常駐アプリ。
認識は Apple SpeechTranscriber のライブ認識で、音声は端末の外に出ない。

A push-to-talk dictation app for macOS (Japanese). Hold a hotkey, speak, and the text is inserted at the cursor of the frontmost app. Recognition runs on-device with Apple's SpeechTranscriber. The documentation is in Japanese.

設計と判断理由は `docs/design.md` にある。

## 例

チャットの入力欄にカーソルを置き、⌃⌥⌘D を押しながら「了解です、午後に対応します、送信して」と話して、離す。
入力欄に「了解です、午後に対応します」が入り、続けて Return が送られる。
話している間は画面の下に字幕が出て、入力欄には確定した文だけが入る。

## 状態

作者が自分で使うために作った試作で、次の前提で動く。

- 日本語専用。認識のロケール、読み辞書、末尾コマンド、フィラーの規則が日本語に固定されている。
- 配布用のバイナリは無い。自分で組んで、自分の Mac で署名する。
- 計測は作者 1 人の声と 1 台の Mac でのもの（肉声 20 文で CER 2.7%、キーを離してから確定まで中央値 0.10 秒）。導入の手順は 2 台目の Mac（macOS 27）で Homebrew 経路を通して確かめた。
- 認識誤りの自動補正はしない。読み辞書で直す（理由と、試して退けた方式は `docs/design.md` の ADR-10）。
- 未確認の事項と既知の限界は `docs/design.md` の §9 にある。

## インストール

配布用のバイナリは無いので、手元で組む。入れ方は三つあり、どれも結果は同じ `Dictate.app` になる。English: [Installation](#installation-english).

### 必要なもの

- macOS 26 以降、Apple Silicon（動作を確かめたのは macOS 27 だけ）
- Swift 6.2 以降（Xcode は不要。Command Line Tools で足りる。`xcode-select --install`）
- 日本語の音声認識モデル（システム設定 > キーボード > 音声入力で日本語を追加）

### Homebrew で入れる

Homebrew を使っていれば、Command Line Tools は入っている。このリポジトリ自体が tap になる（formula は `Formula/dictate.rb`）。

```sh
brew tap rererr/dictate https://github.com/Rererr/dictate
brew install --HEAD rererr/dictate/dictate
dictate                    # 起動（open /opt/homebrew/opt/dictate/Dictate.app と同じ）
```

Spotlight や Launchpad から起動したいときは、`ditto /opt/homebrew/opt/dictate/Dictate.app ~/Applications/Dictate.app` で写す。
更新は `brew upgrade --fetch-HEAD dictate`（`--fetch-HEAD` が無いと、HEAD の formula は更新されない）。
署名はアドホックなので、更新のたびにアクセシビリティの許可を付け直す（下の「署名と許可」）。
やめるときは `brew uninstall dictate` と `brew untap rererr/dictate`。

### スクリプトで入れる

前提の確認、ビルド、`~/Applications/Dictate.app` への配置、起動までを一つのスクリプトが行う。

```sh
git clone https://github.com/Rererr/dictate.git
cd dictate
scripts/install.sh
```

やめるときは `scripts/install.sh --uninstall`（設定と履歴は残す）。

### 手で入れる

```sh
git clone https://github.com/Rererr/dictate.git
cd dictate
scripts/bundle.sh          # build/Dictate.app を組んで署名する
open build/Dictate.app
```

やめるときは、メニューから終了し、clone したディレクトリと `~/Library/Application Support/Dictate/` を消す。

### 初回にすること

1. 起動すると、メニューバーにマイクのアイコンが出る（Dock には出ない）。
2. 初回の起動で、マイクとアクセシビリティの許可を求められる。マイクは許可し、アクセシビリティは、システム設定 > プライバシーとセキュリティ > アクセシビリティで Dictate をオンにする（挿入に使う）。
3. メニューの上部で、マイク、アクセシビリティ、日本語の認識モデルの状態を確かめる。足りないものがあると、その設定を開く項目が同じメニューに出る（認識モデルの行は、設定を変えた次にメニューを開いたときに変わる）。認識モデルが無いときは、起動時にも知らせる。
4. 入力欄にカーソルを置き、⌃⌥⌘D を押している間に話して、離す。

組み直すたびに許可が外れるのを避けたいときは、`scripts/make-cert.sh` で証明書を作る（下の「署名と許可」）。

### LLM に入れてもらう

Claude Code などのコーディングエージェントに、次をそのまま渡す。

```text
https://github.com/Rererr/dictate を、この Mac に導入してください。

1. 前提を確かめる: macOS 26 以降、Apple Silicon、`swift --version` が 6.2 以降。満たさなければ、足りないものを伝えて止まる。
2. 作業用のディレクトリに clone し、README.md を読む。
3. `scripts/install.sh` で組んで ~/Applications/Dictate.app に置き、起動する。失敗したら、エラーをそのまま見せる。
4. `scripts/test.sh` を流し、結果を伝える。
5. あなたにはできない操作を、私に順に案内する: マイクの許可、アクセシビリティの許可、日本語の音声認識モデルの追加。メニューバーのマイクのアイコンを開くと、この三つの状態と、足りないものの設定を開く項目が出るので、三つとも揃うまで案内する。

守ること:
- sudo を使わない。
- キーチェーンに証明書を作らない（`scripts/make-cert.sh` を実行しない）。作るかどうかは、README の「署名と許可」を示して私に尋ねる。
- clone したディレクトリ、~/Applications/Dictate.app、ビルドのキャッシュ以外のファイルを変更しない。

最後に、既定のホットキー、設定ファイルの場所、アンインストールの方法（`scripts/install.sh --uninstall`）を伝える。
```

## Installation (English)

There is no prebuilt binary. Build it locally. The app is Japanese-only (recognition locale, reading dictionary, and voice commands).

### Requirements

- macOS 26 or later on Apple Silicon (tested only on macOS 27)
- Swift 6.2 or later (Xcode is not required; Command Line Tools are enough: `xcode-select --install`)
- The Japanese speech recognition model (System Settings > Keyboard > Dictation, add Japanese)

### Homebrew

If you use Homebrew, the Command Line Tools are already installed. This repository is its own tap (the formula is `Formula/dictate.rb`).

```sh
brew tap rererr/dictate https://github.com/Rererr/dictate
brew install --HEAD rererr/dictate/dictate
dictate                    # launches the app (same as open /opt/homebrew/opt/dictate/Dictate.app)
```

To launch from Spotlight or Launchpad, copy it with `ditto /opt/homebrew/opt/dictate/Dictate.app ~/Applications/Dictate.app`.
Update with `brew upgrade --fetch-HEAD dictate` (without `--fetch-HEAD`, a HEAD-only formula is never updated).
The build is ad-hoc signed, so after every update you have to grant the Accessibility permission again (see below).
Uninstall with `brew uninstall dictate` and `brew untap rererr/dictate`.

### Install script

One script checks the requirements, builds, copies the app to `~/Applications/Dictate.app`, and launches it.

```sh
git clone https://github.com/Rererr/dictate.git
cd dictate
scripts/install.sh
```

Uninstall with `scripts/install.sh --uninstall` (keeps your settings and history).

### Manual install

```sh
git clone https://github.com/Rererr/dictate.git
cd dictate
scripts/bundle.sh          # builds and signs build/Dictate.app
open build/Dictate.app
```

To uninstall, quit from the menu and delete the cloned directory and `~/Library/Application Support/Dictate/`.

### First launch

1. A microphone icon appears in the menu bar (not in the Dock).
2. On first launch, the app asks for microphone and Accessibility permissions. Allow the microphone, and turn Dictate on in System Settings > Privacy & Security > Accessibility (used to insert text).
3. The top of the menu shows the status of the microphone, Accessibility, and the Japanese recognition model. When something is missing, the menu also offers an item that opens the relevant setting (the model row updates the next time you open the menu after changing the setting). A missing model is also announced at launch.
4. Put the cursor in a text field, hold ⌃⌥⌘D while speaking, then release.

With ad-hoc signing, macOS treats every rebuild as a different app and the Accessibility permission stops working (the toggle still looks on). Choose "アクセシビリティの許可を付け直す" in the menu (it runs `tccutil reset Accessibility com.rererr.dictate` and relaunches the app so that it reappears in the list), or create a self-signed certificate once with `scripts/make-cert.sh` so that rebuilds keep the permission.

### Install with an LLM

Paste this into a coding agent such as Claude Code.

```text
Install https://github.com/Rererr/dictate on this Mac.

1. Check the requirements: macOS 26 or later, Apple Silicon, and `swift --version` 6.2 or later. If any is missing, tell me what is missing and stop.
2. Clone the repository into a working directory and read README.md.
3. Run `scripts/install.sh`, which builds the app, copies it to ~/Applications/Dictate.app, and launches it. If it fails, show me the error as is.
4. Run `scripts/test.sh` and report the result.
5. Walk me through the steps you cannot do yourself: microphone permission, Accessibility permission, and adding the Japanese speech recognition model. The menu under the microphone icon in the menu bar shows the status of all three and offers items that open the missing settings; guide me until all three are satisfied.

Rules:
- Do not use sudo.
- Do not create a certificate in my keychain (do not run `scripts/make-cert.sh`). Point me to the "署名と許可" section of the README and ask me first.
- Do not modify files outside the cloned directory, ~/Applications/Dictate.app, and the build caches.

Finally, tell me the default hotkey, where the settings files live, and how to uninstall (`scripts/install.sh --uninstall`).
```

## 署名と許可

署名は、キーチェーンに自己署名の証明書「Dictate Dev」があればそれを使い、無ければアドホック署名になる。
アドホック署名では、組み直すたびに OS が別のアプリとして扱うので、許可を付け直す必要がある。
その場合、一覧の Dictate はオンに見えても効かない。
メニューの「アクセシビリティの許可を付け直す」を選ぶと、記録を消してからアプリが起動し直し、出てきたダイアログから設定を開いて一覧でオンにする（ターミナルなら `tccutil reset Accessibility com.rererr.dictate` の後に起動し直す）。

証明書を作っておくと、組み直しても許可が保たれる。
この Mac の中だけで有効な、コード署名用の自己署名証明書で、次の 1 行で作れる。

```sh
scripts/make-cert.sh           # 作る。次の scripts/bundle.sh からこれで署名する
scripts/make-cert.sh --delete  # 消す
```

作った直後の一度だけ、アドホック署名で付けた許可は引き継がれないので、上の手順で付け直す。
Homebrew で入れた場合は、ビルドが Homebrew のサンドボックスの中で走り、キーチェーンを使えないので、証明書を作ってもアドホック署名のままになる。

証明書には引き換えがある。
鍵は codesign が確認なしに使える設定で入るので、同じユーザー権限で動く他のプログラムも、この証明書と Dictate のバンドル ID で署名したものを作れる。
そうして作られたものは、Dictate に付けたアクセシビリティの許可を受け継ぐ。
アドホック署名にはこの経路が無い（許可がビルドごとの実行ファイルに結び付く）。
自分の Mac で動くものを信頼できる範囲で使う前提の仕組みで、気になるなら証明書を作らず、組み直すたびに付け直す。

メニューバーのマイクのアイコンから、現在の設定と許可の状態、ホットキーの登録、設定と辞書の再読み込み、直前の発話のコピー、終了を選べる。

## つまずいたら

| 症状 | 原因 | 対処 |
|---|---|---|
| ホットキーを押しても字幕が出ない | 押してすぐ離した（0.3 秒未満は誤操作として捨てる） | 話し終わるまで押し続ける |
| 同上 | 他のアプリが同じキーを先に取っている | メニューの「ホットキーを登録…」で別の組み合わせにする |
| 同上。「セキュア入力中」のトーストが出る | パスワード欄にカーソルがあるか、他のアプリがセキュア入力を有効にしたまま | そのアプリ（多くはターミナルかパスワード管理ツール）を切り替えるか終了する |
| 字幕は出るが、入力欄に文が入らない | アクセシビリティの許可が無い。組み直した後なら、アドホック署名で別のアプリ扱いになり、許可が外れている | メニューの「アクセシビリティ」の行を見る。一覧でオンに見えて効かないときは、メニューの「アクセシビリティの許可を付け直す」を選ぶ。繰り返すなら `scripts/make-cert.sh` で証明書を作る |
| 「音声認識モデルが導入されていません」と出る | 日本語の認識モデルが端末に無い | メニューの「音声入力の設定を開く」から、システム設定 > キーボード > 音声入力で日本語を追加する |
| `scripts/bundle.sh` が「package requires minimum Swift tools version 6.2」で止まる | Swift が 6.2 より古い | `swift --version` で確かめ、Command Line Tools を更新する |
| 同じ語がいつも違う表記になる | 認識器の癖。アプリは自動で補正しない | `dictionary.tsv` に `表記<TAB>読み` の行を足し、「設定と辞書を再読み込み」を選ぶ |

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

フィラー（えっと、えーっと、えーと、ええと、えー、あのー）は、認識結果からそのまま消して挿入する。
「あの」「その」「まあ」「なんか」は、文頭か句読点の直後にあって読点が続くときだけ消す（「あの人」「その件」は残る）。
メニューの「フィラーを消す」で切れる。LLM 整形は要らない。

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
    "systemPrompt": null,
    "startCommand": "mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8124 --chat-template-args '{\"enable_thinking\": false}'"
  },
  "history": { "enabled": true },
  "alwaysPasteBundleIds": [],
  "newlineAfterUtterance": false,
  "editor": null,
  "removeFillers": true
}
```

`hotkey` は登録の窓が書く。手で書く場合、`code` は仮想キーコードで、マウスボタンは `{ "type": "mouse", "button": 3, "modifiers": [] }` の形になる（2 が中ボタン、3 以降がサイドボタン）。

書式が壊れていると、既定値には読み替えず、箇所を示して停止する。
直してからメニューの「設定と辞書を再読み込み」を選ぶ。

メニューの「設定ファイルを開く」を選ぶと、全項目を現在の値で書き出してから `config.json` を開く。
初回はどのアプリで開くかを尋ねる（テキストエディットか、選んだアプリ）。「次回からこのアプリで開く」にチェックを入れると `editor` にそのアプリのパスが入り、以後は尋ねない。選び直したいときは `editor` を `null` にする。
違うところだけ直して保存し、「設定と辞書を再読み込み」を選ぶ。

LLM 整形は、規則が残した曖昧なフィラーと句読点を整えるもので、手元で動かすサーバに文を送って結果を受け取る。
はじめての人向けの手順と、モデルをどう選んだかは [docs/local-llm.md](docs/local-llm.md) にある。
メニューの「LLM で整える（フィラーと句読点）」をオンにしたとき、サーバに接続できなければ、`formatter.startCommand` のコマンドでアプリがサーバを起動する。既定は mlx-lm で既定のモデルを立てるコマンドで、mlx-lm が無ければ入れ方をトーストで知らせる。`""` にすると起動せず、接続できないことだけを知らせる（`null` は既定の意味）。
アプリが起動したサーバは、オフにしたときと終了時にアプリが止める。
`budgetSeconds` 以内に結果が届かなければ、整形前の文を挿入する。遅いモデルを使うなら、この値を延ばす。
`systemPrompt` を書くと組み込みのプロンプトを置き換える。ただし、挿入されるのは「フィラーの削除と句読点の変更だけ」の検証を通った出力に限られ、それ以外の書き換えは捨てて整形前の文を挿入する。

```sh
# startCommand の既定値（手で立てるときも同じ）
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8124 --chat-template-args '{"enable_thinking": false}'
```

## よくある質問

**LLM 整形とは何か。ローカル LLM を触ったことがない。**
話した文の句読点を整え、規則では消せない曖昧なフィラーを消す任意の機能で、手元の Mac で動くサーバを使う。
入れ方から動作確認までを [docs/local-llm.md](docs/local-llm.md) に書いた。使わなくても音声入力は動き、よくあるフィラー（えっと、えー、あのー 等）は規則で消える。

**なぜモデルが Qwen3-8B なのか。もっと小さい、または大きいモデルは使えるか。**
「キーを離して 1 秒以内」に入る中で試した最大のモデルだからである。27B は品質が良くても 3〜7 秒かかり、8B でも指示を無視することがあったので、LLM の役割をフィラーと句読点に絞った。計測の表は [docs/local-llm.md](docs/local-llm.md#モデルをどう選んだか) にある。

**話した内容はどこかに送られるか。**
送られない。認識は Apple の端末内モデル、整形は手元のサーバで、どちらも Mac の外に出ない。履歴は `~/Library/Application Support/Dictate/history.jsonl` に文字として残り、音声は保存しない。

**他の人の声や英語でも使えるか。**
認識のロケール、読み辞書、末尾コマンド、フィラーの規則が日本語に固定されている。英語は対象外である。

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
