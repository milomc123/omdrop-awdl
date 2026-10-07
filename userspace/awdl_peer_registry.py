"""Bounded firmware membership and LRU eviction of unprotected entries.

Protection is explicit local policy, never inferred from an unauthenticated
packet. Firmware DELETE must succeed before its slot can be reused.
"""


class PeerRegistry:
    def __init__(self, capacity, protected=()):
        if not 1 <= capacity <= 8:
            raise ValueError('capacity must be between 1 and 8')
        self.capacity = capacity
        self.protected = frozenset(protected)
        if len(self.protected) > capacity:
            raise ValueError('protected peers exceed capacity')
        self.entries = {}

    def __contains__(self, peer):
        return peer in self.entries

    def __iter__(self):
        return iter(self.entries)

    def touch(self, peer):
        if peer in self.entries:
            self.entries.pop(peer)
            self.entries[peer] = None

    def add(self, peer):
        if peer in self.entries:
            self.touch(peer)
            return
        if len(self.entries) >= self.capacity:
            raise ValueError('firmware registry is full')
        self.entries[peer] = None

    def remove(self, peer):
        self.entries.pop(peer, None)

    def eviction_candidate(self):
        return next((peer for peer in self.entries if peer not in self.protected), None)

    def make_room(self, delete):
        if len(self.entries) < self.capacity:
            return True
        peer = self.eviction_candidate()
        if peer is None or not delete(peer):
            return False
        self.remove(peer)
        return True
