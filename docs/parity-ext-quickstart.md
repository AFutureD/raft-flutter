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
3. **Register** the builder with one line in `tool/parity-ext/builders.txt` (order = run order;
   `build-cases.py` first). An unlisted `build-*.py` still runs last, alphabetically, with a warning.
   On a merge conflict in that file keep both lines.
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

## Dark sampling

Only the first `elegant-dark` case per surface (`components.<area>.<surface>`) runs; elegant-dark just
re-skins elegant-light. `PARITY_EXT_ALL_DARK=1` runs all of them.

## Rules

- No full-suite runs (`run run` without `--cases`) and no `tool/check-project` per task; the lead runs them per batch.
- Run your cases once per change, read the output once. No polling or sleep loops; no sub-agents.
- Do not publish; do not touch the raft-source checkout; do not commit `build/`.
