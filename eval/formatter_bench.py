#!/usr/bin/env python3
"""整形サーバの所要と採用率を、モデルごとに測る。

使い方:
  mlx_lm.server --model mlx-community/Qwen3-4B-4bit --port 8124 --chat-template-args '{"enable_thinking": false}'
  python3 eval/formatter_bench.py --model mlx-community/Qwen3-4B-4bit
  オンラインの API（ADR-16）: python3 eval/formatter_bench.py --endpoint https://api.anthropic.com/v1 --model claude-haiku-5-5 \
      --api-key "$ANTHROPIC_API_KEY" --temperature null --thinking null
  （--temperature null と --thinking null は、アプリの temperature と enableThinking を null にした条件と同じ）

送る文は 12 文（Slack 風、メール風、介護記録風）。各文を 2 回送り、2 回目（温まった状態）の所要を取る。
初回はモデルのダウンロードが終わるまで最初の要求が待たされる（既定 600 秒まで待つ）。
採用の判定はアプリの検証と同じで、句読点と空白を除いた文字列が入力と一致すれば採用とする（フィラーの削除も棄却になる）。
文頭のフィラーは、アプリでは規則が先に消すので、送る前に規則と同じ語彙で落とす。
数値はアプリと同じく印に置き換えて送る。
"""
import argparse, json, re, statistics, time, urllib.error, urllib.request

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
    "句読点と空白を整えます。語は一字も変えず、消しません。<N1> のような印はそのまま残します。出力は本文だけ。"
)

def mask(text):
    originals = []
    def repl(m):
        originals.append(m.group(0))
        return f"<N{len(originals)}>"
    return re.sub(r"[0-9０-９]+(?:[.,:/\-．，：／][0-9０-９]+)*", repl, text), originals

def normalize(text):
    return "".join(ch for ch in text if ch not in PUNCT)

def strip_leading_filler(text):
    """台本のフィラーは文頭に読点つきで置いてある。アプリの規則（ADR-14）が消す形だけを落とす。"""
    for filler in sorted(FILLERS, key=len, reverse=True):
        if text.startswith(filler + "、"):
            return text[len(filler) + 1:]
    return text

def ask(endpoint, model, text, timeout, api_key=None, temperature=0.0, thinking=False):
    """アプリと同じ本文。temperature と thinking は None なら項目ごと送らない（アプリの null と同じ）。"""
    request = {"model": model, "max_tokens": 256,
               "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]}
    if temperature is not None:
        request["temperature"] = temperature
    if thinking is not None:
        request["chat_template_kwargs"] = {"enable_thinking": thinking}
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(f"{endpoint}/chat/completions", data=json.dumps(request).encode(), headers=headers)
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            content = json.load(res)["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as error:
        raise SystemExit(f"HTTP {error.code}: {error.read().decode(errors='replace')}")
    return content.strip(), time.perf_counter() - started

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--endpoint", default="http://127.0.0.1:8124/v1")
    # mlx_lm.server は待ち受けを開いた後もモデルのダウンロードを続ける。初回は温めの要求がその完了を待つ
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--api-key", help="オンラインの API の鍵。Authorization: Bearer で送る")
    parser.add_argument("--temperature", default="0", help="数値か null（送らない。Claude は 1 未満を拒む）")
    parser.add_argument("--thinking", default="false", choices=["false", "true", "null"], help="chat_template_kwargs の enable_thinking。null なら送らない")
    args = parser.parse_args()
    temperature = None if args.temperature == "null" else float(args.temperature)
    thinking = {"false": False, "true": True, "null": None}[args.thinking]
    def send(text):
        return ask(args.endpoint, args.model, text, args.timeout, args.api_key, temperature, thinking)
    send("えっと、準備です")  # 温め
    seconds, adopted, rejected = [], 0, []
    for sentence in SENTENCES:
        masked, _ = mask(strip_leading_filler(sentence))
        send(masked)  # 1 回目は捨てる（キャッシュの影響を揃える）
        output, elapsed = send(masked)
        seconds.append(elapsed)
        ok = normalize(output) == normalize(masked)
        if ok:
            adopted += 1
        else:
            rejected.append((masked, output))
        print(f"{elapsed:5.2f}s  {'採用' if ok else '棄却'}  {output}")
    print()
    print(f"model: {args.model}")
    print(f"所要: 中央値 {statistics.median(seconds):.2f} 秒、最大 {max(seconds):.2f} 秒、最小 {min(seconds):.2f} 秒（{len(seconds)} 文、温まった状態）")
    print(f"採用: {adopted}/{len(SENTENCES)}（検証と同じ判定。句読点と空白以外の変更があれば棄却）")
    for masked, output in rejected:
        print(f"  棄却: {masked}\n     → {output}")

if __name__ == "__main__":
    main()
