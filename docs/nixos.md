# NixOS

This integration installs the AWDL driver, radio helpers, sender, polkit policy,
and boot-time `awdl0.service`. It does not install an AirDrop receiver.

## Prerequisites

Use an Apple Silicon Mac with Apple's Broadcom Wi-Fi, an Asahi-enabled kernel,
and the firmware already configured by your NixOS Apple Silicon setup. The
module does not select a kernel or fetch Apple firmware. The replacement driver
requires `aarch64-linux`, and the kernel must build `brcmfmac` and `brcmutil` as
modules rather than built-ins.

Kernel API compatibility still matters: building against the selected kernel's
headers does not make the vendored driver compatible with every kernel release.
The flake lock pins a standalone Asahi build target for reproducible checks.

## Install with a flake

Add an input to your system flake:

```nix
inputs.omdrop-awdl = {
  url = "github:brentkearney/omdrop-awdl";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

While testing a local checkout, use `url = "path:/absolute/path/to/omdrop-awdl"`
instead. Include the module in the existing `nixosSystem` declaration:

```nix
modules = [
  # Existing Apple Silicon and machine modules go here.
  inputs.omdrop-awdl.nixosModules.default
  { services.omdrop-awdl.enable = true; }
];
```

For a configuration without flakes, copy this repository into the configuration
tree and add `./omdrop-awdl/nix/module.nix` to `imports`.

Build a boot generation, then reboot into it. Replace `HOST` with your flake's
configuration name:

```bash
sudo nixos-rebuild boot --flake /etc/nixos#HOST
sudo reboot
```

The first build may also build the selected kernel if its development outputs
are missing from your binary caches. Subsequent AWDL changes reuse those kernel
outputs and compile only the replacement driver.

Nix installs the driver under `updates/omdrop-awdl/`, alongside the stock kernel
modules. A failed driver build prevents installation of the new generation;
your previous generation remains available. This differs from DKMS's automatic
stock-driver fallback.

## Use

Check boot setup and the loaded driver:

```bash
systemctl status awdl0.service
ip -6 addr show dev awdl0
modinfo -n brcmfmac
test -e /sys/module/brcmfmac/parameters/awdl_trace
```

`modinfo` should report a path containing `updates/omdrop-awdl`. The parameter
check confirms the AWDL instrumentation is present in the loaded module, rather
than only in the module files for the new generation.

From a local desktop session, open a ten-minute window:

```bash
pkexec "$(readlink -f "$(command -v omdrop-discoverable)")" start 600
omdrop-discoverable status --json
send-to-peer --list
send-to-peer FILE
pkexec "$(readlink -f "$(command -v omdrop-discoverable)")" stop
```

Resolve the helper's real path so it matches the packaged polkit action. That
action preserves the Arch package's authorization policy: local active sessions
can change discoverability without a password; remote and inactive sessions
require administrator authentication. Driver reloads through `awdl-up --reload`
use ordinary administrator authorization and interrupt Wi-Fi.

Bluetooth wake-up support is included in the Python environment. Enable
`hardware.bluetooth.enable` in your system configuration to use it. Without a
running BlueZ service, discovery is limited to devices already listening.

Receiving requires the [Omdrop receiver](https://github.com/brentkearney/omdrop-plugin)
or another compatible receiver. Configure its firewall rules separately,
including TCP 8771 and any discovery ports it uses on `awdl0`. This radio module
does not open firewall ports or install the Omarchy desktop plugin.

## Configure

All options live under `services.omdrop-awdl`:

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Install and configure the radio integration |
| `package` | Packaged userspace helpers | Override the helpers and matching policy |
| `driver.enable` | `true` | Install the replacement driver; disable for an already patched kernel |
| `driver.package` | Built against `boot.kernelPackages` | Override the driver derivation |
| `settings` | `{}` | One-line files under `/etc/omdrop`, using the README's configuration names |

For example:

```nix
services.omdrop-awdl = {
  enable = true;
  settings = {
    infra-iface = "wlan0";
    peer-chan = 44;
    chan-shape = "dense";
  };
};
```

Keep certificates and private keys in the existing per-user identity storage;
do not put them in Nix configuration or the Nix store.

When NetworkManager is enabled, the module keeps `awdl0` unmanaged through NixOS
configuration. The packaged helper disables its runtime configuration-file
fallback. If you use a different network manager, exclude `awdl0` yourself.
When Avahi is enabled, the module excludes `awdl0` to prevent hostname conflicts
from multicast echoes; the AWDL helper supplies its own mDNS responder.

## Packaging and validation

The expressions also work without flakes:

```nix
pkgs.callPackage ./nix/userspace.nix { }
config.boot.kernelPackages.callPackage ./nix/driver.nix { }
```

On an Apple Silicon Linux build host:

```bash
nix build .#userspace .#driver
nix flake check
```

The standalone `driver` output uses the Asahi kernel pinned in `flake.lock`.
The NixOS module instead uses the consuming system's selected kernel and package
set. Following the consumer's `nixpkgs` input does not replace its Asahi setup.

On `x86_64-linux`, `nix flake check` builds the userspace package and runs the
existing unit tests and NixOS module checks. The hardware driver output and its
module-selection check are available on `aarch64-linux` only.

Checks exercise installed tools with an empty environment, Python dependencies,
the policy's executable path, module configuration, and the existing identity
and supervisor tests. The driver check combines stock and replacement modules,
then verifies that `modinfo` and `modprobe` select the AWDL modules.

These checks do not establish radio compatibility. A hardware report should
include the Mac model, Wi-Fi PCI ID, kernel version, loaded module path, and
observed discovery, sending, and receiving behavior.

Keep `nix/version.nix` in sync with `pkgver` in `PKGBUILD`. Driver patches and
vendored sources remain shared with the Arch package; Nix packaging does not
carry a separate kernel patch series.
