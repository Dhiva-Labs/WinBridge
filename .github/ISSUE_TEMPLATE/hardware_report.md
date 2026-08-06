---
name: Hardware report
about: Tell others what worked (or didn't) with your device
title: "[hw] <vendor> <device>"
labels: hardware-report
---

**Device** (printer, GPU, USB gadget, ...):

**Ids**: `lsusb` line or `lspci -nn` line for the device:

**Distro / kernel**: (`lsb_release -ds`, `uname -r`)

**What works natively** (no VM involved):

**What needed the VM** (driver or vendor app installed in the VM, passthrough
used, print bridge, ...):

**What doesn't work at all**:

**Notes** (exact packages, winbridge commands, gotchas):
