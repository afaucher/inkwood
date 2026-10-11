#!/usr/bin/env python3
"""Compares two folders of look_probe.gd PNGs (Track P, 2026-10-10): the same views before and after a change.

    python scripts/render/look_compare.py tmp/perf/look_before tmp/perf/look_after [--save-diff DIR]

Per view: the share of pixels that differ at all, the share that differ by more than 8/255 in any channel, the mean
absolute difference, the largest. A change that must not change the look leaves these near zero (the effects layer's
smoke and the UI's animations are the only moving things; the first seconds of the hint card are waited out).
"""
import sys, os
import numpy as np
from PIL import Image

def main() -> int:
    a_dir, b_dir = sys.argv[1], sys.argv[2]
    save = None
    if "--save-diff" in sys.argv:
        save = sys.argv[sys.argv.index("--save-diff") + 1]
        os.makedirs(save, exist_ok=True)
    names = sorted(f for f in os.listdir(a_dir) if f.endswith(".png") and os.path.exists(os.path.join(b_dir, f)))
    worst = 0.0
    for n in names:
        a = np.asarray(Image.open(os.path.join(a_dir, n)).convert("RGB"), dtype=np.int16)
        b = np.asarray(Image.open(os.path.join(b_dir, n)).convert("RGB"), dtype=np.int16)
        if a.shape != b.shape:
            print("%-16s SIZE DIFFERS %s vs %s" % (n, a.shape, b.shape))
            continue
        d = np.abs(a - b).max(axis=2)
        any_ = float((d > 0).mean()) * 100.0
        big = float((d > 8).mean()) * 100.0
        print("%-16s differ at all %6.3f %%   by > 8/255 %6.3f %%   mean abs diff %.4f   max %3d" % (n, any_, big, float(np.abs(a - b).mean()), int(d.max())))
        worst = max(worst, big)
        if save:
            out = np.clip(d * 8, 0, 255).astype(np.uint8)
            Image.fromarray(out).save(os.path.join(save, n))
    print("worst share of pixels differing by more than 8/255: %.3f %%" % worst)
    return 0

if __name__ == "__main__":
    sys.exit(main())
