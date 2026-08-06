# Devices: printers, USB, and GPUs

Windows kernel drivers can never load into the Linux kernel. That is a hard
boundary, not a bug — but it is narrower than it looks. The failure mode
people actually hit is almost never "there is no Linux driver for my
hardware." It is "there is no Linux build of the vendor's *companion app*" —
the utility suite bundled with a printer, a graphics card, or a peripheral
that configures it, updates its firmware, or unlocks features beyond what the
device does on its own. Printing, scanning, and 3D acceleration usually have
solid native Linux paths already; what is missing is the Windows-only
software layered on top, and that is exactly what the VM this project already
builds Windows binaries on is good for.

None of what follows assumes particular hardware. Epson shows up as the
worked example for printers and NVIDIA for GPUs because they are common cases
with a lot to say about them, not because WinBridge treats them specially —
each section leads with the vendor-agnostic decision path first. If your
setup does not fit cleanly into any of this, file a report at
[`.github/ISSUE_TEMPLATE/hardware_report.md`](../.github/ISSUE_TEMPLATE/hardware_report.md) —
"it doesn't work" recorded honestly is more useful to the next person than an
untested guess in these docs would be.

## Printers

**Check driverless IPP first**, regardless of brand. Most printers made in
the last decade — across Brother, HP, Canon, Epson and others — speak IPP
Everywhere or AirPrint over the network, or IPP-over-USB, which CUPS on
modern Ubuntu auto-discovers with no driver installed at all:

```sh
ippfind                        # finds IPP/IPP-USB printers announcing themselves
lpinfo -v                      # lists everything CUPS can currently see
```

Add it from the CUPS web UI (`http://localhost:631` → Administration → Add
Printer) or your desktop's printer settings. If it shows up there, you are
done — no vendor software, Linux or Windows, involved.

Vendors also ship native Linux packages for models or features driverless IPP
does not cover: Brother publishes `.deb`/`.rpm` drivers per model on its
support site, HP's `hplip` covers a large chunk of HP's range from the
Ubuntu/Debian repos directly, and Canon publishes Linux driver packages for
most of its printer and scanner lines. Check those before reaching for the VM
— they give you a real native driver, not a bridge.

### Worked example: Epson

- **Driverless IPP** — as above; a large share of Epson's current lineup
  supports it and needs nothing installed.
- **Non-IPP models** — Epson's own `epson-inkjet-printer-escpr` (older,
  pre-AirPrint models) and `epson-inkjet-printer-escpr2` (current ET-series
  and newer) `.deb` packages, from Epson's Linux driver downloads.
- **Scanning** — the SANE `epson2` backend covers most models out of the box
  (`sane-utils`/`libsane`); for the ones it does not, Epson's own `imagescan`
  (built on `utsushi`) fills the gap.
- **Maintenance, natively** — ink levels, nozzle checks and head cleaning do
  not need Windows either: `escputil` from the `gutenprint` package handles
  all three (`escputil -P <printer> --ink-levels`, `--nozzle-check`,
  `--clean-head`).
- **What is actually Windows-only** — Epson's "Smart Panel" utility suite and
  its firmware updaters. Neither has a Linux build, and neither is something
  you need often. This is the VM's job: USB-passthrough the printer (or point
  it at a printer reachable from the VM over the network) with `winbridge vm
  usb passthrough`, install Epson's Windows software inside the VM once, and
  run it there the rare times you actually need it — a firmware update, a
  deep-clean cycle the native tools do not expose. Day to day, print
  natively through IPP or `escpr`.

### The VM print bridge, for GDI-only printers

Some printers genuinely have no IPP mode and no native Linux driver — this
is where `scripts/printing/` earns its place. The shape:

1. Get the printer reachable from the VM: either `winbridge vm usb
   passthrough <vendor:product>` for a USB printer (see the USB section
   below), or point the VM at the printer over the network if it has one.
2. Install the vendor's Windows driver inside the VM, the same way you would
   on any Windows machine.
3. Send jobs to it with `scripts/printing/winbridge-print.sh` — as a
   standalone command, piped a PDF, or wired up as a CUPS System V filter —
   or run `scripts/printing/print-vm-side.ps1` inside the VM to watch a
   folder and print whatever lands there. Both use SumatraPDF's silent
   `-print-to`; see the scripts' own header comments for every flag and
   environment variable, and `setup-windows.ps1 -WithPrinting` to install
   SumatraPDF on the VM.

**On the SumatraPDF download**: `-WithPrinting` fetches a version-pinned zip
from the project's own domain over TLS. SumatraPDF publishes no checksum
alongside its releases, so there is no vendor hash to pin — which leaves the
vendor and their CDN trusted for that one download. If that is not a trade you
want to make, verify a copy yourself and pass its hash: the script then checks
every later run against it.

```powershell
Get-FileHash .\SumatraPDF-3.6.1-64.zip -Algorithm SHA256   # once, on a copy you trust
.\setup-windows.ps1 -PublicKey "..." -WithPrinting -SumatraSha256 <hash>
```

**The real limitation**: per-job settings — paper size, duplex, tray, quality
— are not exposed through this bridge. They live in the printer's Windows
driver *default* dialog inside the VM. Set them once there for how you
normally print; a job-by-job override would mean reimplementing that driver's
UI, which is out of scope here. If that is a hard blocker for your workflow,
that is worth a hardware report too.

## USB devices generally

```sh
winbridge vm usb list                    # non-hub devices attached to this host
winbridge vm usb list --all              # include hubs and root hubs
winbridge vm usb passthrough <vendor:product>
```

`passthrough` prints, but never applies, both:

- the **dockur/windows** compose fragment (an `ARGUMENTS` addition plus the
  `/dev/bus/usb` device mapping) — the container needs recreating
  (`docker compose up -d --force-recreate`) for it to take effect, a running
  one will not pick it up;
- the **libvirt** equivalent (a `<hostdev>` XML fragment and the matching
  `virsh attach-device ... --live --config` for attaching to a running VM
  without touching the domain definition directly).

Either way, the device shows up in the VM as if physically plugged in, and
its Windows driver installs exactly as on real hardware.

One thing worth knowing: a **USB 3** device passed through to a VM whose
virtual USB controller is still USB 2 (the default in a lot of stock
configurations) will negotiate down to USB 2 speeds. If throughput matters,
check that the guest's controller is configured for `qemu-xhci` (dockur/
windows and recent libvirt defaults generally already do this; older
libvirt XML sometimes still defaults to `ich9-usb-uhci`, worth checking).

## GPUs

The vendor-agnostic fact first: **a Windows GPU driver can only ever run
inside a Windows kernel.** It cannot be "installed on Linux" in any form —
there is no path where a `.exe` from NVIDIA, AMD or Intel ends up driving
your Linux desktop. Every GPU vendor with hardware in active use has a native
Linux path; which one you need depends on the card.

- **AMD and Intel** — nothing to install for the driver itself. Both are
  in-kernel (`amdgpu`, `i915`) plus Mesa for the userspace OpenGL/Vulkan
  implementation; a stock Ubuntu install already has both. Newer Mesa
  releases (for newer hardware or newer API features) are available via the
  `kisak-mesa` PPA or similar if the distro's own package is behind.
- **NVIDIA** — the proprietary driver is not optional the way it is for
  AMD/Intel; it is the *only* way to drive an NVIDIA card on Linux at all
  (the in-kernel `nouveau` driver exists but is reverse-engineered and far
  behind for anything performance-sensitive). Install it with:

  ```sh
  ubuntu-drivers devices          # see what Ubuntu recommends for your card
  sudo ubuntu-drivers install     # install the recommended driver
  ```

  On Turing and newer (RTX 20-series onward), Ubuntu also packages NVIDIA's
  **open-source kernel modules** (`nvidia-driver-XXX-open`) as an alternative
  to the proprietary kernel module — same proprietary userspace, open kernel
  layer.

### Worked example: NVIDIA's companion apps

The NVIDIA App (GeForce Experience's successor), Broadcast, and similar are
utilities layered on top of the driver, not drivers themselves — driver
updates, game-specific tuning, AI-powered webcam/mic effects. They have no
Linux build and, unlike a printer's maintenance utility, running them
meaningfully requires the actual GPU under their control: there is no point
running the NVIDIA App inside a VM that only has a virtual display adapter.
That means these only ever work through **full VFIO GPU passthrough** — the
VM gets exclusive, direct control of the physical card, not just a plugged-in
peripheral. Say this plainly: **giving the VM your only GPU means the Linux
desktop goes dark while the VM holds it.** That is a real, supported
configuration, not a failure state — plenty of people run it — but it is a
cost you are choosing, not a bug to work around.

### VFIO passthrough overview

This is the shape of it, not a complete walkthrough — get the details from
the sources linked below, which stay current as kernels and QEMU change
faster than this document would.

1. **IOMMU** — enable VT-d (Intel) or AMD-Vi (AMD) in the BIOS/UEFI, then add
   `intel_iommu=on` or `amd_iommu=on` (`iommu=pt` is usually recommended
   alongside it) to the kernel command line and reboot. Confirm with `dmesg
   | grep -i iommu` and check that the GPU sits in its own IOMMU group (or a
   group you are willing to pass through as a unit).
2. **vfio-pci binding** — find the GPU's PCI ids with `lspci -nnk`, then bind
   the GPU *and* its HDMI/DP audio function to `vfio-pci` instead of
   `nvidia`/`amdgpu`/`i915`. This can be static (kernel module options, so
   the host driver never claims the card) or dynamic (a script that unbinds
   the host driver and binds `vfio-pci` right before the VM starts).
3. **Second GPU vs. one GPU** — a second GPU (or a capable iGPU) for the host
   to keep using while the VM owns the discrete card is simpler to set up:
   no unbind/rebind dance, the host desktop never goes away. It is *not*
   required. **Single-GPU passthrough is fully supported**: the common
   pattern is a pair of scripts hooked into libvirt's lifecycle
   (`/etc/libvirt/hooks/qemu`, `prepare`/`release` events) that stop the
   display manager and rebind the GPU to `vfio-pci` when the VM starts, and
   reverse both when it stops. Expect the host display to drop (and
   sometimes need a manual `systemctl start display-manager` or similar) for
   as long as the VM has the card.
4. **dockur/windows** documents its own GPU passthrough support (device
   mapping for an iGPU, or full PCI passthrough for a discrete card) in its
   README — check there for the current compose syntax rather than here.

**Authoritative references** (these are maintained elsewhere and get this
right in more depth than is useful to duplicate):

- [Arch Wiki: PCI passthrough via OVMF](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF) —
  the de facto community reference for the whole setup, including single-GPU.
- [dockur/windows](https://github.com/dockur/windows) — GPU-related
  environment variables and device mapping for this project's own compose
  file.

## Vendor utilities generally

The pattern across all of the above, generalized: when a device needs
software beyond what Linux already gives it natively, work through this in
order.

1. **A native Linux equivalent exists?** Use it — a native tool beats a VM
   round-trip every time. This covers most printing, scanning and GPU
   driver needs, as above.
2. **The vendor utility only configures or maintains the device** — firmware
   updates, one-off calibration, a settings panel you touch occasionally?
   Run it inside the VM with the device passed through, when you actually
   need it. This is the Epson Smart Panel case, and it is a good fit: rare,
   short-lived use of a Windows tool for something native Linux tooling does
   not expose.
3. **The vendor utility has to run continuously for the device to work at
   all** — some RGB lighting suites, macro engines and similar peripheral
   "software-defined" features fall here. Be honest about this one: keeping
   a whole VM running around the clock just so a keyboard's backlight stays
   a particular color is a poor trade, and WinBridge does not paper over
   that. Where the device supports it, use its onboard/hardware profiles
   instead of the software ones; where it does not, this is a real
   limitation, not a solved problem.

If you land on (3), or on anything else that does not fit this cleanly, that
is exactly what
[`.github/ISSUE_TEMPLATE/hardware_report.md`](../.github/ISSUE_TEMPLATE/hardware_report.md)
is for — a short, honest record of what worked and what did not, for the next
person with the same device.
