import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'userspace'))
from awdl_peer_registry import PeerRegistry


class PeerRegistryTests(unittest.TestCase):
    def test_protected_oldest_peer_survives_pressure(self):
        registry = PeerRegistry(2, protected=[b'a'])
        registry.add(b'a')
        registry.add(b'b')
        deleted = []
        self.assertTrue(registry.make_room(lambda peer: deleted.append(peer) or True))
        registry.add(b'c')
        self.assertEqual(deleted, [b'b'])
        self.assertEqual(list(registry), [b'a', b'c'])

    def test_delete_failure_does_not_free_a_slot(self):
        registry = PeerRegistry(1)
        registry.add(b'a')
        self.assertFalse(registry.make_room(lambda peer: False))
        self.assertEqual(list(registry), [b'a'])
        with self.assertRaises(ValueError):
            registry.add(b'b')

    def test_all_protected_declines_new_admission(self):
        registry = PeerRegistry(2, protected=[b'a', b'b'])
        registry.add(b'a')
        registry.add(b'b')
        def unexpected_delete(peer):
            self.fail('protected peer must not be deleted')
        self.assertFalse(registry.make_room(unexpected_delete))
        self.assertEqual(list(registry), [b'a', b'b'])

    def test_touch_changes_only_lru_order(self):
        registry = PeerRegistry(2)
        registry.add(b'a')
        registry.add(b'b')
        registry.touch(b'a')
        self.assertEqual(registry.eviction_candidate(), b'b')
        registry.touch(b'unknown')
        self.assertEqual(list(registry), [b'b', b'a'])

    def test_capacity_and_protection_bounds(self):
        for capacity in [0, -1, 9]:
            with self.assertRaises(ValueError):
                PeerRegistry(capacity)
        with self.assertRaises(ValueError):
            PeerRegistry(1, protected=[b'a', b'b'])


if __name__ == '__main__':
    unittest.main()
