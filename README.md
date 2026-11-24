# Omnipha Linux for Google Tensor GS101

Mainline-based Linux kernel source for Google Tensor GS101 devices. The first
bring-up target is Google Pixel 6 Pro (`raven`). This repository contains kernel
sources, not a complete bootable image or installer. A successful compile does
not demonstrate that the kernel boots or that device features work.

## Source and history

The initial source tree is identical to Nura's Tensor/Exynos Linux
[`tensor-master`](https://gitlab.nura.eco/soc/tensor-exynos/linux/-/tree/tensor-master)
commit `e8f42849a581ea8e915ad0f10c25951e696dc6b5` (Linux 7.3.0-rc6).
The imported root snapshot commit is `2b9171062b902a04d116bb907cb66b3ebb1b3d90`
with tree `f8364cb8afa1bb9853f2d3db2391df137f031d64`, the same Git tree as the
upstream commit. This import is a new root commit, **not** the original commit
or the complete upstream history. The full upstream history is maintained at
the source URL; obtain it separately when reviewing authorship or changes.

Development in this repository is on the `main` branch. Build configuration,
reproducible commands and appropriate device packaging are tracked in
[issue #1](https://github.com/omnipha/linux-google-gs101/issues/1).
The external Tensor tree has a Raven device tree, but source presence does not
establish working hardware support.

## Current status and safety

An arm64 kernel, Raven DTB and modules were compiled from the upstream source.
On 2026-11-24 a candidate built from this tree booted on a real Pixel 6 Pro
(`raven`, slot `_a`): full Linux userspace, key-only SSH over USB-C networking
(`18d1:d001`, CDC-NCM) and passwordless `sudo` were verified, and the boot is
repeatable across a reboot. Evidence and artifact hashes are recorded in
[`Documentation/gs101/raven-boot-failure-analysis.md`](Documentation/gs101/raven-boot-failure-analysis.md).
The display currently shows no mainline panel output (`fb0` is the bootloader
framebuffer via `simpledrm`); this remains open. Image composition and device
packaging are separate from this kernel tree. Before any further device boot
or flash test, obtain explicit operator authorization and verify device
identity, artifact checksums, partition/slot targets, backups and the
device-specific recovery path.

Do not commit private keys, passwords, serial numbers, device dumps, proprietary
firmware blobs or other private data. Follow the kernel licensing notices in
[`COPYING`](COPYING) and the individual source files.
