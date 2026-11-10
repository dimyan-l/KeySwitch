#!/usr/bin/env python3
"""Convert FrequencyWords 2018 Spanish counts to KeySwitchES TSV scores.

Source: hermitdave/FrequencyWords, content/2018/es/es_50k.txt, commit
525f9b560de45753a5ea01069454e72e9aa541c6 (CC BY-SA 4.0).
Usage: python3 tools/build_es_dict.py es_50k.txt Resources/Dictionaries/es.tsv
"""

import math
import re
import sys
import unicodedata

source, output = sys.argv[1:3]
counts = {}
total = 0
pattern = re.compile(r"^[a-záéíóúüñ]+$")
with open(source, encoding="utf-8") as stream:
    for line in stream:
        try:
            raw, count = line.rsplit(" ", 1)
            count = int(count)
        except ValueError:
            continue
        total += count
        word = unicodedata.normalize("NFC", raw.lower())
        if pattern.fullmatch(word) and (len(word) > 1 or word in "aeouy"):
            counts[word] = counts.get(word, 0) + count

with open(output, "w", encoding="utf-8") as stream:
    for word, count in sorted(counts.items(), key=lambda pair: -pair[1]):
        score = math.log10(count / total * 1_000_000_000 + 1)
        stream.write(f"{word}\t{score:.2f}\n")
print(f"Wrote {len(counts)} Spanish words to {output}")
