# Parity extension: agent quickstart

One page for adding or fixing a surface in the extension suite
(`tool/parity-ext/run`; background in docs/parity.md "Extension suite").

## Add a surface

1. **React host** `tool/parity-ext/host/<Area>Cases.tsx`: expose
   `function parityExt<Area>Element()` returning the element for your case ids,
   otherwise `null`. Fixture data: `import x from "virtual:parity-ext/<name>"`
   (= `tool/parity-ext/fixtures/<name>.json`). `tool/parity-ext-web.mjs` appends every host file.
2. **Builder** `tool/parity-ext/build-<area>.py`: replace your `components.<area>.*`
   cases in the manifest at `manifest_path()` (`from builders import manifest_path`; copy
   `build-notification-card.py`). It may also write `fixtures/<name>.json`. The manifest
   (`build/parity-ext/cases.json`) is generated every run and never committed.
3. **No registration**: every `build-*.py` is discovered automatically (`build-cases.py` first, then by an optional
   top-level `ORDER = n` constant in the builder, default 1000, then by file name). Add `ORDER = n` only if your
   builder must run before or after another one (it reads/amends the manifest); no shared file is edited.
4. **Flutter**: `apps/raft_flutter/test/parity/cases/ext_<area>.dart` (a `Map<String, ParityCase>`
   keyed like the case's `androidCaseHint`) and one `...ext<Area>Cases` line in `case_map.dart`.
   Crop with `capture.androidKey` (a `ValueKey` in the widget); interactions with `capture.androidInteractions`.

## Run only your cases

```bash
export PARITY_EXT_WEB_PORT=4xxx        # unique per agent; the default 4396 collides
tool/parity-ext/run run --cases 'components.<area>.*'   # comma list / globs; --refresh-react to recapture
```

Results: `build/parity-ext/summary.md` (per-case table, per-area table) and `site/index.html`.

## Done criterion

**Geometry pass** for every case of your area: `summary.md` column "non-text" >= 99.5%
(similarity after counting pixels classified as text glyph anti-aliasing as matching;
`tool/parity-ext/analyze-diffs.py --cases <glob> --viz DIR` shows where the rest is, as
fill / hairline / corner / offset / text / other). The official 96% "exact" pass is reported next
to it and is not the target. **Never iterate on text anti-aliasing** (text bucket); fix layout,
colour, spacing, borders, radii, and glyph positions that move by whole pixels.

## React cache

Captures are cached across worktrees in `/home/kevinzhow/github/raft-flutter-wt/.parity-cache/react/<key>.png`
(`PARITY_EXT_CACHE` overrides). Key = raft-source commit, the case JSON without Flutter-only
fields, the fixtures and host `.tsx` that render it, `parity-ext-web.mjs`, the spec patches and
render flags. Edit a host/fixture/case and only its cases recapture; Flutter edits never do.
`--refresh-react` ignores and overwrites the entries. Each entry has a `.key.json` listing its inputs.

## Theme sampling

brutal-light (the default theme) runs every case. elegant-light and elegant-dark run 1-2 cases per surface
(`components.<area>.<surface>`): the first case in builder order plus one dense case (name with a density word such as
`long`, `many`, `mixed`, `gallery`, `filled`, `full`, `rich`, `multi`, `batch`, else the last case of the surface);
rule and word list in `tool/parity-ext/sampling.py`. Write your builder so the surface's FIRST case is its default
variant. `--cases` globs only see the sampled manifest; set `PARITY_EXT_ALL_THEMES=1` to run an elegant case that
sampling dropped (`PARITY_EXT_ALL_DARK=1` keeps every elegant-dark case; elegant-light stays sampled).

## Page inventory

`docs/parity-page-inventory.md` lists every Web page / modal / state and which have a brutal-light case (official id or
extension id) or none. After adding cases update the matching row in `tool/parity-ext/inventory.py` (the `d=` / `p=`
ids) and run `python3 tool/parity-ext/inventory.py`; the unit tests fail on a stale document or an unknown id.

## Rules

- No full-suite runs (`run run` without `--cases`) and no `tool/check-project` per task; the lead runs them per batch.
- Run your cases once per change, read the output once. No polling or sleep loops; no sub-agents.
- Do not publish; do not touch the raft-source checkout; do not commit `build/`.
