#!/usr/bin/env python3
"""整形サーバの所要と採用率を、モデルごとに測る。

使い方:
  mlx_lm.server --model mlx-community/Qwen3-4B-4bit --port 8124 --chat-template-args '{"enable_thinking": false}'
  python3 eval/formatter_bench.py --model mlx-community/Qwen3-4B-4bit

送る文はフィラーを含む 12 文（Slack 風、メール風、介護記録風）。各文を 2 回送り、2 回目（温まった状態）の所要を取る。
初回はモデルのダウンロードが終わるまで最初の要求が待たされる（既定 600 秒まで待つ）。
採用の判定はアプリの検証（フィラーの削除と句読点の変更だけ）の近似で、句読点と空白とフィラーを除いた文字列が入力と一致すれば採用とする。
数値はアプリと同じく印に置き換えて送る。
"""
import argparse, json, re, statistics, time, urllib.request

SENTENCES = [
    "えっと、本番デプロイは15時からでいいですか",
    "あの、Laravel のキューが詰まっているみたいなので、ワーカーを再起動します",
    "さっきの件、明日の朝一でレビューお願いできますか",
    "えー、見積書を添付いたしましたので、ご確認をお願いいたします",
    "まあ、ステージングで再現できましたマイグレーションの順序が原因です",
    "なんか、PR 3113 のテストが落ちているので原因を見てからもう一度プッシュします",
    "お世話になっております先日ご相談いただいた件についてご連絡いたします",
    "えっと、入浴後に仙骨部の発赤を確認看護師に報告",
    "血圧は 120 の 78 脈拍は 72 体温は 36 度 5 分",
    "あのー、来週の水曜日 14 時から 30 分ほどお時間をいただけますでしょうか",
    "了解です午後に対応します",
    "えーっと、朝食は主食が全量副食が半分で水分は 150",
]
FILLERS = ["えっと", "えーっと", "えーと", "ええと", "えー", "あのー", "あの", "その", "まあ", "なんか"]
PUNCT = "、。，．！？ 　\n\t"
# アプリ本体の組み込みプロンプト（Sources/DictateKit/Formatting.swift の defaultSystemPrompt）と同じ文
SYSTEM = (
    "あなたは音声入力の整形担当です。入力は音声認識の生テキストです。"
    "フィラー（えっと、えー、あのー、あの、その、まあ、なんか）を取り除き、句読点を整えます。"
    "それ以外の語は一字も変えません。<N1> のような印はそのまま残します。出力は本文だけ。"
)

def mask(text):
    originals = []
    def repl(m):
        originals.append(m.group(0))
        return f"<N{len(originals)}>"
    return re.sub(r"[0-9０-９]+(?:[.,:/\-．，：／][0-9０-９]+)*", repl, text), originals

def normalize(text):
    text = "".join(ch for ch in text if ch not in PUNCT)
    for filler in sorted(FILLERS, key=len, reverse=True):
        text = text.replace(filler, "")
    return text

def ask(endpoint, model, text, timeout):
    body = json.dumps({
        "model": model, "temperature": 0, "max_tokens": 256,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}],
    }).encode()
    req = urllib.request.Request(f"{endpoint}/chat/completions", data=body, headers={"Content-Type": "application/json"})
    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as res:
        content = json.load(res)["choices"][0]["message"]["content"]
    return content.strip(), time.perf_counter() - started

def has_filler(text):
    """文頭のフィラー（台本のフィラーは全て文頭に置いてある）が残っているか。"""
    head = text.lstrip(PUNCT)
    return any(head.startswith(f) for f in FILLERS)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--endpoint", default="http://127.0.0.1:8124/v1")
    # mlx_lm.server は待ち受けを開いた後もモデルのダウンロードを続ける。初回は温めの要求がその完了を待つ
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    ask(args.endpoint, args.model, "えっと、準備です", args.timeout)  # 温め
    seconds, adopted, effective, with_filler, rejected, untouched = [], 0, 0, 0, [], []
    for sentence in SENTENCES:
        masked, _ = mask(sentence)
        ask(args.endpoint, args.model, masked, args.timeout)  # 1 回目は捨てる（キャッシュの影響を揃える）
        output, elapsed = ask(args.endpoint, args.model, masked, args.timeout)
        seconds.append(elapsed)
        ok = normalize(output) == normalize(masked)
        if ok:
            adopted += 1
        else:
            rejected.append((masked, output))
        if has_filler(masked):
            with_filler += 1
            if ok and not has_filler(output):
                effective += 1
                label = "効果"
            elif ok:
                untouched.append(output)
                label = "採用（フィラー残り）"
            else:
                label = "棄却"
        else:
            label = "採用" if ok else "棄却"
        print(f"{elapsed:5.2f}s  {label}  {output}")
    print()
    print(f"model: {args.model}")
    print(f"所要: 中央値 {statistics.median(seconds):.2f} 秒、最大 {max(seconds):.2f} 秒、最小 {min(seconds):.2f} 秒（{len(seconds)} 文、温まった状態）")
    print(f"採用: {adopted}/{len(SENTENCES)}（検証の近似。フィラーと句読点以外の変更があれば棄却）")
    print(f"効果: {effective}/{with_filler}（フィラーのある文のうち、採用され、かつフィラーが消えたもの。採用でもフィラーを残したものは {len(untouched)}）")
    for masked, output in rejected:
        print(f"  棄却: {masked}\n     → {output}")

if __name__ == "__main__":
    main()
