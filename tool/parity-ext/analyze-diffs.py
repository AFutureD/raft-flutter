#!/usr/bin/env python3
"""Bucket the differing pixels of each parity case by likely cause.

  tool/parity-ext/analyze-diffs.py [--out build/parity-ext] [--cases GLOB] [--all] [--json FILE]

Works on any provider output tree laid out like the official CLI's
(`<out>/visual-testing-results/{react,android}/<case>.png`), so it also reads the
official suite: `--out build/parity`.

The official score (`pixelPerfectSimilarity`) counts pixels whose RGBA is
exactly equal after flattening on white. Every mismatched pixel is assigned
to the first bucket that explains it:

  fill     both images are locally flat (3x3 constant) and differ by <= 4/255:
           blend / colour rounding over a uniform fill.
  hairline on (or 1px next to) a long straight horizontal/vertical edge of either
           image and the mismatch band is <= 3px thick: border / divider pixel
           snapping and edge coverage.
  corner   near the junction of a horizontal and a vertical edge: rounded-corner
           anti-aliasing arcs.
  offset   a (4*density+1)^2 patch around the pixel matches (mean delta <= 2)
           when the Flutter image is shifted by whole CSS px up to 3px (or one
           device px): real geometry offsets.
  text     dense ink neighbourhood (5x5 luminance range >= 48) that no shift
           explains: glyph rasterisation / sub-pixel glyph placement.
  other    everything else (wrong colours, missing / extra content).

For each bucket the report also gives the score the case would reach if that
bucket's pixels matched, which ranks the systematic causes by leverage.
"""
import argparse
import fnmatch
import hashlib
import json
import pathlib
import multiprocessing
import sys
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUCKETS = ('fill', 'hairline', 'corner', 'offset', 'text', 'other')
PASS = 96.0
# Geometry pass (tool/parity-ext/run summary): similarity >= this after counting the
# `text` bucket as matching. See docs/parity.md "Extension suite: non-text score".
GEOMETRY_PASS = 99.5


def load(path):
    im = Image.open(path).convert('RGBA')
    a = np.asarray(im).astype(np.float32)
    rgb = a[..., :3] * (a[..., 3:] / 255.0) + 255.0 * (1 - a[..., 3:] / 255.0)
    return np.rint(rgb).astype(np.int16)


def pad(a, h, w):
    out = np.full((h, w, 3), 255, np.int16)
    out[:a.shape[0], :a.shape[1]] = a
    return out


def box_mean(x, r):
    """Mean over a (2r+1)^2 window, edge-padded."""
    p = np.pad(x.astype(np.float64), r, mode='edge')
    c = p.cumsum(0).cumsum(1)
    c = np.pad(c, ((1, 0), (1, 0)))
    k = 2 * r + 1
    s = c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]
    return s / (k * k)


def _dil(m, ry, rx):
    out = m.copy()
    for dy in range(-ry, ry + 1):
        for dx in range(-rx, rx + 1):
            if dy or dx:
                out |= shift(m, dy, dx, False)
    return out


def shift(a, dy, dx, fill):
    out = np.full_like(a, fill)
    h, w = a.shape[:2]
    ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
    xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
    out[yd, xd] = a[ys, xs]
    return out


def run_length(mask, axis):
    """Per-pixel length of the contiguous True run along axis (1 = horizontal)."""
    m = mask if axis == 1 else mask.T
    out = np.zeros(m.shape, np.int32)
    for i in range(m.shape[0]):
        row = m[i]
        if not row.any():
            continue
        d = np.diff(np.concatenate(([0], row.view(np.int8), [0])))
        starts, ends = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
        for s, e in zip(starts, ends):
            out[i, s:e] = e - s
    return out if axis == 1 else out.T


def flat(img):
    eq = np.ones(img.shape[:2], bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy or dx:
                eq &= (shift(img, dy, dx, -1) == img).all(-1)
    return eq


def edges(img, min_len):
    """Long straight horizontal / vertical colour edges (pixel lies on the second side)."""
    eh = (img != shift(img, 1, 0, -1)).any(-1) | (img != shift(img, -1, 0, -1)).any(-1)
    ev = (img != shift(img, 0, 1, -1)).any(-1) | (img != shift(img, 0, -1, -1)).any(-1)
    # A horizontal edge pixel continues horizontally: its left/right neighbours share its colour.
    hstraight = eh & ((img == shift(img, 0, 1, -1)).all(-1) | (img == shift(img, 0, -1, -1)).all(-1))
    vstraight = ev & ((img == shift(img, 1, 0, -1)).all(-1) | (img == shift(img, -1, 0, -1)).all(-1))
    return run_length(hstraight, 1) >= min_len, run_length(vstraight, 0) >= min_len


COLOURS = np.array([(0, 160, 255), (255, 0, 0), (255, 0, 255), (255, 160, 0), (0, 170, 0), (0, 0, 0)], np.int16)


def visualise(path, r, f, label):
    """React | Flutter | bucket map (faded React, mismatches coloured per bucket)."""
    faded = 255 - (255 - r) // 4
    faded[label >= 0] = COLOURS[label[label >= 0]]
    gap = np.full((r.shape[0], 4, 3), 128, np.int16)
    Image.fromarray(np.concatenate([r, gap, f, gap, faded], 1).astype(np.uint8)).save(path)


def classify(react_png, flutter_png, density, viz=None):
    r, f = load(react_png), load(flutter_png)
    h, w = max(r.shape[0], f.shape[0]), max(r.shape[1], f.shape[1])
    r, f = pad(r, h, w), pad(f, h, w)
    d = np.abs(r - f).max(-1)
    m = d > 0
    total = h * w
    label = np.full((h, w), -1, np.int8)
    left = m.copy()

    def take(mask, i):
        nonlocal left
        sel = left & mask
        label[sel] = i
        left = left & ~sel

    s = max(1, int(round(density)))
    take(flat(r) & flat(f) & (d <= 4), 0)

    hr, vr = edges(r, 12 * s)
    hf, vf = edges(f, 12 * s)
    hl = _dil(hr | hf, 1 * s, 0)
    vl = _dil(vr | vf, 0, 1 * s)
    thick_v = run_length(m, 0)
    thick_h = run_length(m, 1)
    take((hl & (thick_v <= 3 * s)) | (vl & (thick_h <= 3 * s)), 1)

    rr = 6 * s
    corner_zone = _dil(hr | hf, rr, rr) & _dil(vr | vf, rr, rr)
    take(corner_zone, 2)

    if left.any():
        err0 = box_mean(d, 2 * s)
        best = np.full((h, w), np.inf)
        # Whole-CSS-pixel shifts up to 3px plus +-1 device px (sub-CSS-px at 3x).
        steps = sorted({k * s for k in range(-3, 4)} | {-1, 0, 1})
        for dy in steps:
            for dx in steps:
                if dy or dx:
                    fs = shift(f, dy, dx, 255)
                    best = np.minimum(best, box_mean(np.abs(r - fs).max(-1), 2 * s))
        take((best <= 2) & (best < err0), 3)

        lum = lambda a: (a[..., 0] * 299 + a[..., 1] * 587 + a[..., 2] * 114) // 1000
        def lrange(a):
            l = lum(a)
            mx, mn = l.copy(), l.copy()
            for dy in range(-2 * s, 2 * s + 1):
                for dx in range(-2 * s, 2 * s + 1):
                    sh = shift(l, dy, dx, 0)
                    shn = shift(l, dy, dx, 255)
                    mx = np.maximum(mx, sh)
                    mn = np.minimum(mn, shn)
            return mx - mn
        take((lrange(r) >= 48) | (lrange(f) >= 48), 4)
    take(left, 5)
    if viz:
        visualise(viz, r, f, label)

    equal = total - int(m.sum())
    counts = {b: int((label == i).sum()) for i, b in enumerate(BUCKETS)}
    return {
        'size': [w, h], 'pixels': total, 'equal': round(100 * equal / total, 3),
        'buckets': {b: round(100 * c / total, 3) for b, c in counts.items()},
        'ifFixed': {b: round(100 * (equal + c) / total, 3) for b, c in counts.items()},
        'maxDelta': {b: int(d[label == i].max()) if counts[b] else 0 for i, b in enumerate(BUCKETS)},
    }


def _classify_one(args):
    react_png, flutter_png, density = args
    return classify(react_png, flutter_png, density)


def non_text_scores(pairs, jobs=None, memo=None):
    """pairs: {case id: (react png, flutter png, density)} -> {case id: {...}}.

    nonTextSimilarity is the score a case would reach if every pixel in the `text` bucket
    (glyph anti-aliasing / sub-pixel placement no whole-pixel shift explains) matched;
    textShare is that bucket's share of all pixels. Exactly equal images are not classified.
    `memo` (dict, optional) caches results by the content hash of the two PNGs."""
    memo = {} if memo is None else memo
    digest = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
    todo, out, keys = {}, {}, {}
    for cid, (rp, fp, density) in pairs.items():
        keys[cid] = f'{digest(rp)}:{digest(fp)}:{density}'
        if keys[cid] in memo:
            out[cid] = memo[keys[cid]]
        else:
            todo[cid] = (rp, fp, density)
    if todo:
        ids = list(todo)
        if jobs == 1 or len(ids) == 1:
            results = [_classify_one(todo[i]) for i in ids]
        else:
            with ProcessPoolExecutor(max_workers=jobs, mp_context=multiprocessing.get_context('fork')) as pool:
                results = list(pool.map(_classify_one, [todo[i] for i in ids], chunksize=1))
        for cid, r in zip(ids, results):
            out[cid] = memo[keys[cid]] = {
                'similarity': r['equal'], 'nonTextSimilarity': r['ifFixed']['text'],
                'textShare': r['buckets']['text'], 'buckets': r['buckets']}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default=str(ROOT / 'build/parity-ext'))
    ap.add_argument('--cases', default='*', help='glob(s), comma separated')
    ap.add_argument('--all', action='store_true', help='include passing cases')
    ap.add_argument('--json', help='write per-case results here')
    ap.add_argument('--viz', help='write <case>.png bucket maps (React | Flutter | buckets) here; '
                    'colours: fill blue, hairline red, corner magenta, offset orange, text green, other black')
    a = ap.parse_args()
    res = pathlib.Path(a.out) / 'visual-testing-results'
    globs = a.cases.split(',')
    rows = []
    for rp in sorted((res / 'react').glob('*.png')):
        cid = rp.name[:-4]
        fp = res / 'android' / rp.name
        if not fp.is_file() or not any(fnmatch.fnmatch(cid, g) for g in globs):
            continue
        meta = json.loads((res / 'react' / f'{cid}.metadata.json').read_text())
        density = (meta.get('viewport') or {}).get('density', 1)
        viz = None
        if a.viz:
            pathlib.Path(a.viz).mkdir(parents=True, exist_ok=True)
            viz = pathlib.Path(a.viz) / f'{cid}.png'
        row = {'id': cid, 'density': density, **classify(rp, fp, density, viz)}
        if a.all or row['equal'] <= PASS:
            rows.append(row)
        print(f"{row['equal']:7.2f}  " + '  '.join(f"{b}={row['buckets'][b]:.2f}" for b in BUCKETS) + f"  {cid}",
              file=sys.stderr, flush=True)
    failing = [r for r in rows if r['equal'] <= PASS]
    agg = {b: round(sum(r['buckets'][b] for r in failing) / max(1, len(failing)), 3) for b in BUCKETS}
    rescued = {b: sum(1 for r in failing if r['ifFixed'][b] > PASS) for b in BUCKETS}
    print(f'\n{len(failing)} failing case(s). Mean share of all pixels per bucket, and how many cases '
          f'would pass (>{PASS}%) if that bucket alone matched:')
    print('| bucket | mean % of pixels | cases rescued alone |\n| --- | --- | --- |')
    for b in BUCKETS:
        print(f'| {b} | {agg[b]:.2f} | {rescued[b]} |')
    print('\n| case | equal | ' + ' | '.join(BUCKETS) + ' |\n| --- | --- | ' + ' | '.join('---' for _ in BUCKETS) + ' |')
    for r in sorted(rows, key=lambda r: r['equal']):
        print(f"| {r['id'].replace('components.computers.', '')} | {r['equal']:.2f} | " +
              ' | '.join(f"{r['buckets'][b]:.2f}" for b in BUCKETS) + ' |')
    if a.json:
        pathlib.Path(a.json).write_text(json.dumps({'buckets': BUCKETS, 'cases': rows}, indent=1))


if __name__ == '__main__':
    main()
