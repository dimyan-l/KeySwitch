#!/usr/bin/env python3
"""Merge subtitle (conversational) + Wikipedia frequency lists into compact per-language
dictionaries for KeySwitch. Output format: one 'word<TAB>score' line, score = log10 per-billion freq."""
import math, re, sys, os

SRC = sys.argv[1]          # dir with raw lists
OUT = sys.argv[2]          # output dir
TOP = int(sys.argv[3]) if len(sys.argv) > 3 else 80000

ALPHA = {
    "ru": re.compile(r"^[а-яё]+(-[а-яё]+)?$"),
    "en": re.compile(r"^[a-z]+('[a-z]+)?$"),
}
FILES = {
    "ru": ["ru_50k.txt", "ruwiki-2022-08-29.txt"],
    "en": ["en_50k.txt", "enwiki-2023-04-13.txt"],
}

def load(path, rx, limit=400000):
    d, total = {}, 0
    with open(path, encoding="utf-8", errors="ignore") as f:
        for i, line in enumerate(f):
            if i >= limit:
                break
            parts = line.rstrip("\n").split(" ")
            if len(parts) != 2:
                continue
            w, c = parts[0].lower().replace("ё", "е"), int(parts[1])
            total += c
            if rx.match(w):
                d[w] = d.get(w, 0) + c
    return d, total

for lang, files in FILES.items():
    merged = {}
    for fn in files:
        d, total = load(os.path.join(SRC, fn), ALPHA[lang])
        for w, c in d.items():
            p = c / total * 1e9  # per billion
            merged[w] = max(merged.get(w, 0), p)
    # Single letters: only keep real one-letter words
    singles = {"ru": set("явискоуа"), "en": set("ai")}[lang]
    merged = {w: p for w, p in merged.items() if len(w) > 1 or w in singles}
    top = sorted(merged.items(), key=lambda x: -x[1])[:TOP]
    with open(os.path.join(OUT, f"{lang}.tsv"), "w", encoding="utf-8") as f:
        for w, p in top:
            f.write(f"{w}\t{math.log10(p + 1):.2f}\n")
    print(lang, len(top), "min score", f"{math.log10(top[-1][1] + 1):.2f}")
