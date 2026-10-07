#!/usr/bin/env python3
"""Register AWDL peers the moment their first frame arrives.

Two things have to exist before a Mac can complete a connection to us, and
both are derived from nothing but its MAC:

  1. a firmware peer entry (`awdl_peer_op ADD`) -- without it our unicast to
     the Mac completes tx_status 0x0003 FW_TOSSED (065508Z), so its DISCOVER
     fails and the share sheet says "No People Found";
  2. a permanent neighbour for fe80::<EUI-64 of MAC> -- ND cannot resolve
     over AWDL (062218Z: 513 NS, 0 NA), and the Mac's link-local is always
     the EUI-64 of its AWDL MAC.

The hold loop used to do both on a ~3 s poll keyed on the kernel neighbour
table, which only gets an entry once the Mac sends *unicast*; its first frames
after the sheet opens are multicast mDNS queries, seconds earlier, and every
DISCOVER in the gap failed (213115Z: 1, 215526Z: 6 over ~50 s). This watches
the interface itself and acts on the first frame from each new source MAC.

Run as root while awdl0 is up; SIGTERM ends it. One line per event on stdout.
Use --prime MAC to register one explicitly selected peer without waiting for
its first frame, print its link-local address, and exit. Failure exits nonzero.
"""
import argparse
import os
import signal
import socket
import subprocess
import sys
import time

from awdl_peer_registry import PeerRegistry

# Helpers are siblings of this file. Resolving them against the working
# directory instead made every peer_op ADD fail with python's "can't open
# file" whenever the caller ran from anywhere but the checkout root -- and a
# peer with no firmware entry silently swallows every unicast we send it.
IOVAR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'brcm_iovar.py')

ETH_P_ALL = 0x0003
PACKET_OUTGOING = 4
# Generic HT Capabilities IE (mode 01, "HT-only" 37-byte form) -- the form the
# firmware accepted in peerop2 and that made unicast complete 0x0000 (074311Z).
HT_IE = bytes.fromhex('2d1a6f881bffff000000000000000096000100000000000000000000')

ap = argparse.ArgumentParser()
ap.add_argument('--iface', default='awdl0')
ap.add_argument('--max-peers', type=int, default=8,
                help='maximum firmware entries (1..8; capacity increases are not validated)')
ap.add_argument('--only', default='',
                help='comma-separated MACs; register these and nothing else (223044Z/231000Z: '
                     'data stalled both ways after transfers in the two runs that registered strangers)')
ap.add_argument('--protect', default='',
                help='comma-separated explicitly selected MACs to prime and exclude from LRU eviction; '
                     'protection lasts for this watcher process')
ap.add_argument('--prime', metavar='MAC',
                help='register this explicitly selected peer and exit, printing its link-local address')
args = ap.parse_args()


def parse_macs(value):
    peers = set()
    for item in value.split(','):
        if not item.strip():
            continue
        try:
            mac = bytes.fromhex(item.strip().replace(':', ''))
        except ValueError:
            ap.error('peer lists require six-byte unicast MACs')
        if len(mac) != 6 or mac[0] & 1:
            ap.error('peer lists require six-byte unicast MACs')
        peers.add(mac)
    return peers


ONLY = parse_macs(args.only)
PROTECTED = parse_macs(args.protect)
try:
    registered = PeerRegistry(args.max_peers, PROTECTED)
except ValueError as error:
    ap.error(str(error))
if ONLY and not PROTECTED.issubset(ONLY):
    ap.error('--protect peers must also be allowed by --only')

with open(f'/sys/class/net/{args.iface}/address') as f:
    OURMAC = bytes.fromhex(f.read().strip().replace(':', ''))

if OURMAC in PROTECTED or OURMAC in ONLY:
    ap.error('peer lists must not contain this interface address')


def now():
    return time.strftime('%H:%M:%SZ', time.gmtime())


def eui64_ll(mac):
    b = bytearray(mac)
    b[0] ^= 0x02
    return 'fe80::%02x%02x:%02xff:fe%02x:%02x%02x' % (b[0], b[1], b[2], b[3], b[4], b[5])


# A peer with no firmware entry silently loses every unicast frame we send it:
# the transmit completes FW_TOSSED and is discarded before air. The responder
# still logs that it answered, the peer still appears in the peer table, and
# the window still reports healthy -- so the radio looks fine while it cannot
# reach that device at all. That is how an ESPIPE run went unnoticed long
# enough to be mistaken for a discovery, capability-flags, TLS and certificate
# bug in turn.
#
# So record it where `status` can find it rather than only in this log. Not an
# automatic reload: recovering costs the Wi-Fi link for ~15 s, which is not a
# decision to take behind the user's back. Reporting it is.
DEGRADED = '/run/awdl-discoverable/peerop.degraded'
FAILED_PEERS = set()
MAX_FAILED_PEERS = 64
FAILURE_OVERFLOW = False


def note_peer_op(macs, ok):
    global FAILURE_OVERFLOW
    if ok:
        FAILED_PEERS.discard(macs)
    elif len(FAILED_PEERS) < MAX_FAILED_PEERS:
        FAILED_PEERS.add(macs)
    elif macs not in FAILED_PEERS:
        FAILURE_OVERFLOW = True
    try:
        if not FAILED_PEERS and not FAILURE_OVERFLOW:
            os.path.exists(DEGRADED) and os.remove(DEGRADED)
            return
        with open(DEGRADED, 'w') as fh:
            fh.write(f'{now()} unresolved peer operation failures: {len(FAILED_PEERS)} '
                     f'overflow={int(FAILURE_OVERFLOW)}\n')
    except OSError:
        pass    # never let bookkeeping break registration


def peer_op(op, mac):
    """ADD (op 0) or DEL (op 1) a firmware peer entry. Returns (ok, tail)."""
    if op == 0:
        payload = b'\x00\x00' + mac + b'\x01' + HT_IE
    else:
        # awdl_peer_op_t = version(1) opcode(1) addr(6) mode(1). The 9-byte
        # form is DEL only: sent with opcode 0 it returns NOMEM, and one
        # variant trapped the firmware (2026-09-02). Do not reuse it for ADD.
        payload = b'\x00\x01' + mac + b'\x01'
    r = subprocess.run([sys.executable, IOVAR, '-i', args.iface, 'set',
                        'awdl_peer_op', payload.hex()], capture_output=True, text=True, timeout=8)
    tail = (r.stdout.strip().splitlines() or [''])[-1].split('-> ')[-1]
    return (r.returncode == 0 and tail == 'OK'), tail


def forget(mac):
    """Drop a peer from the firmware table and from the neighbour table."""
    macs = ':'.join(f'{x:02x}' for x in mac)
    ok, tail = peer_op(1, mac)
    if not ok:
        note_peer_op(macs, False)
        print(f'{now()} peer {macs} retained; peer_op DEL failed -> {tail}', flush=True)
        return False
    subprocess.run(['ip', '-6', 'neigh', 'del', eui64_ll(mac), 'dev', args.iface],
                   check=False, capture_output=True, timeout=8)
    registered.remove(mac)
    note_peer_op(macs, True)
    print(f'{now()} peer {macs} evicted; peer_op DEL -> {tail}', flush=True)
    return True


def resync():
    """Make the firmware table match ours, which is empty, at startup.

    The firmware keeps its peer entries across everything except a driver
    reload; this process does not. Every `omdrop on` starts a new watcher
    with an empty set, so it re-registers peers the firmware already holds
    and fills the remaining slots with rotated MACs -- which is how a table
    with 8 slots served 12 ADDs in one window, the last 4 failing ESPIPE.

    Our own permanent neighbour entries are the record of what we added, so
    they are what we clear. Peers still on air are re-registered by the loop
    within a frame or two of their next transmission.
    """
    r = subprocess.run(['ip', '-6', 'neigh', 'show', 'dev', args.iface, 'nud', 'permanent'],
                       check=False, capture_output=True, text=True, timeout=8)
    if r.returncode:
        note_peer_op('resync-neighbour-read', False)
        print(f'{now()} resync: neighbour enumeration failed; membership uncertain', flush=True)
        return False
    note_peer_op('resync-neighbour-read', True)
    stale = []
    for line in r.stdout.splitlines():
        parts = line.split()
        if 'lladdr' in parts:
            try:
                stale.append(bytes.fromhex(parts[parts.index('lladdr') + 1].replace(':', '')))
            except ValueError:
                continue
    clean = True
    for mac in stale:
        ok, tail = peer_op(1, mac)
        if not ok:
            clean = False
            note_peer_op(mac.hex(':'), False)
            print(f'{now()} resync: peer_op DEL failed -> {tail}; membership uncertain', flush=True)
            continue
        note_peer_op(mac.hex(':'), True)
        subprocess.run(['ip', '-6', 'neigh', 'del', eui64_ll(mac), 'dev', args.iface],
                       check=False, capture_output=True, timeout=8)
    if stale and clean:
        print(f'{now()} resync: released {len(stale)} peer slot(s) held from a previous window', flush=True)
    return clean


def register(mac):
    macs = ':'.join(f'{x:02x}' for x in mac)
    t0 = time.monotonic()
    ll = eui64_ll(mac)
    # Reuse only a confirmed free slot; selected peers are not LRU victims.
    if not registered.make_room(forget):
        print(f'{now()} peer {macs} not admitted: no evictable firmware slot', flush=True)
        return False
    neighbour = subprocess.run(['ip', '-6', 'neigh', 'replace', ll, 'lladdr', macs, 'dev', args.iface,
                                'nud', 'permanent'], check=False, timeout=8)
    if neighbour.returncode:
        print(f'{now()} peer {macs} neighbour registration failed rc={neighbour.returncode}', flush=True)
        return False
    ok, tail = peer_op(0, mac)
    print(f'{now()} peer {macs} neigh {ll} pinned; peer_op ADD -> {tail} rc={0 if ok else 1} '
          f'({(time.monotonic() - t0) * 1000:.0f} ms)', flush=True)
    if ok:
        registered.add(mac)
    else:
        print(f'{now()} peer {macs} HAS NO FIRMWARE ENTRY: every unicast frame to it will be '
              f'dropped before air. Clear it with: pkexec /usr/lib/omdrop/awdl-up --reload', flush=True)
    note_peer_op(macs, ok)
    return ok


# PeerRegistry retains firmware membership until DELETE succeeds.


def release(_sig=None, _frame=None, exit_status=0):
    """Hand the firmware its slots back when the window closes.

    The table survives this process, so entries held past the end of a window
    are dead weight the NEXT window inherits -- it starts against a table that
    is already full and cannot add the peer it actually needs.

    Best effort by design: SIGKILL, a crash or a suspend all skip this, which
    is why resync() at startup is the guarantee and this is the courtesy. Both
    are wanted. Releasing here keeps an idle machine from holding slots, and
    makes the common case -- a window closed normally -- cost nothing.
    """
    for mac in list(registered):
        forget(mac)
    sys.exit(exit_status)


signal.signal(signal.SIGTERM, release)
signal.signal(signal.SIGINT, release)

if args.prime:
    try:
        peer = bytes.fromhex(args.prime.replace(':', ''))
    except ValueError:
        ap.error('--prime requires a unicast peer MAC')
    if len(peer) != 6 or peer[0] & 1 or peer == OURMAC or (ONLY and peer not in ONLY):
        ap.error('--prime requires a selected unicast peer other than this interface')
    if not register(peer):
        sys.exit(1)
    print(f'{now()} primed {eui64_ll(peer)}', flush=True)
    sys.exit(0)

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
s.bind((args.iface, 0))
if not resync():
    sys.exit(1)
for peer in sorted(PROTECTED):
    if not register(peer):
        release(exit_status=1)
skipped = set()
print(f'{now()} watching {args.iface} for new peers', flush=True)
while True:
    frame, (_, _, pkttype, _, _) = s.recvfrom(2048)
    if pkttype == PACKET_OUTGOING or len(frame) < 12:
        continue
    src = frame[6:12]
    if src == OURMAC or src[0] & 1:
        continue
    if src in registered:
        # Heard again: newest in the eviction order, not a re-registration.
        registered.touch(src)
        continue
    if ONLY and src not in ONLY:
        if src not in skipped:
            skipped.add(src)
            print(f'{now()} peer {src.hex(":")} seen; not in --only, skipped', flush=True)
        continue
    register(src)
