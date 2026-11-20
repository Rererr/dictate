#!/usr/bin/env python3
"""formatter_bench.py の 12 文を整形サーバに送り、正解の句読点（punct_reference.tsv）との一致を出す。

収集と採点を分ける。正解を直したら採点だけやり直せばよい（サーバは要らない）。
  収集: python3 eval/punct_bench.py collect --model mlx-community/Qwen3-4B-4bit --out eval/results/2026-11-16-punct-outputs.json
        同じファイルに書くと、モデルごとに足していく（同じモデルは上書き）。接続先の既定は http://127.0.0.1:8131/v1
  採点: python3 eval/punct_bench.py score eval/results/2026-11-16-punct-outputs.json [--detail] [--json 出力先] [--reference 別の正解]

要求はアプリの既定（Config.Formatter）と同じ: temperature 0、max_tokens 512、chat_template_kwargs {"enable_thinking": false}、組み込みのプロンプト。
各文を 2 回送り、2 回目の出力と所要を使う（formatter_bench.py と同じ）。思考が止まっているかを見るため、応答の reasoning・finish_reason・出力トークン数も残す。
採点の対象はアプリが実際に入れる文: 検証を通れば出力、通らなければ入力のまま（予算は見ない。予算内の件数は別に出す）。
「LLM なし」の行は入力をそのまま採点したもので、入力を素通しで返すモデルはこれと同じ値になる。
句読点（、。？！）は文中と文末に分け、空白は別に、位置の一致で適合率と再現率を出す。位置は句読点と空白を除いた文字列の境目で数える。
"""
import argparse, collections, json, re, statistics, time, urllib.error, urllib.request
from datetime import datetime
from pathlib import Path

from formatter_bench import PUNCT, SENTENCES, SYSTEM, mask, normalize, strip_leading_filler

REFERENCE = Path(__file__).with_name("punct_reference.tsv")
BUDGET_SECONDS = 1.0  # Config.Formatter.budgetSeconds の既定
MARKS = {"、": "、", "，": "、", "。": "。", "．": "。", "？": "？", "！": "！"}  # 残りの PUNCT（空白・改行・タブ）は空白に数える
THINK_MARKERS = ("<think>", "</think>", "<|channel>", "<channel|>")


def request(endpoint, model, text, kwargs, timeout):
    body = {"model": model, "temperature": 0.0, "max_tokens": 512, "stream": False,
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]}
    if kwargs is not None:
        body["chat_template_kwargs"] = kwargs
    req = urllib.request.Request(f"{endpoint}/chat/completions", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            data = json.load(res)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"HTTP {error.code}: {error.read().decode(errors='replace')}")
    seconds = time.perf_counter() - started
    choice = data["choices"][0]
    message = choice["message"]
    return {"content": message.get("content") or "", "reasoning": message.get("reasoning") or message.get("reasoning_content") or "",
            "finish_reason": choice.get("finish_reason"), "completion_tokens": (data.get("usage") or {}).get("completion_tokens"),
            "seconds": round(seconds, 4)}


def thinking_summary(responses):
    """思考が止まっていれば、reasoning は空、content は空でなく、印も無く、finish_reason は stop、出力トークンは入力相応になる。"""
    tokens = [r["completion_tokens"] for r in responses if r["completion_tokens"] is not None]
    return {"responses": len(responses),
            "with_reasoning": sum(bool(r["reasoning"]) for r in responses),
            "empty_content": sum(not r["content"].strip() for r in responses),
            "think_markers_in_content": sum(any(m in r["content"] for m in THINK_MARKERS) for r in responses),
            "finish_reasons": dict(collections.Counter(r["finish_reason"] for r in responses)),
            "completion_tokens_max": max(tokens) if tokens else None}


def collect(args):
    kwargs = json.loads(args.chat_template_kwargs) if args.chat_template_kwargs != "null" else None
    def send(text):
        return request(args.endpoint, args.model, text, kwargs, args.timeout)
    warmup = send("えっと、準備です")  # formatter_bench.py と同じ温め
    rows = []
    for sentence in SENTENCES:
        masked, _ = mask(strip_leading_filler(sentence))
        first = send(masked)  # 1 回目は捨てる（キャッシュの影響を揃える）
        second = send(masked)
        rows.append({"input": masked, "first": first, "second": second})
        print(f"{second['seconds']:5.2f}s  {second['content'].strip()}")
    thinking = thinking_summary([warmup] + [r[k] for r in rows for k in ("first", "second")])
    out = Path(args.out)
    data = json.loads(out.read_text(encoding="utf-8")) if out.exists() else {"models": {}}
    data["models"][args.model] = {"endpoint": args.endpoint, "chat_template_kwargs": kwargs,
                                  "collected_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                                  "thinking": thinking, "warmup": warmup, "rows": rows}
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"思考の確認: {json.dumps(thinking, ensure_ascii=False)}")
    if thinking["with_reasoning"] or thinking["empty_content"] or thinking["think_markers_in_content"] or set(thinking["finish_reasons"]) != {"stop"}:
        raise SystemExit("思考が止まっていない応答があります（reasoning・空の content・思考の印・stop 以外の終わり方のいずれか）。指定を見直してください")


def load_reference(path):
    rows = [line.split("\t") for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.startswith("#")]
    if len(rows) != len(SENTENCES):
        raise SystemExit(f"{path.name} の文は {len(rows)} 個で、formatter_bench.py の {len(SENTENCES)} 文と数が合いません")
    references = []
    for number, (row, sentence) in enumerate(zip(rows, SENTENCES), 1):
        if len(row) != 2:
            raise SystemExit(f"{path.name} の {number} 文目: 列が {len(row)} 個です（タブ区切りで 送る文 と 正解 の 2 列）")
        source, reference = row
        if source != strip_leading_filler(sentence):
            raise SystemExit(f"{path.name} の {number} 文目の送る文が formatter_bench.py と違います: {source!r} / {strip_leading_filler(sentence)!r}")
        if normalize(reference) != normalize(source):
            raise SystemExit(f"{path.name} の {number} 文目の正解が、句読点と空白以外の所で送る文と違います: {reference!r}")
        references.append(reference)
    return references


def unmask(output, originals):
    """Swift の NumberMask.unmask と同じ。印が欠けた、増えた、順序が変わった出力は None。"""
    result, rest = "", output
    for index, original in enumerate(originals, 1):
        tag = f"<N{index}>"
        at = rest.find(tag)
        if at < 0:
            return None
        result += rest[:at] + original
        rest = rest[at + len(tag):]
    result += rest
    return None if re.search(r"<N[0-9]+>", result) else result


def inserted(row, sentence):
    """アプリの検証（FormatVerifier と NumberMask）を通れば復元した出力、通らなければ入力。
    keepsSeparators は、12 文に数値どうしの間が記号と空白だけの所が無いので発火しない。"""
    text = strip_leading_filler(sentence)
    masked, originals = mask(text)
    if row["input"] != masked:
        raise SystemExit(f"収集した文が formatter_bench.py の今の文と違います: {row['input']!r}。収集し直してください")
    output = row["second"]["content"].strip()
    restored = unmask(output, originals) if normalize(output) == normalize(masked) else None
    if restored is None or not normalize(restored):
        return text, False
    return restored, True


def marks(text):
    """（境目の位置, 句読点）の集合と、空白のある境目の集合と、句読点と空白を除いた長さ。"""
    position, punctuation, spaces = 0, set(), set()
    for ch in text:
        if ch in MARKS:
            punctuation.add((position, MARKS[ch]))
        elif ch in PUNCT:
            spaces.add(position)
        else:
            position += 1
    return punctuation, spaces, position


def compare(texts, references):
    counts = {kind: collections.Counter() for kind in ("inner", "end", "space")}
    for text, reference in zip(texts, references):
        got_p, got_s, length = marks(text)
        want_p, want_s, _ = marks(reference)
        for kind, got, want in (("inner", {m for m in got_p if m[0] < length}, {m for m in want_p if m[0] < length}),
                                ("end", {m for m in got_p if m[0] == length}, {m for m in want_p if m[0] == length}),
                                ("space", got_s, want_s)):
            counts[kind].update(tp=len(got & want), fp=len(got - want), fn=len(want - got))
    def ratio(a, b):
        return round(a / b, 3) if b else None
    result = {kind: {**c, "precision": ratio(c["tp"], c["tp"] + c["fp"]), "recall": ratio(c["tp"], c["tp"] + c["fn"])} for kind, c in counts.items()}
    result["exact"] = sum(t == r for t, r in zip(texts, references))
    return result


def score(args):
    path = Path(args.reference)
    references = load_reference(path)
    data = json.loads(Path(args.outputs).read_text(encoding="utf-8"))
    baseline = [strip_leading_filler(s) for s in SENTENCES]
    results = {"reference": path.name, "budget_seconds": BUDGET_SECONDS,
               "no_llm": compare(baseline, references), "models": {}}
    for model, entry in data["models"].items():
        pairs = [inserted(row, sentence) for row, sentence in zip(entry["rows"], SENTENCES)]
        texts = [t for t, _ in pairs]
        seconds = [row["second"]["seconds"] for row in entry["rows"]]
        results["models"][model] = {
            **compare(texts, references),
            "adopted": sum(ok for _, ok in pairs),
            "within_budget": sum(s <= BUDGET_SECONDS for s in seconds),
            "adopted_within_budget": sum(ok and s <= BUDGET_SECONDS for (_, ok), s in zip(pairs, seconds)),
            "median_seconds": round(statistics.median(seconds), 3), "max_seconds": round(max(seconds), 3),
            "thinking": entry["thinking"],
            "sentences": [{"inserted": t, "adopted": ok, "exact": t == r} for (t, ok), r in zip(pairs, references)],
        }
    def pr(c):
        return f"{c['precision'] if c['precision'] is not None else '-'}/{c['recall']}"
    print(f"正解: {path.name}（{len(references)} 文）。句読点と空白は 適合率/再現率")
    print("| モデル | 採用 | 完全一致 | 文中の句読点 | 文末の句読点 | 空白 | 所要（2 回目）中央値/最大 | 予算内 |")
    print("|---|---|---|---|---|---|---|---|")
    n = len(SENTENCES)
    b = results["no_llm"]
    print(f"| LLM なし（入力のまま） | - | {b['exact']}/{n} | {pr(b['inner'])} | {pr(b['end'])} | {pr(b['space'])} | - | - |")
    for model, r in results["models"].items():
        print(f"| {model} | {r['adopted']}/{n} | {r['exact']}/{n} | {pr(r['inner'])} | {pr(r['end'])} | {pr(r['space'])} | "
              f"{r['median_seconds']:.2f}/{r['max_seconds']:.2f} 秒 | {r['within_budget']}/{n} |")
        if args.detail:
            for number, s in enumerate(r["sentences"], 1):
                print(f"    {number:2d} {'一致' if s['exact'] else '    '} {'採用' if s['adopted'] else '棄却'}  {s['inserted']}")
    if args.json:
        Path(args.json).write_text(json.dumps(results, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("collect", help="12 文をサーバに送って出力を残す")
    c.add_argument("--model", required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--endpoint", default="http://127.0.0.1:8131/v1")
    c.add_argument("--timeout", type=float, default=600)
    c.add_argument("--chat-template-kwargs", default='{"enable_thinking": false}', help="JSON か null（送らない）")
    s = sub.add_parser("score", help="残した出力を正解と比べる（サーバは要らない）")
    s.add_argument("outputs")
    s.add_argument("--detail", action="store_true", help="文ごとに、アプリが入れる文を出す")
    s.add_argument("--json", help="採点の結果を書き出す先")
    s.add_argument("--reference", default=str(REFERENCE), help="正解のファイル（既定は punct_reference.tsv）。方針を変えた正解を試すとき")
    args = parser.parse_args()
    collect(args) if args.command == "collect" else score(args)


if __name__ == "__main__":
    main()
