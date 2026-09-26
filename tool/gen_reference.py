#!/usr/bin/env python3
"""Generate test/fixtures/reference.json from the original Python app
(logic/eqloader.py), so the Dart port can be checked against it.

    python3 tool/gen_reference.py
"""

import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "logic"))
import eqloader as eq  # noqa: E402

BANDS = [
    {"type": "PK", "freq": 1000.0, "gain": 3.5, "q": 1.41},
    {"type": "PK", "freq": 27.0, "gain": -8.4, "q": 0.5},
    {"type": "LSQ", "freq": 105.0, "gain": 6.0, "q": 0.7},
    {"type": "HSQ", "freq": 8000.0, "gain": -4.2, "q": 0.9},
    {"type": "LP", "freq": 16000.0, "gain": 0.0, "q": 0.707},
    {"type": "HP", "freq": 30.0, "gain": 0.0, "q": 0.707},
    {"type": "PK", "freq": 2900.0, "gain": 1.45, "q": 2.0},
]


def synthetic_measurement():
    """A headphone-ish curve: bass shelf, 3 kHz ear gain, treble peaks."""
    pts = []
    f = 20.0
    while f <= 20000:
        v = (6 / (1 + (f / 120) ** 2)
             + 9 * math.exp(-(math.log2(f / 3000) ** 2) / 0.5)
             + 5 * math.exp(-(math.log2(f / 8500) ** 2) / 0.05)
             - 7 * math.exp(-(math.log2(f / 450) ** 2) / 0.3))
        pts.append((f, v + 80))
        f *= 1.02
    return pts


def target_curve():
    pts = []
    f = 20.0
    while f <= 20000:
        pts.append((f, 5 / (1 + (f / 100) ** 2) + 8 * math.exp(-(math.log2(f / 2800) ** 2) / 0.6)))
        f *= 1.05
    return pts


def main():
    freqs = [20 * (1000 ** (i / 49)) for i in range(50)]
    ref = {
        "bands": BANDS,
        "packets": [eq.build_filter_packet(i, b, 2) for i, b in enumerate(BANDS)],
        "response_freqs": freqs,
        "response": {
            b["type"] + str(i): eq.filters_response_db(freqs, [b]).tolist()
            for i, b in enumerate(BANDS)
        },
        "response_all": eq.filters_response_db(freqs, BANDS).tolist(),
        "preamp_to_register": [
            [p, b, eq.preamp_to_register(p, b)]
            for p in (-7.3, -5.0, -2.5, 0.0, 3.0, -10.5)
            for b in (-5.0, 0.0)
        ],
        "q_to_bw": [[q, eq.q_to_bw(q)] for q in (0.5, 0.707, 1.0, 2.0, 5.0)],
        "profiles": {},
        "iso226_offset": eq.iso226_find_offset(synthetic_measurement(), 60.0),
    }
    for name in ("pulled_profile.txt", "pulled_profile2.txt", "pulled_profile3.txt"):
        path = ROOT / "logic" / name
        data = eq.load_profile(str(path))
        active = eq.active_filters(data["filters"])
        out = ROOT / "build" / f"ref_{name}"
        out.parent.mkdir(exist_ok=True)
        eq.save_profile(str(out), data["preamp"], data["filters"])
        ref["profiles"][name] = {
            "text": path.read_text(),
            "preamp": data["preamp"],
            "active": active,
            "saved": out.read_text(),
        }

    measurement = synthetic_measurement()
    target = target_curve()
    ref["autoeq"] = {
        "measurement": measurement,
        "target": target,
        "cases": [],
    }
    for tgt, n in ((None, 8), (target, 8), (target, 3)):
        filters, preamp = eq.autoeq_compute(measurement, tgt, n)
        ref["autoeq"]["cases"].append(
            {"flat": tgt is None, "max_filters": n, "filters": filters, "preamp": preamp})

    dest = ROOT / "test" / "fixtures" / "reference.json"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(ref, indent=1))
    print(f"wrote {dest}")


if __name__ == "__main__":
    main()
