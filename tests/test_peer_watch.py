"""Exercise the watcher's actual functions without AF_PACKET or firmware access."""
import ast
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'userspace'))
from awdl_peer_registry import PeerRegistry


class PeerWatchFailureTests(unittest.TestCase):
    def setUp(self):
        source = ast.parse((ROOT / 'userspace' / 'awdl-peer-watch.py').read_text())
        # Load original function bodies, excluding the privileged top-level loop.
        functions = ast.Module(body=[node for node in source.body
                                    if isinstance(node, ast.FunctionDef)], type_ignores=[])
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {'os': os, 'time': time, 'args': SimpleNamespace(iface='test0'),
                    'registered': PeerRegistry(1), 'FAILED_PEERS': set(),
                    'MAX_FAILED_PEERS': 64, 'FAILURE_OVERFLOW': False,
                    'DEGRADED': str(Path(self.tmp.name) / 'degraded'),
                    'subprocess': SimpleNamespace(run=Mock()),
                    'print': Mock()}
        exec(compile(functions, 'awdl-peer-watch.py', 'exec'), self.env)
        self.env['peer_op'] = Mock(return_value=(False, 'BCME_RANGE'))
        self.peer = bytes.fromhex('020000000001')

    def test_failed_delete_retains_neighbour_and_firmware_membership(self):
        self.env['registered'].add(self.peer)
        self.assertFalse(self.env['forget'](self.peer))
        self.assertIn(self.peer, self.env['registered'])
        self.env['subprocess'].run.assert_not_called()
        self.assertTrue(Path(self.env['DEGRADED']).exists())

    def test_successful_retry_releases_slot_and_clears_failure(self):
        self.env['registered'].add(self.peer)
        self.env['forget'](self.peer)
        self.env['peer_op'].return_value = (True, 'OK')
        self.assertTrue(self.env['forget'](self.peer))
        self.assertNotIn(self.peer, self.env['registered'])
        self.assertFalse(Path(self.env['DEGRADED']).exists())

    def test_unrelated_success_does_not_hide_failure(self):
        self.env['note_peer_op']('02:00:00:00:00:01', False)
        self.env['note_peer_op']('02:00:00:00:00:02', True)
        self.assertTrue(Path(self.env['DEGRADED']).exists())
        self.env['note_peer_op']('02:00:00:00:00:01', True)
        self.assertFalse(Path(self.env['DEGRADED']).exists())

    def test_resync_failure_preserves_neighbour_and_declines_startup(self):
        self.env['subprocess'].run.return_value = SimpleNamespace(
            returncode=0, stdout='fe80::1 lladdr 02:00:00:00:00:01 PERMANENT\n')
        self.assertFalse(self.env['resync']())
        self.assertEqual(self.env['subprocess'].run.call_count, 1)
        self.assertTrue(Path(self.env['DEGRADED']).exists())

    def test_failure_tracking_is_bounded_and_overflow_stays_degraded(self):
        for index in range(100):
            self.env['note_peer_op'](str(index), False)
        self.assertEqual(len(self.env['FAILED_PEERS']), 64)
        for index in range(100):
            self.env['note_peer_op'](str(index), True)
        self.assertTrue(Path(self.env['DEGRADED']).exists())

    def test_resync_neighbour_read_failure_declines_startup(self):
        self.env['subprocess'].run.return_value = SimpleNamespace(returncode=1, stdout='')
        self.assertFalse(self.env['resync']())
        self.env['peer_op'].assert_not_called()

    def test_no_add_or_neighbour_change_after_failed_eviction(self):
        self.env['registered'].add(self.peer)
        self.assertFalse(self.env['register'](bytes.fromhex('020000000002')))
        self.env['peer_op'].assert_called_once_with(1, self.peer)
        self.env['subprocess'].run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
