#!/usr/bin/env python3
"""評価シートの書き出しと履歴を突き合わせ、精度と遅延を集計する。

使い方: score.py dictate-eval.json [--history PATH]
  読み正規化後の CER には、同じ場所の yomi（yomi.swift を組んだ実行ファイル）を使う。無ければその列だけ未計測になる。
    swiftc -O -o eval/yomi eval/yomi.swift

突き合わせは文字列で行う: 各行の欄の内容（末尾の改行を除く）と「挿入した文字列」が一致する発話のうち最新のもの。
一致が無い行は未採点として一覧に出す。
"""
import argparse
import json
import statistics
import subprocess
import sys
from pathlib import Path

from cer import cer, normalize

DEFAULT_HISTORY = Path.home() / "Library/Application Support/Dictate/history.jsonl"
STYLES = {"slack": "Slack 風", "mail": "メール風", "care": "介護記録風"}
SEND = "送信して"


def load_history(path: Path) -> tuple[list[dict], dict[str, dict]]:
    utterances, formats = [], {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            sys.exit(f"履歴の {number} 行目を読めません: {error}")
        if event["type"] == "utterance":
            utterances.append(event)
        elif event["type"] == "format":
            formats[event["utteranceId"]] = event
    return utterances, formats


def pooled(pairs: list[tuple[str, str]], cer, raw: bool = False) -> str:
    if not pairs:
        return "-"
    results = [cer(ref, hyp, raw=raw) for ref, hyp in pairs]
    errors = sum(r["sub"] + r["del"] + r["ins"] for r in results)
    length = sum(r["ref_len"] for r in results)
    return f"{errors / length:.1%}（{errors}/{length}）"


def readings(texts: list[str], yomi: Path) -> list[str]:
    done = subprocess.run([str(yomi)], input="\n".join(t.replace("\n", " ") for t in texts) + "\n", capture_output=True, text=True, check=True)
    lines = done.stdout.splitlines()
    if len(lines) != len(texts):
        sys.exit(f"yomi の出力行数が合いません（入力 {len(texts)}、出力 {len(lines)}）")
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export", type=Path)
    parser.add_argument("--history", type=Path, default=DEFAULT_HISTORY)
    args = parser.parse_args()

    rows = json.loads(args.export.read_text(encoding="utf-8"))["rows"]
    utterances, formats = load_history(args.history)

    matched, unmatched = [], []
    for row in rows:
        text = row["text"].rstrip("\n")
        hits = [u for u in utterances if u["inserted"] == text and text]
        (matched.append((row, hits[-1])) if hits else unmatched.append(row))

    print(f"# dictate 評価（{len(matched)}/{len(rows)} 行を採点）\n")
    if unmatched:
        print("## 未採点の行（欄の内容と一致する発話が履歴に無い）\n")
        for row in unmatched:
            print(f"- {row['id']}: 欄の内容「{row['text'].strip() or '（空）'}」")
        print()
    if not matched:
        sys.exit("採点できる行がありません")

    print("## 認識精度（CER。誤り文字数/参照文字数）\n")
    print("| 範囲 | 表記のまま | 正規化後 | 読み正規化後 |")
    print("|---|---|---|---|")
    yomi = Path(__file__).parent / "yomi"
    groups = [("全体", matched)] + [(name, [m for m in matched if m[0]["style"] == key]) for key, name in STYLES.items()]
    for name, group in groups:
        pairs = [(row["expected"], u["inserted"]) for row, u in group]
        if yomi.exists() and pairs:
            refs, hyps = readings([p[0] for p in pairs], yomi), readings([p[1] for p in pairs], yomi)
            by_reading = pooled(list(zip(refs, hyps)), cer)
        else:
            by_reading = "-" if not pairs else f"未計測（{yomi} が無い）"
        print(f"| {name}（{len(group)} 文） | {pooled(pairs, cer, raw=True)} | {pooled(pairs, cer)} | {by_reading} |")

    print("\n## 辞書の効き（台本全文に対する CER、正規化後）\n")
    without = pooled([(row["script"], u["raw"]) for row, u in matched], cer)
    with_dictionary = pooled([(row["script"], u["afterDictionary"]) for row, u in matched], cer)
    print(f"- 辞書なし: {without}\n- 辞書あり: {with_dictionary}")
    replaced = [(row, r) for row, u in matched for r in u["replacements"]]
    wrong = [(row, r) for row, r in replaced if r["surface"] not in row["script"]]
    print(f"- 置換 {len(replaced)} 件、うち台本に無い表記への置換（誤置換） {len(wrong)} 件")
    for row, r in replaced:
        print(f"  - {row['id']}: {r['original']} → {r['surface']}{'　**誤置換**' if (row, r) in wrong else ''}")

    print("\n## コマンド判定\n")
    for row, u in matched:
        if row["command"] or SEND in row["script"]:
            got = u.get("command") == "send"
            print(f"- {row['id']}: 期待 {'送信' if row['command'] else '送らない'}、結果 {'送信' if got else '送らない'} → {'正' if got == row['command'] else '**誤**'}")

    print("\n## 発話冒頭の欠け（認識結果が台本の 2〜4 文字目から始まる行。文頭の誤認識は数えない）\n")
    def head_drop(script: str, raw: str) -> int:
        ref, hyp = normalize(script), normalize(raw)
        return next((k for k in (1, 2, 3) if not hyp.startswith(ref[:3]) and hyp.startswith(ref[k:k + 3])), 0)
    dropped = [(row, u, head_drop(row["script"], u["raw"])) for row, u in matched]
    dropped = [d for d in dropped if d[2]]
    print(f"- {len(dropped)} 件")
    for row, u, count in dropped:
        print(f"  - {row['id']}: 文頭 {count} 文字が欠落。台本「{row['script'][:8]}…」 認識「{u['raw'][:8]}…」")

    print("\n## 遅延（秒）\n")
    def stats(values: list[float]) -> str:
        return f"中央値 {statistics.median(values):.2f}、最大 {max(values):.2f}"
    timings = [u["timings"] for _, u in matched]
    print(f"- キーを離す → 確定: {stats([t['releaseToFinal'] for t in timings])}")
    print(f"- 挿入の所要: {stats([t['insert'] for t in timings])}")
    print(f"- 整形なしの合成（確定待ち + 挿入）: {stats([t['releaseToFinal'] + t['insert'] for t in timings])}　基準: 中央値 0.5 以内")
    print(f"- 実測（後処理を含む。整形が有効ならその待ちを含む）: {stats([t['releaseToFinal'] + t['postprocess'] + t['insert'] for t in timings])}")
    methods: dict[str, int] = {}
    for _, u in matched:
        methods[u["insertion"]["method"]] = methods.get(u["insertion"]["method"], 0) + 1
    print(f"- 挿入経路: {methods}")

    print("\n## 整形\n")
    formatted = [(row, u, formats[u["id"]]) for row, u in matched if u["id"] in formats]
    if not formatted:
        print("- 整形の記録なし（整形が無効だった）")
        return
    counts: dict[str, int] = {}
    for _, _, f in formatted:
        counts[f["status"]] = counts.get(f["status"], 0) + 1
    print(f"- 判定: {counts}（{len(formatted)} 文）")
    print(f"- 完了時間: {stats([f['seconds'] for _, _, f in formatted])}")
    print("\n| # | 判定 | 秒 | 整形前（辞書置換後） | 整形の出力 |")
    print("|---|---|---|---|---|")
    for row, u, f in formatted:
        before = u["afterDictionary"]
        print(f"| {row['id']} | {f['status']} | {f['seconds']:.2f} | {before} | {f.get('output') or f.get('detail') or ''} |")


if __name__ == "__main__":
    main()
