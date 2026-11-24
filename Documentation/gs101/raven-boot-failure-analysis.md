# GS101 / Pixel 6 Pro (`raven`): fastboot boot-failure analysis

This document records the analysis of the `raven` boot failure described in
[issue #2](https://github.com/omnipha/linux-google-gs101/issues/2) (parent:
[#1](https://github.com/omnipha/linux-google-gs101/issues/1)).

It covers the reproduction of the failure from host-side evidence, the
identified root cause, the diagnostics added to this tree, and the reproducible
build and hash records for the next boot candidate.

**Status of the device test (2026-11-24):** the flash test **succeeded**.
A candidate built from this repository was flashed to `boot`, `vendor_boot`
and `userdata` on slot `_a` and booted into full Linux userspace: the repo
kernel runs, the pmOS rootfs mounts, the USB gadget enumerates as
`18d1:d001`, and both SSH and telnet answer over the USB link. The result is
reproducible across a reboot. See [Device test result](#device-test-result).
The earlier `fastboot stage` + `fastboot boot` RAM-boot attempt aborted and
left the device's USB bulk endpoints unusable until a physical re-plug; see
[Device test status](#device-test-status) for that history.

## Failed baseline

The candidate from issue #1 booted to fastboot repeatedly and never produced
kernel output:

| artifact     | sha256                                                            |
|--------------|-------------------------------------------------------------------|
| `boot.img`   | `bf4cbab0e4dff7d6ef982b6bb3f46974a57cb97a83f19bf8f879601c787ac187` |
| `vendor_boot.img` | `6792724abb2079f9fb1a0415a216d6cc23e9eb1a3b7c3c3bc6a33f054ead5356` |
| `google-raven.img` | `8afc0d6a4d1bd95489e875a7e0c59f5ae579e05e8c193cda356e17add6cc6485` |

The candidate `boot.img` kernel payload hashes to
`589fc78684d939f25164bbf96f92c960a01eebd9def9d8b44598ff6d2e4e946e`
(15 676 151 bytes) and reports
`Linux version 7.3.0-rc6-gs101 (pmos@vmware007) (Alpine clang version 23.1.6, LLD 23.1.6)`.

Reference (stock) factory images, `raven-cp3a.261005.002.a1`:

| artifact        | sha256                                                            |
|-----------------|-------------------------------------------------------------------|
| `boot.img`      | `cfde6c2dc776c338d17fb58da8bd5dc56221d625fc13ae56722a70cb27cbca50` |
| `vendor_boot.img` | `8d7b2587b3c3aa51001a636808bec66183a3f9cf902894c030e4e4be6a1d5f49` |
| `vbmeta.img`    | `127408be459f961ad105c9d766377b81c37661c789d003a4f53fc5f30e988b9f` |
| `dtbo.img`      | `99e1cf3b8d0fab3cfb45d99462d431918593d995be66ea372f6845bcc51bf59b` |

## Root cause

Two independent defects were found in the failed candidate by inspecting the
artifacts alone, without a device. A third candidate cause — DTBO overlay
incompatibility — was also proposed and has since been **disproved** by the
device test.

A candidate built from this tree, carrying fixes for all three, **boots** on
the real device (see [Device test result](#device-test-result)). The device
test does not isolate which of the fixes was the necessary one: several
things changed together, so what is proven is that the combination works.

### 1. DTBO overlay incompatibility (candidate cause 1 — DISPROVED)

> **Superseded.** This section is kept for the historical record of the
> original analysis. It is now known to be wrong: see
> [The old "overlay incompatibility" hypothesis is disproved](#the-old-overlay-incompatibility-hypothesis-is-disproved),
> which shows the stock overlays **do** resolve against this tree's DTB on the
> real device. What follows was an inference from host-side tests only.

This is the most direct host-reproducible explanation for the observed
symptom: the device returned to fastboot with no kernel output at all, on
every attempt. **It is an inference from host-side tests, not device
evidence** — the bootloader source is not available and no kernel log was
captured, so nothing here proves which step the bootloader reached.

The bootloader applies the `dtbo` partition on **every** boot. The stock
`dtbo.img` contains 18 overlay entries whose `__fixups__` sections reference
**128 distinct fixup labels** (for example `pinctrl_1`, `pinctrl_4`,
`serial_16`, `odm`, `pdma0`, `pcie_1`, `gpp17`, `sbbmux`, `modemif`,
`touch_bus_negotiator`, `bbd_pps`).

The fixups are resolved against the `__symbols__` node of the DTB that is
shipped in `vendor_boot.img`:

| DTB                | nodes | `__symbols__` entries | size (bytes) |
|--------------------|-------|-----------------------|--------------|
| stock `vendor_boot` | 1396  | 809                   | 536 176      |
| mainline `gs101-raven` | 476 | **0**              | 63 516       |

The mainline DTB in this tree carries **no `__symbols__` node at all** and is
missing **all 128** labels the overlays require. The referenced stock paths
(`/pinctrl@174E0000`, `/pinctrl@10840000`, `/serial@175B0000`, `/odm`,
`/amba/pdma0@10110000`, `/pcie@14520000`, …) simply do not exist in the
mainline tree, because mainline uses a different SoC-internal layout (for
example the UART is at `/soc@0/usi@10a000c0/serial@10a00000` rather than
`/serial@175B0000`).

Applying a stock overlay to the mainline DTB fails **on the host**:

```
$ fdtoverlay -i gs101-raven.dtb -o merged.dtb entry00.dtbo
Failed to apply 'entry00.dtbo': FDT_ERR_BADOFFSET
base blob does not have a '/__symbols__' node, make sure you have compiled
the base blob with '-@' option
```

The failed candidate's DTB was byte-identical to the mainline build
(`4cb8a443b01143cca707881849f5db40bbf747fcbf9c62f42bab0b84caf048af`). What is
established is that the host-side overlay operation fails on it; what is
**not** established is that the bootloader treats that failure as fatal. The
conclusion "the bootloader aborts the boot before the kernel is entered" is a
reasonable hypothesis consistent with the symptom, and it is the reason the
next candidate carries the **stock** DTB instead.

Note that the failed candidate was flashed with `vbmeta` verification disabled
(`avbtool make_vbmeta_image --flags 2`) and it **still** returned to fastboot.
Verified Boot is therefore **not** the blocker, and no AVB or `vbmeta` change
is required for the next candidate.

### 2. Vendor ramdisk compression format mismatch (secondary cause)

The candidate's `vendor_ramdisk00` is a **Zstandard** frame:

```
00000000: 28 b5 2f fd ...    ZSTD
```

The stock `vendor_boot.img` uses the **LZ4-legacy** format, which is what the
Pixel GKI bootloader expects:

```
00000000: 02 21 4c 18 ...    LZ4 legacy
```

The candidate was produced by pmbootstrap's `mkinitfs`, which reported
`Unknown or no compression format set, using zstd` in the build log. The
`raven` device recipe does not set `deviceinfo_initfs_compression`, so the
default was used.

This is a real format mismatch in the boot chain, but it is **not** by itself
sufficient to explain the failure: the pmOS kernel that was flashed had
`CONFIG_RD_ZSTD=y`, so it could have decompressed a zstd ramdisk. The
mismatch is still a defect worth fixing, because the format that the
bootloader itself consumes is LZ4-legacy, and a correct candidate should not
rely on the kernel compensating for a wrongly-compressed vendor ramdisk.

### 3. Kernel/module vermagic mismatch (fixed in the new candidate)

The kernel built from this tree reported `7.3.0-rc6-gs101+`, while the modules
shipped in the initramfs were built as `7.3.0-rc6-gs101`:

```
$ strings Image | grep 'Linux version'
Linux version 7.3.0-rc6-gs101+ (gregor@vmware007) (Ubuntu clang version 21.1.8, LLD 21.1.8)

$ zstd -d -c .../evdev.ko.zst | strings | grep vermagic
vermagic=7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
```

The trailing `+` comes from `scripts/setlocalversion`: `CONFIG_LOCALVERSION_AUTO`
is not set and `LOCALVERSION` is unset, so a plus sign is appended. With
`CONFIG_MODULE_SIG` and `CONFIG_MODVERSIONS` both disabled, the vermagic
string is the only consistency requirement, and the mismatch would prevent
the modules from loading.

The new candidate is built with `LOCALVERSION=`, which removes the `+` and
makes the kernel release exactly `7.3.0-rc6-gs101`, matching the modules.

## Diagnostics added to this tree

Early-boot diagnostics require a kernel log sink that survives a boot failure.
Two changes provide it.

### Persistent store (pstore/ramoops)

`CONFIG_PSTORE` was not set in the previous configuration (neither in this
tree's `.config` nor in the pmOS reference config), so there was no way to
recover a panic or early log from the device.

This tree now enables:

```
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_PSTORE_PMSG=y
```

and adds a `ramoops` reservation to
`arch/arm64/boot/dts/exynos/google/gs101.dtsi`, using the **same memory
region as the stock DTB** so that the layout matches the vendor one:

```dts
ramoops_mem: ramoops@fd3ff000 {
	compatible = "ramoops";
	reg = <0x0 0xfd3ff000 0x00400000>;
	console-size = <0x00200000>;
	pmsg-size = <0x00200000>;
};
```

The region does not collide with the reservations already present in the
mainline tree: `debug_kinfo_reserved` ends at `0xfd3ff000` and
`bldr_log_reserved` starts at `0xfd800000`.

### Early console

**Not used in the candidate that booted.** Neither `earlycon=` nor `console=`
appears on the command line of the flashed image, and `/chosen/stdout-path` is
**deleted** from `arch/arm64/boot/dts/exynos/google/gs101-raven.dts`. The
reasoning is recorded in the comment on that property: the only path that can
turn `stdout-path` into a console is `of_console_check()`, which returns false
whenever the bootloader's `console=null` has already set
`console_set_on_cmdline`, and the command-line path
(`early_init_dt_scan_chosen_stdout()`) needs a bare `earlycon` token, which
nothing provides. The property could therefore have selected nothing here, and
`CONFIG_NULL_TTY=m` (not built-in) means the `ttynull` device the bootloader
asks for cannot register either. The candidate matches the stock geometry
instead: the live tree has no `/proc/device-tree/chosen/stdout-path`, and the
only registered console is the ramoops legacy console:

```
[    0.032243] printk: legacy console [ramoops-1] enabled
[    0.312196] Warning: unable to open an initial console.
```

The two conditions below are kept because they explain why **adding** a
console later would need care.

`drivers/tty/serial/samsung_tty.c` already provides an `OF_EARLYCON_DECLARE`
handler for this platform:

```c
OF_EARLYCON_DECLARE(gs101, "google,gs101-uart", gs101_early_console_setup);
```

The early console argument selects the handler by **name** from the
`__earlycon_table`, and the register base address comes from the command line
itself (`parse_options()` in `drivers/tty/serial/earlycon.c` sets
`port->mapbase` and, for `mmio32`, `port->regshift = 2`). The DTB is therefore
not needed for the command-line form of `earlycon=`:

| DTB used in `vendor_boot.img` | UART node compatible | `earlycon=` value | `console=` |
|--------------------------------|----------------------|-------------------|------------|
| mainline `gs101-raven.dtb`     | `google,gs101-uart`  | `earlycon=gs101,mmio32,0x10A00000` | `ttySAC0` |
| stock `vendor_boot` DTB        | `samsung,exynos-uart` | `earlycon=exynos4210,mmio32,0x10A00000` | not available |

Caveat for the stock DTB: `samsung,exynos-uart` is **not** in this tree's
`s3c24xx_uart_dt_match` table, so `samsung_tty` does not bind that node and
the regular `console=ttySAC0` console is not registered. The `earlycon` output
still works, because it only needs the memory-mapped base from the command
line. This does not matter for the test, since the UART is not observable
from the host in any case; pstore and the framebuffer are the practical
channels.

With the mainline DTB the UART node would match the `gs101` earlycon entry and
the driver would register the console under the name `ttySAC`
(`S3C24XX_SERIAL_NAME`). That path is **not** used by the candidate that
booted, because the bootloader's `console=null` disables command-line console
selection and `stdout-path` is deleted — the live device confirms this with
`Warning: unable to open an initial console.` and a single registered
console, the ramoops one.

Framebuffer output is available as a second channel: `gs101-raven.dts` enables
`framebuffer-0` as a `simple-framebuffer` at 1440x3120 over `cont_splash_mem`,
and the kernel is configured with `CONFIG_FRAMEBUFFER_CONSOLE=y` and
`CONFIG_DRM_SIMPLEDRM=y`. This is the channel that actually produced
pre-userspace evidence on the device: `simple-framebuffer` is initialised at
0.937 s, before the pmOS initramfs starts.

### How to capture the early log

1. Boot with the candidate (flashed, as in [Device test result](#device-test-result)).
2. If the kernel panics, the log of the failing run is in the pstore
   filesystem of the **next** boot.
3. Read it from a working userspace:
   ```
   adb shell ls /sys/fs/pstore/
   adb shell cat /sys/fs/pstore/console-ramoops-0
   ```
   On the pmOS rootfs the same path is readable as root
   (`/sys/fs/pstore` is mode `0750 root:root`, so `sudo -n cat` works).
   The ramoops region is persistent across reboots but not across a full
   power loss, so the log must be collected after the failing boot.

   In the successful run this directory was **empty**, which is the expected
   result for a kernel that did not crash: the ramoops backend registers
   (`pstore: Registered ramoops as persistent store backend`) but only writes
   on a panic. The early-boot evidence for the successful run therefore comes
   from `dmesg` over SSH instead.

The UART at `0x10A00000` is not broken out on the device, so the UART channel
is not observable from the host; pstore and the framebuffer are the practical
channels.

## Next boot candidate

Two candidates were assembled from this repository. They differ **only** in
the DTB and the matching `earlycon` value, so a RAM-boot of each isolates
cause 1 from causes 2 and 3:

| candidate | DTB                        | purpose                                    |
|-----------|----------------------------|--------------------------------------------|
| A         | stock `vendor_boot` DTB    | bootloader overlay applies; tests kernel + ramdisk |
| B         | mainline `gs101-raven.dtb` | mainline DTB as shipped; tests whether the bootloader rejects it |

If A boots and B does not, cause 1 is supported as the blocker and the fix is
to make the mainline DTB overlay-compatible (or to flash a matching `dtbo`).
If both behave the same, cause 1 is not the differentiator and the remaining
causes have to be re-examined.

**Outcome:** candidate A was tested by RAM-boot on 2026-11-23 and **did not
boot** (it stayed in, or returned to, fastboot). That is what forced the
decision to ship the mainline DTB. The candidate that ultimately booted is
described in [Device test result](#device-test-result): it ships the
mainline DTB as a **two-FDT region** (both FDTs carrying
`soc_id = 0x9845001`) instead of the single mainline DTB of candidate B.

The A/B plan above therefore did not distinguish the causes by itself. What
the successful run does establish is listed under
[Distinguishing bytes versus the failed trio](#distinguishing-bytes-versus-the-failed-trio):
the mainline DTB region, the LZ4-legacy vendor ramdisk, the stock
`0x800` page size and the matching module vermagic together produce a
booting device.

### Build inputs

| input | value |
|-------|-------|
| kernel source | this tree, `main` branch |
| kernel release | `7.3.0-rc6-gs101` (`LOCALVERSION=` to suppress the `+` suffix) |
| toolchain | Ubuntu clang 21.1.8, LLD 21.1.8 (`LLVM=1`) |
| config | repository `.config` plus `CONFIG_PSTORE{,_RAM,_CONSOLE,_PMSG}=y` |
| vendor ramdisk | pmOS initramfs repacked with this tree's modules, LZ4-legacy compressed |
| bootconfig | stock `vendor_boot` bootconfig, unmodified |
| image tooling | `mkbootimg` / `unpack_bootimg` (Android platform-tools 34.0.5) |

Reproducible commands:

```sh
# 1. Kernel, DTBs and modules
make ARCH=arm64 LLVM=1 LOCALVERSION= -j"$(nproc)" Image.lz4 dtbs
make ARCH=arm64 LLVM=1 LOCALVERSION= -j"$(nproc)" modules
make ARCH=arm64 LLVM=1 LOCALVERSION= modules_install INSTALL_MOD_PATH=<moddir>

# 2. Initramfs: repack the pmOS initramfs with this tree's modules
cd <initramfs-root>
rm -rf usr/lib/modules/7.3.0-rc6-gs101
cp -a <moddir>/lib/modules/7.3.0-rc6-gs101 usr/lib/modules/
find . -print0 | cpio --null -o --format=newc --owner=0:0 > initramfs.cpio

# 3. Vendor ramdisk, LZ4-legacy (NOT the zstd default)
lz4 -l -f initramfs.cpio vendor-ramdisk-lz4.img

# 4. boot.img
mkbootimg --header_version 4 \
	--kernel arch/arm64/boot/Image.lz4 \
	--ramdisk empty-ramdisk \
	--cmdline '' \
	-o boot.img

# 5. vendor_boot.img
mkbootimg --header_version 4 --pagesize 0x00000800 --base 0x00000000 \
	--kernel_offset 0x10008000 --ramdisk_offset 0x11000000 \
	--tags_offset 0x10000100 --dtb_offset 0x0000000011f00000 \
	--vendor_cmdline '<see below>' --board '' \
	--dtb <dtb> --vendor_bootconfig bootconfig \
	--ramdisk_type 1 --ramdisk_name '' \
	--vendor_ramdisk_fragment vendor-ramdisk-lz4.img \
	--vendor_boot vendor_boot.img
```

The header parameters above were validated by rebuilding the stock
`vendor_boot.img` with them and comparing byte for byte: the rebuild matched
the first 32 612 352 bytes of the stock image exactly.

### Kernel command line

The candidate that booted carries **no** `earlycon=` and **no** `console=`
of its own. The bootloader appends `console=null` and the pmOS tokens come
from two sources: `/chosen/bootargs` in the DTB and the `vendor_cmdline` of
`vendor_boot.img`.

The `vendor_cmdline` (215 bytes, 8 tokens, `cand4/vendor_cmdline.txt`):

```
loglevel=8 clk_ignore_unused regulator_ignore_unused loop.max_part=7 \
printk.devkmsg=on pmos_boot_uuid=dcca49fa-fc71-498e-9f4f-09f2b80edaf1 \
pmos_root_uuid=0bcaadf4-9a11-4422-9a03-e297f1e97aaf pmos_rootfsopts=defaults
```

Every non-pmOS token was verified to be a real kernel parameter
(`__setup`/`early_param`); `ioremap_guard` and `reserve-fimc` are **not**
kernel parameters in this tree and were therefore left out. The pmOS UUID
tokens are intentionally kept out of the kernel parameter space by the pmOS
init (they are read from the command line by the initramfs), and they are
duplicated in `/chosen/bootargs` so that they survive whichever channel the
bootloader honours.

`pmos.debug-shell` is deliberately **not** set: it makes the initramfs start
a telnetd on port 23 and wait for `pmos_continue_boot`, which blocks the boot.

The resulting live command line on the device is:

```
clocksource=arch_sys_counter root=/dev/ram0 firmware_class.path=/vendor/firmware \
reserve-fimc=0xffffff90f9fe0000 clk_ignore_unused loop.max_part=7 coherent_pool=4M \
no_console_suspend softlockup_panic=1 loglevel=8 regulator_ignore_unused \
pmos_boot_uuid=... pmos_root_uuid=... pmos_rootfsopts=defaults \
loglevel=8 clk_ignore_unused regulator_ignore_unused loop.max_part=7 \
printk.devkmsg=on pmos_boot_uuid=... pmos_root_uuid=... pmos_rootfsopts=defaults \
console=null exynos_drm.panel_name=samsung-s6e3hc3 tcpci_max77759.conf_sbu=0 \
ufs_pixel_fips140.* id_aa64mmfr1.vh=0 kvm-arm.mode=nvhe bootconfig
```

The duplication is expected: the same pmOS tokens appear once from the DTB
`bootargs` and once from the `vendor_cmdline`. `console=null` and the
`exynos_drm`/`ufs_pixel_fips140`/`kvm-arm` tokens are appended by the
bootloader's own suffix.

`quiet` is deliberately absent so that early output is not suppressed, and
`loglevel=8` raises the console log level.

### Artifact hashes

| artifact | size (bytes) | sha256 |
|----------|---------------|--------|
| `Image` | 29 684 224 | `c8ba068448af2e9ac858c48fb66761ac052c201ba0118afb8f19bf3c4afe8a4a` |
| `Image.lz4` | 14 672 794 | `38e331c480b20772b4a3bd772285cb04e6598dec06e6c3d4fc7197e62973a561` |
| `gs101-raven.dtb` (single, rebuilt) | 94 069 | `d1a170e6fde5ac27c3634da3a55a98694d340dd55dd99ffdf9ba0283a8373c02` |
| `raven-region.dtb` (two-FDT, flashed) | 536 176 | `d3ca24573a9df941bc52655772b2db705ee936c1e5ba3e20d1fb0d7c7c44680c` |
| `initramfs-repo.cpio` | 36 805 632 | `ccb3f6470a3288c4fd818f96e5bffa8ca60130995db1600e89f33f5aa26600fb` |
| `vendor-ramdisk-lz4.img` | 25 879 963 | `7563f4611b03f61234170864a92fca93b91f8dded57522cf8864f483c2f3b7f0` |
| `boot.img` (flashed) | 14 680 064 | `c29a02d8c91051305008cbc35777475edff01454cd1025bf691a4b9e1c6c24c2` |
| `vendor_boot.img` (flashed) | 26 423 296 | `df84c78cc785e542fc32fd7cd7fc8783abdb96420bf4f6968532dd6feb5bda55` |
| `google-raven-patched.img` (flashed as userdata) | 966 787 072 | `94bafb30083c40a64177480de75646c2b463679d9778c3212fb20a4714d68198` |
| `A-boot.img` / `B-boot.img` | 14 680 064 | `c29a02d8c91051305008cbc35777475edff01454cd1025bf691a4b9e1c6c24c2` |
| `A-vendor_boot.img` (stock DTB) | 26 425 344 | `4cf79af30bffc6225c424e86b01a7c2a52dcc144bcd33fa3b234f5b17dca8683` |
| `B-vendor_boot.img` (mainline DTB) | 25 954 304 | `a2cdaf95ec514ee5b9219fc4ef5d36918ff1fcdc132d53799f9729131ab87c5a` |

`A-boot.img` and `B-boot.img` are identical; the two candidates differ only
in `vendor_boot.img`.

Verification performed on the host:

* the vendor ramdisk starts with the LZ4-legacy magic `02 21 4c 18` and
  decompresses back to the exact `initramfs-repo.cpio` byte for byte;
* the kernel payload in `boot.img` starts with the same LZ4-legacy magic;
* all modules in the initramfs carry
  `vermagic=7.3.0-rc6-gs101 SMP preempt mod_unload aarch64`, matching the
  kernel release;
* `unpack_bootimg` confirms vendor boot header version 4, page size `0x800`,
  DTB size 536 176 (A) / 63 643 (B), vendor ramdisk size 25 879 963, type
  `0x1`, bootconfig size 107;
* the **flashed** `vendor_boot.img` has an **empty** bootconfig (0 bytes)
  instead of the stock 107-byte one, because `CONFIG_BOOT_CONFIG` is not set
  in this kernel: `get_boot_config_from_initrd()` then returns `NULL`, the
  bootconfig is never stripped from the initramfs, and the trailing bytes
  would make the initramfs unpacker report `invalid magic at start of
  compressed archive`. An empty bootconfig avoids that entirely; the failed
  issue-#2 baseline also used an empty bootconfig.

## Device test result

**Date:** 2026-11-24. **Device:** Pixel 6 Pro `raven`, slot `_a`, bootloader
unlocked (`vbstate=orange`, `flashlocked=0`), stock build
`google/raven/raven:17/CP3A.261005.002.A1/16269273`.

Only `boot`, `vendor_boot` and `userdata` were written. `bootloader`, `radio`,
`modem`, `efs`, `persist`, `vbmeta` and `dtbo` were **not** touched, the
bootloader was not re-locked, and AVB was not weakened.

### What was flashed

| partition | artifact | size (bytes) | sha256 |
|---|---|---|---|
| `boot` | `cand4/boot.img` | 14 680 064 | `c29a02d8c91051305008cbc35777475edff01454cd1025bf691a4b9e1c6c24c2` |
| `vendor_boot` | `cand4/vendor_boot.img` | 26 423 296 | `df84c78cc785e542fc32fd7cd7fc8783abdb96420bf4f6968532dd6feb5bda55` |
| `userdata` | `cand3/google-raven-patched.img` → sparse | 966 787 072 (raw) | `94bafb30083c40a64177480de75646c2b463679d9778c3212fb20a4714d68198` |

The `userdata` image is a GPT disk image carrying the pmOS partitions:

| partition | type | UUID | label |
|---|---|---|---|
| p1 | ext2 | `dcca49fa-fc71-498e-9f4f-09f2b80edaf1` | `pmOS_boot` |
| p2 | ext4 | `0bcaadf4-9a11-4422-9a03-e297f1e97aaf` | `pmOS_root` |

Both UUIDs match the `pmos_boot_uuid=` and `pmos_root_uuid=` values carried in
the `vendor_cmdline` and in `/chosen/bootargs`, which is what the pmOS init
uses to find them.

`userdata` was 966 787 072 bytes raw, which exceeds the device's
`max-download-size` of `0xf900000` (261 095 424 bytes). It was converted with
`img2simg` and flashed with `fastboot -S 240M`, which split the download into
two sparse parts (245 747 KB + 44 731 KB). Both parts were accepted:

```
Sending sparse 'userdata' 1/2 (245747 KB)          OKAY [  7.021s]
Writing 'userdata'                                 OKAY [  1.423s]
Sending sparse 'userdata' 2/2 (44731 KB)           OKAY [  1.294s]
Writing 'userdata'                                 OKAY [  0.238s]
```

### Build inputs

| input | value |
|---|---|
| kernel | this tree, `main`, `arch/arm64/boot/Image.lz4`, 14 672 794 B, sha256 `38e331c4…` |
| kernel release | `7.3.0-rc6-gs101` (no `+` suffix), matches the shipped modules |
| DTB | `cand4/raven-region.dtb`, 536 176 B, sha256 `d3ca24573a9df941bc52655772b2db705ee936c1e5ba3e20d1fb0d7c7c44680c` |
| vendor ramdisk | pmOS initramfs, LZ4-legacy, 25 879 963 B, sha256 `7563f461…` |
| `vendor_cmdline` | 215 B, 8 tokens, `cand4/vendor_cmdline.txt` |
| bootconfig | empty (0 bytes) — `CONFIG_BOOT_CONFIG` is not set in this kernel |
| `vendor_boot` page size | `0x800` (stock geometry) |
| initramfs modules | 770 modules, vermagic `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` |

### The DTB region: two FDTs, both mainline

The stock `vendor_boot` carries **two** back-to-back FDTs in its `dtb`
partition region, exactly 536 176 bytes in total:

| FDT | `totalsize` | root `soc_id` |
|---|---|---|
| `dtb0` | 268 095 | `0x9845000` |
| `dtb1` | 268 081 | `0x9845001` |

The live `/proc/device-tree` on the running device is `dtb1` (`soc_id`
`0x9845001`), so the bootloader walks the region by `fdt_totalsize` and selects
by the root `soc_id`.

The candidate ships a region built the same way (`/tmp/opencode/gs101/build_dtb_region.py`):
two FDTs, `268 095` and `268 081` bytes, **both** carrying
`soc_id = <0x9845001 0x00>`. Every selection rule — walk-and-match, first, last,
or "there are exactly two" — therefore resolves to the mainline DTB. The
region was verified by walking it: two FDTs, `dtc` parse clean, `stdout-path`
absent from both, `__symbols__` intact with 393 labels and 120 anchor
references per FDT, and the region ends exactly at 536 176 bytes.

### Early-boot evidence, before Linux userspace

Captured from the running device with `dmesg` (the ramoops/pstore backend is
registered but empty, because the kernel did not crash — pstore only fills on
a panic):

```
[    0.000000] Linux version 7.3.0-rc6-gs101 (gregor@vmware007) (Ubuntu clang version 21.1.8, LLD 21.1.8) #2 SMP PREEMPT Mon Nov 23 09:40:54 CET 2026
[    0.000000] KASLR enabled
[    0.000000] Machine model: Raven DVT
[    0.032243] printk: legacy console [ramoops-1] enabled
[    0.032635] pstore: Registered ramoops as persistent store backend
[    0.285714] sd 0:0:0:0: [sda] 31196160 4096-byte logical blocks: (128 GB/119 GiB)
[    0.297884]  sda: sda1 sda2 sda3 ... sda27
[    0.377690] [pmOS-rd]:   ❬❬ PMOS STAGE 1 ❭❭
[    0.377716] [pmOS-rd]:   ❬❬ PMOS STAGE 2 ❭❭
[    0.934445] [pmOS-rd]:   Setting up USB gadget through configfs
[    0.937036] [drm] Initialized simpledrm 1.0.0 for chosen:framebuffer-0 on minor 0
[    0.949753] configfs-gadget.g1 gadget.0: HOST MAC 32:xx:xx:xx:xx:75
[    1.041017] [pmOS-rd]: Trying to start server with parameters: Server IP addr: 172.16.42.1:67, client IP addr: 172.16.42.2, interface: usb0
[    2.394315] [pmOS-rd]: Mount subpartitions of /dev/sda27
```

Both acceptance-criterion-3 channels are present:

* **Display / framebuffer** — `simple-framebuffer` is initialised at 0.937 s,
  before any userspace, from the bootloader-provided `cont_splash_mem`:
  `/dev/fb0` is `simpledrmdrmfb`, 1440x3120, 32 bpp, stride 5760;
  `/dev/dri/card0` exists; `card0-Unknown-1` connector present.
* **USB gadget logs** — the gadget is configured at 0.934 s and binds the
  DWC3 UDC `11110000.usb`; the device enumerates on the host as
  `18d1:d001` with a **CDC-NCM** interface.

`Warning: unable to open an initial console.` is expected and harmless: the
bootloader appends `console=null` to the command line, so the kernel has no
serial console. The only registered console is the ramoops legacy console.

### Userspace and connectivity

The boot reaches full userspace — `systemd` is PID 1 and the pmOS rootfs is
the real root:

```
$ uname -a
Linux mb010 7.3.0-rc6-gs101 #2 SMP PREEMPT Mon Nov 23 09:40:54 CET 2026 aarch64 Linux

$ cat /proc/mounts
/dev/loop0p2 / ext4 rw,relatime 0 0
/dev/loop0p1 /boot ext2 rw,nosuid,nodev,noexec,relatime 0 0
configfs /sys/kernel/config configfs rw,nosuid,nodev,noexec,relatime 0 0
none /sys/fs/pstore pstore rw,nosuid,nodev,noexec,relatime 0 0

$ cat /proc/device-tree/soc_id | od -An -tx1
 09 84 50 01 00 00 00 00        # 0x9845001 -> the mainline DTB
$ cat /proc/device-tree/model
Raven DVT
$ ls /proc/device-tree/chosen/stdout-path
ls: ...: No such file or directory   # matches the stock geometry
```

Startup time is `2.909s` (kernel) + `2.099s` (userspace) = `5.009s`
(`systemd-analyze`).

**USB network.** The host enumerates the device as `18d1:d001` (the pmOS
gadget VID:PID) and binds `cdc_ncm`:

```
Bus 001 Device 020: ID 18d1:d001 Google Inc. Nexus 4 (fastboot)
  iInterface 5 CDC Network Control Model (NCM)
enxXXXXXXXXXXXX  UP  172.16.42.2/24      # host, NetworkManager
172.16.42.1      lladdr ba:xx:xx:xx:xx:2c  # device
```

Ping: 4/4 packets, 0% loss, ~2.8 ms.

**SSH (port 22).** Answering, and the host key was generated on the device by
`sshdgenkeys.service` on first boot:

```
ssh-ed25519  SHA256:8epfpng5UJI0nEMuM2XbOeunHgy1sLbT54uL5kCFQgY  172.16.42.1
```

Login as `user` with the pre-seeded key
(`/home/user/.ssh/authorized_keys`, `vmware007-flash`) works and gives
passwordless `sudo` (the account is in `wheel`).

**Telnet (port 23).** Also available: `telnetd` is present in the rootfs
(`/usr/sbin/telnetd`). A transient `systemd-run` instance was used to capture
an interactive shell over the USB link, then stopped again:

```
/ # echo TELNET_WORKS
TELNET_WORKS
/ # uname -a
Linux mb010 7.3.0-rc6-gs101 #2 SMP PREEMPT Mon Nov 23 09:40:54 CET 2026 aarch64 Linux
/ # id
uid=0(root) gid=0(root)
```

The listener was stopped afterwards and port 23 was confirmed closed, so no
unauthenticated shell is left behind on the device.

**Services.** `sshd` and `unudhcpd@usb0` are both `active`. The only failed
unit is `getty@tty1.service` (no `tty1` because the console is `null`);
`systemd-firstboot.service` fails on stdin and is harmless.

### Repeatability

The device was rebooted from inside the running system
(`systemctl reboot`) and came back the same way:

| time after reboot | observation |
|---|---|
| 5 s | no USB device |
| 10 s | `18d1:d001` present, SSH port 22 open |

The second boot reproduced the same initramfs trace
(`PMOS STAGE 1` / `PMOS STAGE 2` / gadget setup / `Mount subpartitions of
/dev/sda27`) and the same `simple-framebuffer` registration at 0.990 s.

### Distinguishing bytes versus the failed trio

The failed issue-#2 baseline and the candidate that boots differ in every
image that was flashed, and in the boot-critical geometry:

| artifact | failed trio | this candidate |
|---|---|---|
| `boot.img` | `bf4cbab0…` (15 683 584 B) | `c29a02d8…` (14 680 064 B) |
| `boot.img` kernel payload | `589fc786…` (15 676 151 B) | `38e331c4…` = repo `Image.lz4` (14 672 794 B) |
| `vendor_boot.img` | `6792724a…` (12 869 632 B) | `df84c78c…` (26 423 296 B) |
| `vendor_boot` page size | `0x1000` | `0x800` (stock) |
| `vendor_boot` DTB | 63 516 B, single mainline FDT, no `__symbols__` | 536 176 B, two-FDT mainline region, 393 `__symbols__` labels |
| `vendor_ramdisk00` | **ZSTD**, 12 794 920 B | **LZ4-legacy**, 25 879 963 B |
| `vendor_cmdline` | `quiet clk_ignore_unused regulator_ignore_unused pmos_boot_uuid=… pmos_root_uuid=… pmos_rootfsopts=defaults` | `loglevel=8 clk_ignore_unused regulator_ignore_unused loop.max_part=7 printk.devkmsg=on pmos_boot_uuid=… pmos_root_uuid=… pmos_rootfsopts=defaults` |
| `vendor_boot` bootconfig | 0 B | 0 B |
| `userdata` | `8afc0d6a…` (unpatched) | `94bafb30…` (pmOS rootfs patched) |

The bytes-level differences that were deliberately changed from the failed
baseline are therefore: the **kernel build** (this tree, matching module
vermagic), the **vendor ramdisk compression** (LZ4-legacy instead of ZSTD),
the **`vendor_boot` page size** (`0x800` instead of `0x1000`), the **`vendor_cmdline`**
(`quiet` replaced by `loglevel=8 printk.devkmsg=on`, plus `loop.max_part=7`),
the **DTB region** (two-FDT mainline region instead of a single mainline FDT)
and the **`userdata` rootfs**.

### The old "overlay incompatibility" hypothesis is disproved

The previous version of this document listed "DTBO overlay incompatibility" as
cause 1, on the grounds that the mainline DTB had no `__symbols__` node and
therefore could not resolve the stock overlays' fixups. On the device this
turns out to be **false** for this candidate:

* the live `/proc/device-tree` contains the overlay-created nodes —
  `max77759fg@36`, `max77729pmic@66`, `max77759tcpc@25` — **next to** the
  mainline nodes `fuel-gauge@36`, `pmic@66` and `usb-typec@25`, i.e. the
  overlay was applied on top of our DTB;
* the region DTB's `__symbols__` contains **393** labels, and the union of
  fixup labels required by all 18 stock overlays is **148** — every one of
  them resolves (`missing=NONE` for each of `ov00`…`ov17`).

The duplicate I²C nodes are a consequence of that overlay application: the
overlay's `max77759fg@36` and the mainline `fuel-gauge@36` both describe
address `0x36`, so the kernel logs `Failed to register i2c client ... (-16)`
(`EEXIST`) and only one of the two binds per address. Observed bindings:
`max77759` (PMIC at `0x66`), `maxtcpc` (Type-C at `0x25`), `max17042` (fuel
gauge), `at24` (EEPROM at `0x50`). The `max77759tcpc` overlay node is the one
that failed to bind at `0x25`; the mainline `usb-typec@25` node binds instead
and the Type-C controller enumerates.

What the evidence does **not** establish is which of the changed bytes is
*necessary*. The candidate changed several things at once (kernel build,
ramdisk compression, page size, DTB region, rootfs), so this run proves the
combination boots, not which single change was the blocker. Isolating them
would require further flashes.

### Known remaining limitations

These are real but do not block the boot:

* **Display is the bootloader framebuffer, not a mainline panel driver.**
  This tree has no `exynos_drm`/`samsung-s6e3hc3` panel support
  (`/lib/modules/.../drivers/gpu/drm/exynos/` does not exist), so
  `exynos_drm.panel_name=samsung-s6e3hc3` on the command line has no
  consumer. `fb0` works, but it shows the bootloader splash, and the panel
  timings/DSI are not driven by mainline. `panfrost` also fails
  (`GPU model not found: mali-unknown id rev 0x9202 0x10`).
* **No serial console.** The bootloader forces `console=null`, so the kernel
  has no tty output; `getty@tty1` consequently fails. Logs are available via
  `dmesg` over SSH and, after a panic, via ramoops/pstore.
* **Five I²C clients fail to register** (`-16`, duplicate address), as
  described above.
* **`fuse` refuses to load**: `module fuse: .gnu.linkonce.this_module section
  size must match the kernel's built struct module size at run time`. The
  shipped `fuse.ko` was built against a different `struct module` layout than
  the running kernel, so `fuse` is unavailable (relevant for `ntfs-3g`/
  `sshfs`, not for the boot path).
* **`/sys/fs/pstore` is empty**, which is the *correct* behaviour for a
  non-crashing boot. The ramoops backend is registered
  (`pstore: Registered ramoops as persistent store backend`), and
  `systemd-pstore` is enabled and would archive a crash log.
* **The `bootconfig` token on the command line is inert**, because
  `CONFIG_BOOT_CONFIG` is not set; the kernel warns about it
  (`WARNING: 'bootconfig' found on the kernel command line but
  CONFIG_BOOT_CONFIG is not set`).

### Evidence files

The raw captures live in the session's evidence directory (not committed, as
they contain device-specific data); the paths are listed in the handoff notes:

| file | content |
|---|---|
| `flash-cand4-20261124-101151.log` | pre-state getvars, the three flash operations, reboot, re-enumeration |
| `ssh-cand4-20261124-102644.log` | first boot: cmdline, `/proc/device-tree`, mounts, block devices |
| `ssh-cand4-pstore-20261124-102715.log` | framebuffer, configfs gadget, UDC, loaded modules, unit states |
| `ssh-cand4-root2-20261124-102813.log` | root dmesg head (early boot, t=0 …) |
| `ssh-cand4-dmesg-20261124-102847.log` | full dmesg + filtered key markers |
| `ssh-cand4-reboot2-20261124-103017.log` | second boot: pmOS stage trace, gadget, mounts |
| `ssh-cand4-display-20261124-103140.log` | DRM/framebuffer details, SSH host keys, services |
| `ssh-cand4-telnet-20261124-103253.log` | telnet session transcript |
| `ssh-cand4-final-20261124-103458.log` | final acceptance snapshot |
| `known_hosts-cand4` | device host keys (fingerprints quoted above) |

### Historical: the abandoned 2026-11-23 RAM-boot attempt (superseded)

> Historical record only — this attempt preceded the successful flash of
> 2026-11-24 described in [Device test result](#device-test-result). It is
> kept for the USB-wedge findings, not as current state.

The RAM-boot test was **not** completed. The sequence was:

1. `adb reboot bootloader` — device entered fastboot, `fastboot getvar all`
   answered normally.
2. `fastboot stage A-vendor_boot.img` — the transfer started and the
   bootloader's USB bulk endpoint stopped responding.

The failure was diagnosed at the USB level with `strace`:

```
ioctl(4, USBDEVFS_CLAIMINTERFACE, ...) = 0
ioctl(4, USBDEVFS_BULK, ...) = -1 ESHUTDOWN
```

`fastboot devices` continues to work because it only reads the USB string
descriptors over the control endpoint, while every command that needs the
bulk pipe hangs.

Host-side recovery attempts that did **not** restore the bulk pipe:
`USBDEVFS_RESET`, `USBDEVFS_RESETEP`, `USBDEVFS_CLEAR_HALT`,
`USBDEVFS_SETCONFIGURATION`, deauthorise/reauthorise, USB port power-cycle,
driver unbind/rebind, and restarting the adb server. See the table in the next
section: a port power-cycle *does* re-enumerate the device, but the bulk pipe
stays dead — which is what establishes that the fault is device-side.

**No partition was written during this attempt.** `fastboot stage` is a
RAM-only operation; `boot`, `vendor_boot`, `dtbo` and `vbmeta` still contain
the stock images, and the bootloader remains unlocked.

**Required recovery:** a restart of the bootloader on the device — physically
re-plug the USB cable, or force a hardware restart with Power + Volume Down
held for about 15 seconds. Then verify with:

```sh
fastboot getvar version      # must answer, not time out
```

Owner re-plugs on 2026-11-23 at 14:27:16 and 16:34 both restored a healthy
pipe, confirming the recovery method.

### The USB wedge (device-side, trigger not proven)

Observed facts on 2026-11-23:

* The wedge is **not** correlated with transfer size. It was reproduced with
  **no payload transfer at all**: after a fresh enumeration the bootloader
  answered exactly two `getvar` commands and then stopped servicing the bulk
  endpoints.
* The wedge is **not** fixed by any host-side action. A USB port power cycle
  re-enumerates the device with a fresh `18d1:4ee0` descriptor and a working
  control endpoint, yet the bulk endpoints stay dead. That is what places the
  fault on the device rather than in the host or in the USB link.

Observed correlation, **not** proven cause: in both observed instances the
host had issued a fastboot command whose reply was not consumed —

* `fastboot getvar all | head -12` — the pipe closed after `head` had taken
  its twelve lines, so the bootloader's reply was never read.
* A crash in the host tool between `download:<size>` and the read of its
  `OKAY`/`DATA` reply.

In both cases the bootloader was left with an unanswered command, and it did
not re-arm its fastbulk endpoints afterwards. The device stayed in that state:

| recovery attempt | result |
| --- | --- |
| `USBDEVFS_RESET` (before and after claiming the interface) | ioctl succeeds, endpoint stays dead |
| `USBDEVFS_RESETEP` on `0x02` and `0x81` | ioctl succeeds, endpoint stays dead |
| `USBDEVFS_CLEAR_HALT` on `0x02` and `0x81` | ioctl succeeds, endpoint stays dead |
| deauthorise / reauthorise the device | no re-enumeration |
| `bConfigurationValue` 0 → 1 | no re-enumeration |
| driver unbind/bind of `1-1` | no re-enumeration |
| USB port power cycle (`usb1-port1` disable → enable) | **new enumeration**, endpoint still dead |
| USB port power cycle + full `fastboot` session | endpoint still dead |
| resuming the abandoned download (first 64 KiB) | rejected — the bootloader is *not* waiting for data, its fastboot task is wedged |
| three probes over three minutes | no device-side timeout recovery |

The port power cycle shows that the fault is **device-side**: the device
re-enumerates with a fresh `18d1:4ee0` descriptor and a working control
endpoint (enumeration, `fastboot devices`, and the USB string descriptors all
still work), yet the bulk endpoints never come back. Only the *bootloader's*
fastboot task is stuck.

What is **not** established: that an unconsumed reply is the *cause*. It is
the only correlation observed so far, and the bootloader implementation is not
available for inspection. Both candidate triggers — an unconsumed reply, and
an unsupported/half-finished command sequence — would produce the same
symptom.

**Required recovery** is therefore a restart of the bootloader on the device:
a physical re-plug of the USB cable, or a hardware restart with Power +
Volume Down held for about 15 seconds. Verified working: an owner re-plug at
16:34 restored a fully healthy pipe (`getvar:version` → `OKAY` in the same
session), and `adb reboot bootloader` from Android also produces a clean
enumeration.

### The boot sequence actually used

The command sequence follows pmbootstrap's `boot_gki` action
(`pmb/config/__init__.py`), which is:

```python
"boot_gki": [
    ["fastboot", "stage", "$BOOT/vendor_boot.img"],
    ["fastboot", "boot",   "$BOOT/boot.img"],
],
```

Two properties of the AOSP implementation matter here and were verified
against the AOSP source and against the installed `fastboot` binary:

* `fastboot stage FILE` performs a **plain download** — there is no `stage`
  wire command. The wire traffic is `download:%08x`, then `DATA%08x`, then
  exactly the announced number of bytes, then `OKAY`. The AOSP source for the
  `stage` sub-command is `fb->Download(filename, buf.fd.get(), buf.sz)`.
* `fastboot boot boot.img` sends the boot image **unchanged** when it starts
  with the `ANDROID!` magic, so the image must already be a valid boot image.

Both operations are RAM-only. Nothing in this sequence writes a partition.

### Host-side tooling and its tests

The host tooling was wrong before it was used against the device, so it was
rewritten and tested **host-only** first, before any device command:

* `Documentation/gs101/tests/mock_fastboot.py` — a mock fastboot server. It implements the AOSP
  framing and refuses every partition-write command, so a test can prove that
  the client never asks for a flash.
* `Documentation/gs101/tests/fastboot_client.py` — the corrected protocol client. Commands carry
  **no trailing NUL** (the AOSP README: *"without a trailing 0 byte"*);
  `download:` must be answered with `DATA`, and the **data phase must
  complete with `OKAY`**, never `DATA`; `INFO`/`TEXT` packets are consumed
  and do not end the command; the announced size is checked against the
  requested size; a `FAIL` or a timeout is raised as a failure and is never
  reported as a successful boot; short writes are looped over.
* `Documentation/gs101/tests/test_real_fastboot.py` — drives the **real installed AOSP `fastboot`
  binary** against the mock over `-s tcp:` (the binary supports it), which
  validates the wire behaviour of the tool that is actually used.
* `Documentation/gs101/tests/test_client_protocol.py` — drives the new client against the in-memory
  transport.

Result: 32 host-only tests, all passing. The run is recorded in
`Documentation/gs101/evidence/host-protocol-tests.txt`.

Two facts were established by these tests rather than assumed:

* the installed `fastboot` opens **one** connection for a whole invocation, so
  `stage` and `boot` can be issued in a single process;
* `fastboot` queries `getvar:max-download-size` before a download, which must
  therefore be answered with an integer byte count.

**Probe hygiene (do not repeat the earlier mistakes):**

* never pipe fastboot output through `head`/`tail` — that truncates the reply;
* never crash between sending a command and reading its reply;
* never interrupt a download mid-flight;
* never read the device's serial number into a committed file.

### Evidence capture path for a failed boot

Both DTBs provide a `ramoops` region at `0xfd3ff000` (stock DTB carries the
same node natively; the mainline DTB now carries it via the change in
`arch/arm64/boot/dts/exynos/google/gs101.dtsi`), and this kernel has
`CONFIG_PSTORE_RAM=y`. A kernel can therefore record its console log into
persistent RAM before it dies, and after a subsequent reboot the log is
readable without touching any partition:

```sh
adb shell ls /sys/fs/pstore/
adb shell cat /sys/fs/pstore/console-ramoops-0
```

This was **exercised on the device on 2026-11-24**: the backend registers
(`pstore: Registered ramoops as persistent store backend`, `printk: legacy
console [ramoops-1] enabled`) and `/sys/fs/pstore` is mounted and writable,
but empty — because the boot did not fail, so nothing was written. The
readback itself was therefore not demonstrated, and it is not needed for the
successful run: the early-boot evidence there comes from `dmesg` (reachable
over SSH once the userspace is up) and from the pre-userspace kernel markers
in that log.

### State at the end of 2026-11-23 (superseded)

> Historical record. The test was carried out on 2026-11-24 — see
> [Device test result](#device-test-result).

Everything needed for the test is prepared and verified on the host:

* candidates `A-boot.img` / `A-vendor_boot.img` / `B-boot.img` /
  `B-vendor_boot.img` with hashes recorded below and re-verified;
* the repo kernel with `CONFIG_PSTORE_RAM=y`; the `ramoops` node at
  `0xfd3ff000` is present in **both** candidate DTBs;
* the initramfs carrying the 761 repo modules at the matching vermagic
  `7.3.0-rc6-gs101`, LZ4-legacy compressed like the stock ramdisk, with the
  postmarketOS stage-1 init;
* a corrected, host-tested fastboot client (see above) that runs
  `getvar` → `stage` → `boot` without the reply-truncation and
  mid-transfer-abort mistakes that preceded the earlier wedges.

### Candidate A versus the pmbootstrap package

Two candidate sets exist and they are **not** interchangeable. The
differences were verified with `unpack_bootimg` and are recorded in
`Documentation/gs101/evidence/candidate-verification.txt`:

| property | candidate A (this tree) | pmbootstrap `work-repo-kernel-issue1` |
|---|---|---|
| `boot.img` kernel | `38e331c4…` = repo `Image.lz4` | `589fc786…` (a different build) |
| `vendor_boot` page size | `0x00000800` (stock) | `0x00001000` |
| `vendor_boot` DTB | `3c7ded98…` = **stock** DTB | `4cb8a443…` = mainline DTB, no `__symbols__` |
| vendor ramdisk | LZ4-legacy, 25 879 963 B | **ZSTD**, 12 794 920 B |
| vendor ramdisk entries | 1 (type `0x1`) | 1 (type `0x1`) |
| vendor cmdline | stock | pmOS (`pmos_boot_uuid=…`) |

Two consequences for candidate A:

* the DTB is byte-identical to the stock one, so it **has** a `__symbols__`
  node with 809 entries and the stock `dtbo` overlays can be resolved
  against it — this is what the pmbootstrap package lacked. Note that
  candidate A **still failed to boot**, so a resolvable overlay is clearly
  not sufficient on its own;
* the stock `vendor_boot` has a **second** vendor ramdisk fragment,
  `vendor_ramdisk01`, type `0x3` (`dlkm`), 5 955 534 B at offset 26 110 597.
  Candidate A does not carry it, because the pmOS initramfs replaces the
  vendor ramdisk contents. The bootloader's handling of a missing `dlkm`
  fragment is not known.

The pmbootstrap package additionally contains a flashable root filesystem
(`google-raven.img`, 966 787 072 B, `8afc0d6a…`), which is what a *flashable*
Linux package needs. Candidate A is a **RAM-boot test artifact only**: it
carries the kernel and the initramfs, not the root filesystem, so it is not
by itself a flashable package. The flashing set that booted is the one
described in [Device test result](#device-test-result).

## Safety notes

* The bootloader was never re-locked and `vbmeta`/`AVB` verification was not
  weakened. The `avbtool make_vbmeta_image --flags 2` step from the previous
  session is **not** part of this candidate and is not required for it.
* **Exactly three partitions were written on 2026-11-24:** `boot`,
  `vendor_boot` and `userdata`, on the active slot `_a`.
* No writes to `bootloader`, `modem`, `radio`, `efs`, `persist`, `vbmeta`,
  `vbmeta_system`, `vbmeta_vendor`, `dtbo`, `dtbo_a`, `dtbo_b`, `super` or any
  other partition were performed. No `fastboot flashall`, `flash-all` script
  or factory-image restore was run, and no AVB key or vbmeta image was
  created.
* The `userdata` write is the only destructive one: it replaced the previous
  root filesystem image. The **source** image is preserved as
  `google-raven.img.orig-8afc0d6a` (sha256 `8afc0d6a…`) outside this
  repository, and the image that was flashed
  (`google-raven-patched.img`, sha256 `94bafb30…`) was itself built from that
  backup, so the original content is still recoverable.
* An unauthenticated `telnetd` was started briefly for evidence capture and
  **stopped again**; port 23 was verified closed afterwards. SSH remains the
  normal access path.
* The device serial number and any device-specific data are not recorded in
  this repository. The evidence files listed above are kept in the session's
  working directory and are deliberately **not** committed here.

## References

* [Issue #1](https://github.com/omnipha/linux-google-gs101/issues/1) — parent issue
* [Issue #2](https://github.com/omnipha/linux-google-gs101/issues/2) — this analysis
* `arch/arm64/boot/dts/exynos/google/gs101.dtsi` — ramoops reservation
* `arch/arm64/boot/dts/exynos/google/gs101-raven.dts` — bootargs, framebuffer,
  and the deleted `stdout-path`
* `drivers/tty/serial/samsung_tty.c` — `OF_EARLYCON_DECLARE(gs101, ...)`
* `drivers/of/fdt.c` — `early_init_dt_scan_chosen_stdout()` (bare-`earlycon`
  path) and `of_console_check()`
* `kernel/printk/printk.c` — `console_set_on_cmdline` set by `console=null`
* `scripts/setlocalversion` — source of the `+` kernel release suffix
