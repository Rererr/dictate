#!/usr/bin/env python3
"""日本語 CER（文字誤り率）を標準ライブラリだけで計算する。

使い方: cer.py REF.txt HYP.txt [--raw]
  既定は正規化後（NFKC・空白と句読点記号を除去）で比較し、--raw で原文のまま比較する。
  出力: JSON {cer, sub, del, ins, ref_len, halluc}
  halluc は「参照に無い 10 文字以上の連続挿入」の件数（幻聴の代理指標。difflib の insert 操作で数える）

正規化しないと句読点の有無や全角半角で CER が数ポイント動く。参照文は数字をアラビア数字で
書く（Whisper 系・Apple とも「10月4日」と出すため。漢数字変換はしない）。
"""
import difflib
import json
import re
import sys
import unicodedata

HALLUC_MIN_CHARS = 10

_PUNCT = re.compile(r"[\s、。，．・,.!！?？「」『』（）()\[\]【】〈〉《》〜～~\-－―…:：;；\"'“”‘’]")  # NFKC 後に残る ASCII 側も含める


def normalize(s: str) -> str:
    return _PUNCT.sub("", unicodedata.normalize("NFKC", s))


def edit_ops(ref: str, hyp: str) -> tuple[int, int, int]:
    """Levenshtein の (置換, 削除, 挿入) を返す。O(len(ref)*len(hyp)) の素朴な DP。"""
    n, m = len(ref), len(hyp)
    # dp[i][j] = (cost, sub, del, ins)
    prev = [(j, 0, 0, j) for j in range(m + 1)]
    for i in range(1, n + 1):
        cur = [(i, 0, i, 0)]
        for j in range(1, m + 1):
            if ref[i - 1] == hyp[j - 1]:
                cur.append(prev[j - 1])
                continue
            s, d, ins = prev[j - 1], prev[j], cur[j - 1]
            best = min((s[0] + 1, 0), (d[0] + 1, 1), (ins[0] + 1, 2))
            if best[1] == 0:
                cur.append((s[0] + 1, s[1] + 1, s[2], s[3]))
            elif best[1] == 1:
                cur.append((d[0] + 1, d[1], d[2] + 1, d[3]))
            else:
                cur.append((ins[0] + 1, ins[1], ins[2], ins[3] + 1))
        prev = cur
    _, sub, dele, ins = prev[m]
    return sub, dele, ins


def cer(ref: str, hyp: str, raw: bool = False) -> dict:
    if not raw:
        ref, hyp = normalize(ref), normalize(hyp)
    if not ref:
        raise ValueError("参照文が空です")
    sub, dele, ins = edit_ops(ref, hyp)
    halluc = sum(1 for tag, _, _, j1, j2 in difflib.SequenceMatcher(None, ref, hyp, autojunk=False).get_opcodes()
                 if tag == "insert" and j2 - j1 >= HALLUC_MIN_CHARS)
    return {"cer": round((sub + dele + ins) / len(ref), 4), "sub": sub, "del": dele, "ins": ins, "ref_len": len(ref), "halluc": halluc}


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    ref = open(args[0], encoding="utf-8").read()
    hyp = open(args[1], encoding="utf-8").read()
    print(json.dumps(cer(ref, hyp, raw="--raw" in sys.argv), ensure_ascii=False))
