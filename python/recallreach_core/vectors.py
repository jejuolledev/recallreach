"""Tiny deterministic text embedding for IRIS Vector Search.

Character-trigram hashing into 128 dimensions, L2-normalised.  No model
download, same result on every machine.  Good enough to map
"Lisinopril tablets, USP" -> MIMIC drug name "Lisinopril" and to survive
spelling variants ("hydrALAZINE", "Levothyroxine Sodium").
"""
import hashlib
import math
import re

DIM = 128
STOP = {"usp", "tablets", "tablet", "capsules", "capsule", "injection", "oral", "solution", "mg", "mcg",
        "ml", "hcl", "hydrochloride", "sodium", "for", "and", "in", "the", "rx", "only", "extended", "release"}


def normalize(name):
    s = (name or "").lower()
    s = re.sub(r"\(.*?\)", " ", s)
    s = re.sub(r"[^a-z ]", " ", s)
    words = [w for w in s.split() if w not in STOP and len(w) > 1]
    return " ".join(words[:4])


def embed(name):
    s = " " + normalize(name) + " "
    v = [0.0] * DIM
    for i in range(len(s) - 2):
        g = s[i:i + 3]
        h = int(hashlib.md5(g.encode()).hexdigest()[:8], 16)
        v[h % DIM] += 1.0 if (h >> 8) & 1 else -1.0
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [round(x / n, 6) for x in v]


def to_iris(vec):
    return ",".join("%g" % x for x in vec)


def cosine(a, b):
    return sum(x * y for x, y in zip(a, b))
