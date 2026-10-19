"""The theme contract's value appendix must match the sources it is generated from.

`docs/theme-contract/values-appendix.md` and `values.json` are generated from
`a57b9dab` (Brutal / Elegant) and the vendored raft-ui 0.7.1 `tokens.json` by
`tool/theme-contract/dump_theme_values.py`. Regenerating is a one-liner, so a
stale appendix is always a mistake — either a source moved and nobody
regenerated, or the appendix was edited by hand.

Run directly (`python3 tool/tests/test_theme_values.py`) or as part of the host
tests in `tool/check-project`; `tool/preflight` runs it as `theme-values`.
"""

import subprocess
import sys
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1]
SCRIPT = TOOL / 'theme-contract' / 'dump_theme_values.py'


class ThemeValuesTest(unittest.TestCase):
    def test_appendix_is_current(self):
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), '--check'],
            capture_output=True, text=True, check=False)
        self.assertEqual(
            completed.returncode, 0,
            'theme value appendix is stale; run '
            f'`python3 {SCRIPT.relative_to(TOOL.parent)}`\n'
            f'{completed.stdout}{completed.stderr}')


if __name__ == '__main__':
    unittest.main()
