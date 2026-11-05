#!/usr/bin/env python3
"""Reference implementation of the KeySwitch word classifier.
The Swift version (LayoutClassifier.swift) mirrors this logic one-to-one, so thresholds
calibrated here carry over."""
import math, os, random, sys

EN_KEYS = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`"
RU_KEYS = "йцукенгшщзхъфывапролджэячсмитьбюё"
EN2RU = dict(zip(EN_KEYS, RU_KEYS)); RU2EN = dict(zip(RU_KEYS, EN_KEYS))

def flip(word, to):  # to = 'ru' or 'en'
    m = EN2RU if to == "ru" else RU2EN
    return "".join(m.get(c, c) for c in word)

ALPHABET = {"ru": set("абвгдежзийклмнопрстуфхцчшщъыьэюя-"),
            "en": set("abcdefghijklmnopqrstuvwxyz'-")}

# ---- thresholds (calibrated by evaluate()) ----
FREQ_MARGIN = 2.0        # both readings are dict words: other must be this much more frequent (log10)
NGRAM_MARGIN = 0.6       # neither in dict: avg log-prob gap per char
NGRAM_FLOOR = -3.3       # other reading must look at least this "wordy"
MIN_NGRAM_LEN = 3

class Lang:
    def __init__(self, code, tsv, custom=None, limit=None):
        self.code = code
        self.words = {}
        with open(tsv, encoding="utf-8") as f:
            for i, line in enumerate(f):
                if limit and i >= limit: break
                w, s = line.rstrip("\n").split("\t")
                self.words[w] = float(s)
        if custom:
            for line in open(custom, encoding="utf-8"):
                if line.startswith("#"): continue
                for w in line.split():
                    w = w.lower().replace("ё", "е")
                    self.words[w] = max(self.words.get(w, 0), 6.0)
        self.train_ngrams()

    def train_ngrams(self):
        counts, ctx = {}, {}
        for w, s in self.words.items():
            weight = s  # log-frequency weighting
            t = "^^" + w + "$"
            for i in range(2, len(t)):
                g, c = t[i-2:i+1], t[i-2:i]
                counts[g] = counts.get(g, 0) + weight
                ctx[c] = ctx.get(c, 0) + weight
        self.counts, self.ctx = counts, ctx
        self.V = len(ALPHABET[self.code]) + 1

    def ngram(self, w):
        t = "^^" + w + "$"; lp = 0.0; n = 0
        for i in range(2, len(t)):
            g, c = t[i-2:i+1], t[i-2:i]
            p = (self.counts.get(g, 0) + 0.1) / (self.ctx.get(c, 0) + 0.1 * self.V)
            lp += math.log10(p); n += 1
        return lp / n

    def is_alpha(self, w):
        return all(ch in ALPHABET[self.code] for ch in w) and any(ch.isalpha() for ch in w)

def decide(typed, cur, other, langs):
    """typed: word as produced by current layout. Returns converted word or None."""
    wc = typed.lower().replace("ё", "е")
    wo = flip(typed, other.code).lower().replace("ё", "е")
    # trailing punctuation keys (, . ; ') belong to letters in RU: strip only from the EN side
    if not other.is_alpha(wo):
        return None, "other-not-alpha"
    cur_ok = cur.is_alpha(wc)
    sc = cur.words.get(wc) if cur_ok else None
    so = other.words.get(wo)
    if sc is not None and so is None:
        return None, "cur-dict"
    if so is not None and sc is None:
        if len(wo) == 1:
            return None, "single-letter"   # handled by context retro-fix
        return wo, "other-dict"
    if so is not None and sc is not None:
        return (wo, "freq") if so - sc >= FREQ_MARGIN else (None, "both-dict")
    if len(wo) < MIN_NGRAM_LEN:
        return None, "short"
    ngo = other.ngram(wo)
    ngc = cur.ngram(wc) if cur_ok else -9.0
    if ngo > NGRAM_FLOOR and ngo - ngc >= NGRAM_MARGIN:
        return wo, "ngram"
    return None, "ngram-no"

def evaluate(dictdir, rawdir):
    ru = Lang("ru", f"{dictdir}/ru.tsv", f"{dictdir}/custom_ru.txt")
    en = Lang("en", f"{dictdir}/en.tsv", f"{dictdir}/custom_en.txt")
    L = {"ru": ru, "en": en}
    random.seed(1)
    def sample(lang, fn, n, lo=0, hi=20000):
        rows = []
        for i, line in enumerate(open(f"{rawdir}/{fn}", encoding="utf-8")):
            if i < lo: continue
            if i >= hi: break
            w, c = line.split(" ")
            w = w.lower().replace("ё", "е")
            if L[lang].is_alpha(w) and len(w) > 1: rows.append((w, int(c)))
        ws, cs = zip(*rows)
        return random.choices(ws, weights=cs, k=n) if lo == 0 else random.sample(ws, min(n, len(ws)))
    report = {}
    for lang, other, fn in (("ru", "en", "ru_50k.txt"), ("en", "ru", "en_50k.txt")):
        for label, words in (("frequent(weighted)", sample(lang, fn, 20000)),):
            fp = sum(1 for w in words if decide(w, L[lang], L[other], L)[0] is not None)
            fixed = sum(1 for w in words if decide(flip(w, other), L[other], L[lang], L)[0] == w)
            report[(lang, label)] = (fp / len(words), fixed / len(words))
    # rare words, not in dict (n-gram fallback): wiki ranks 300k..600k
    for lang, other, fn in (("ru", "en", "ruwiki-2022-08-29.txt"), ("en", "ru", "enwiki-2023-04-13.txt")):
        words = [w for w in sample(lang, fn, 6000, 300000, 600000) if w not in L[lang].words][:3000]
        fp = sum(1 for w in words if decide(w, L[lang], L[other], L)[0] is not None)
        fixed = sum(1 for w in words if decide(flip(w, other), L[other], L[lang], L)[0] == w)
        report[(lang, "rare(not in dict)")] = (fp / len(words), fixed / len(words))
    for (lang, label), (fp, rec) in report.items():
        print(f"{lang:2} {label:20} ложные срабатывания {fp*100:5.2f}%   исправлено при неверной раскладке {rec*100:5.1f}%")
    return L

if __name__ == "__main__":
    L = evaluate(sys.argv[1], sys.argv[2])
    ru, en = L["ru"], L["en"]
    tests = [("ghbdtn", en, ru), ("ytn", en, ru), ("rfr", en, ru), ("nj", en, ru), ("ds", en, ru),
             ("he", en, ru), ("ok", en, ru), ("sql", en, ru), ("hubspot", en, ru), ("cjpdjy", en, ru),
             ("ltgkjq", en, ru), ("fencnfaa", en, ru), ("ифслгз", ru, en), ("ыйд", ru, en),
             ("руддщ", ru, en), ("щл", ru, en), ("ьшпкфешщт", ru, en), ("lfnf,fpf", en, ru),
             ("ikmyfz", en, ru), ("rjnjhsq", en, ru), ("ghjlfrity", en, ru), ("vthl;", en, ru),
             ("linkedin", en, ru), ("slack", en, ru), ("jr", en, ru), ("ntvf", en, ru), ("pfghjc", en, ru),
             ("ckfr", en, ru), ("ltyfyc", en, ru), ("cdjtq", en, ru)]
    for t, c, o in tests:
        print(f"{t:12} -> {decide(t, c, o, L)}")
