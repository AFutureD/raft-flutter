#!/usr/bin/env python3
"""Compact outline of one DOM dump written by `tool/parity-ext/run dom-dump`.

  tool/parity-ext/dom-summary.py build/parity-ext/react-dom/<caseId>.json [--all] [--no-pad]

One line per element that has own text or paints a box (background, border or
shadow); `--all` also prints pure wrappers. Rects are relative to the capture
target's top-left: [x,y wxh]. Text: font size/weight/lineHeight/color.
"""
import json
import sys


def px(v):
    try:
        f = float(str(v).replace('px', ''))
    except ValueError:
        return str(v)
    return str(int(f)) if f == int(f) else f'{f:g}'


def paints(st):
    bg = st['backgroundColor'] not in ('rgba(0, 0, 0, 0)', 'transparent')
    border = any(st[k] not in ('0px', '') for k in ('borderTopWidth', 'borderBottomWidth', 'borderLeftWidth', 'borderRightWidth'))
    return bg, border, st['boxShadow'] not in ('none', '')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    flags = {a for a in sys.argv[1:] if a.startswith('--')}
    if len(args) != 1:
        sys.exit(__doc__)
    d = json.load(open(args[0]))
    c = d['card']
    print(f"{d['caseId']}  card {c['w']}x{c['h']} at ({c['x']},{c['y']}) viewport {d['viewport']['width']}x{d['viewport']['height']}")
    for n in d['nodes']:
        st, r = n['style'], n['rect']
        bg, border, shadow = paints(st)
        if not (n.get('text') or bg or border or shadow or '--all' in flags):
            continue
        name = n['tag']
        if n.get('testid'):
            name += f"[{n['testid']}]"
        if n.get('slot'):
            name += f"<{n['slot']}>"
        out = [f"{'  ' * n['depth']}{name} [{px(r['x'])},{px(r['y'])} {px(r['w'])}x{px(r['h'])}]"]
        if n.get('text'):
            out.append(f"\"{n['text']}\" {px(st['fontSize'])}/{px(st['lineHeight'])} w{st['fontWeight']} {st['color']}")
            if st['letterSpacing'] not in ('normal', '0px'):
                out.append(f"ls={st['letterSpacing']}")
            if st['textTransform'] != 'none':
                out.append(st['textTransform'])
        if bg:
            out.append(f"bg={st['backgroundColor']}")
        if border:
            w = [px(st[k]) for k in ('borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth')]
            out.append(f"border={'/'.join(w)} {st['borderColor']}")
        if shadow:
            out.append(f"shadow={st['boxShadow']}")
        if st['borderRadius'] not in ('0px', ''):
            out.append(f"r={st['borderRadius']}")
        if '--no-pad' not in flags:
            pad = [px(st[k]) for k in ('paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft')]
            if any(p != '0' for p in pad):
                out.append(f"pad={'/'.join(pad)}")
        if st['opacity'] != '1':
            out.append(f"op={st['opacity']}")
        print(' '.join(out))


if __name__ == '__main__':
    main()
