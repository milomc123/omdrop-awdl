# Selected AWDL peers and firmware membership

The BCM4388 firmware on the Asahi test host reports `awdl_maxpeers = 8`
(2026-10-07, first four bytes of an iovar GET: `08 00 00 00`). Trailing bytes in
that GET buffer are not additional peer counts. Do not increase the watcher
capacity based on the length of the returned buffer.

The macOS 15.7.4 legacy IO80211 sample chooses an LRU eviction candidate only
among eligible peers; protected traffic classes are excluded. The active
DriverKit driver's maximum-size routine queries `awdl_maxpeers`. These findings
support controlled admission; they do not establish every active native policy.

The watcher now supports `--protect MAC[,MAC...]` for **explicitly selected**
peers. It primes them after startup resynchronization, retains them through
unrelated traffic, and declines new admission if all slots are protected.
Protection lasts for that watcher process. It ends at normal window shutdown,
when firmware entries are released. MAC rotation requires a new selection.
This is an operator/testing option, not an authentication decision: packet
contents cannot grant protection. `--only` remains an independent allowlist;
if specified, every protected peer must also be allowed. Capacity remains 1..8.

The discoverability helper owns that watcher and accepts
`start 600 --protect MAC[,MAC...]`. Protected windows require 1..600 seconds;
extending one preserves its selection and cannot make it unbounded. Stop the
window before changing the selection. This restores the helper integration
after the upstream library split; no second watcher should be started manually.

Only one watcher should own an interface. Do not launch a second instance beside
an active discoverability supervisor: startup resynchronization deliberately
clears the predecessor's permanent-neighbour-backed firmware entries.
The normal supervisor does not supply protected peers yet. Integrating selected
CompanionLink peers with the root-owned provider remains necessary for automatic
clipboard operation in a crowded environment.

Firmware DELETE failures retain local membership and the permanent neighbour;
the slot is not reused. Startup resynchronization also fails closed if it cannot
clear a stale firmware entry. The degraded marker retains failures across
successful operations on unrelated peers. Failure tracking is bounded to 64
entries; overflow keeps status degraded until the watcher is restarted. These checks prevent a successful
last ADD from hiding failed eviction accounting.

Run deterministic admission/failure tests with:

```sh
python3 -m unittest discover -s tests -p 'test_peer*.py' -v
```

The provider suite passes 64 tests (one environment-dependent test skipped);
12 tests cover peer admission and failure handling. Installed Nix userspace
checks also pass. These changes are unit-tested; crowded-room clipboard recovery and the protected
watcher option have not yet been hardware-validated. The default supervisor's
behaviour changes only in failure accounting; protected admission is opt-in.
