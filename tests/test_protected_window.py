"""Bounded protected windows use one supervisor and preserve its selection."""
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_core_coexistence import function


ROOT = Path(__file__).resolve().parents[1]
HELPER = (ROOT / "userspace/omdrop-discoverable").read_text()
LIBRARY = (ROOT / "userspace/omdrop-broadcom.sh").read_text()
PEER = "02:11:22:33:44:55"


class ProtectedWindowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def start(self, args, current=None):
        if current is not None:
            (self.root / "protected-peers").write_text(current + "\n")
        functions = "\n".join(function(HELPER, name) for name in
                              ("protected_selection", "cmd_start"))
        functions += function(LIBRARY, "is_duration")
        script = f'''set -uo pipefail
RUN={shlex.quote(str(self.root))}
log(){{ printf '%s\\n' "$*" >&2; }}
die(){{ local rc=$1; shift; log "$*"; exit "$rc"; }}
need_root(){{ :; }}
core_supervisor_pids(){{ :; }}
supervisor_alive(){{ {'true' if current is not None else 'false'}; }}
kill_children(){{ :; }}
radio_up(){{ printf radio > "$RUN/radio-touched"; exit 77; }}
{functions}
cmd_start {shlex.join(args)}
'''
        return subprocess.run(["bash", "-c", script], capture_output=True,
                              text=True, timeout=10)

    def test_invalid_selection_never_touches_radio(self):
        for peer in ("", "ff:ff:ff:ff:ff:ff", "00:00:00:00:00:00",
                     "02:11:22:33:44:55;id", ",".join([PEER] * 9)):
            with self.subTest(peer=peer):
                self.assertEqual(self.start(["600", "--protect", peer]).returncode, 2)
                self.assertFalse((self.root / "radio-touched").exists())

    def test_protected_window_rejects_unbounded_and_excessive_durations(self):
        for seconds in ("0", "601", "6000"):
            self.assertEqual(self.start([seconds, "--protect", PEER]).returncode, 2)

    def test_valid_selection_reaches_radio_gate(self):
        self.assertEqual(self.start(["600", "--protect", PEER]).returncode, 77)

    def test_active_selection_cannot_be_replaced(self):
        result = self.start(["600", "--protect", "02:11:22:33:44:66"], PEER)
        self.assertEqual(result.returncode, 2)
        self.assertEqual((self.root / "protected-peers").read_text().strip(), PEER)

    def test_active_protection_cannot_be_extended_without_bound(self):
        self.assertEqual(self.start(["0"], PEER).returncode, 2)

    def test_extending_preserves_selection_and_uses_existing_supervisor(self):
        result = self.start(["600", "--protect", PEER.upper()], PEER)
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertTrue((self.root / "until").exists())
        self.assertFalse((self.root / "radio-touched").exists())

    def test_supervisor_passes_selection_to_its_single_watcher(self):
        (self.root / "protected-peers").write_text(PEER + "\n")
        script = f'''set -uo pipefail
RUN={shlex.quote(str(self.root))}
LIB=/unused IF=awdl0 ADV_FLAGS=136
is_duration(){{ return 0; }}
kill_children(){{ :; }}
spawn(){{ if [[ $1 == peers ]]; then printf '%s\\n' "$@"; exit 0; fi; }}
{function(HELPER, 'supervise')}
supervise 123456 600
'''
        result = subprocess.run(["bash", "-c", script], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-2:], ["--protect", PEER])
