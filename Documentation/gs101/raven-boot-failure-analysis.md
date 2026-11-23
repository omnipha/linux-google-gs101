# GS101 / Pixel 6 Pro (`raven`): fastboot boot-failure analysis

This document records the analysis of the `raven` boot failure described in
[issue #2](https://github.com/omnipha/linux-google-gs101/issues/2) (parent:
[#1](https://github.com/omnipha/linux-google-gs101/issues/1)).

It covers the reproduction of the failure from host-side evidence, the
identified root cause, the diagnostics added to this tree, and the reproducible
build and hash records for the next boot candidate.

**Status of the device test:** the analysis and the candidate build are
complete and verified on the host. The RAM-boot test itself has **not** been
executed, because the device's USB bulk endpoint became unusable during the
attempt and requires a physical re-plug to recover. See
[Device test status](#device-test-status).

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

Two independent defects were found in the failed candidate. Both are
reproducible from the artifacts alone, without a device.

### 1. DTBO overlay incompatibility (candidate cause 1)

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

With the mainline DTB both channels work: `stdout-path` points at
`serial_0`, whose compatible is `google,gs101-uart`, matching the `gs101`
earlycon entry, and the driver binds and registers the console under the name
`ttySAC` (`S3C24XX_SERIAL_NAME`). This matches the stock bootargs, which use
`console=ttySAC0,115200n8`.

Framebuffer output is available as a second channel: `gs101-raven.dts` enables
`framebuffer-0` as a `simple-framebuffer` at 1440x3120 over `cont_splash_mem`,
and the kernel is configured with `CONFIG_FRAMEBUFFER_CONSOLE=y` and
`CONFIG_DRM_SIMPLEDRM=y`.

### How to capture the early log

1. Boot with the candidate (`fastboot stage` + `fastboot boot`, see below).
2. On the next boot, the previous run's log is in the pstore filesystem.
3. Read it from a working userspace:
   ```
   adb shell ls /sys/fs/pstore/
   adb shell cat /sys/fs/pstore/console-ramoops-0
   ```
   The ramoops region is persistent across reboots but not across a full
   power loss, so the log must be collected after the failing boot.

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

```
earlycon=<gs101|exynos4210>,mmio32,0x10A00000 console=ttySAC0,115200n8 \
loglevel=8 clk_ignore_unused regulator_ignore_unused root=/dev/ram0 \
androidboot.boot_devices=14700000.ufs androidboot.hardware.platform=gs101 \
androidboot.wait_for_udc=true
```

`quiet` is deliberately absent so that early output is not suppressed, and
`loglevel=8` raises the console log level.

### Artifact hashes

| artifact | size (bytes) | sha256 |
|----------|---------------|--------|
| `Image` | 29 684 224 | `c8ba068448af2e9ac858c48fb66761ac052c201ba0118afb8f19bf3c4afe8a4a` |
| `Image.lz4` | 14 672 794 | `38e331c480b20772b4a3bd772285cb04e6598dec06e6c3d4fc7197e62973a561` |
| `gs101-raven.dtb` | 63 643 | `ab2081499148a2c69b869e9a57a54ce16b6e2fc9bd3138785bc88ed828b7c59e` |
| `initramfs-repo.cpio` | 36 805 632 | `ccb3f6470a3288c4fd818f96e5bffa8ca60130995db1600e89f33f5aa26600fb` |
| `vendor-ramdisk-lz4.img` | 25 879 963 | `7563f4611b03f61234170864a92fca93b91f8dded57522cf8864f483c2f3b7f0` |
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
  `0x1`, bootconfig size 107.

## Device test status

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
`CONFIG_PSTORE_RAM=y`. A RAM-booted kernel can therefore record its console
log into persistent RAM before it dies, and after a subsequent warm reboot
into the stock Android slot the log is intended to be readable without
touching any partition:

```sh
adb shell ls /sys/fs/pstore/
adb shell cat /sys/fs/pstore/console-ramoops-0
```

This is the intended early-boot evidence channel for acceptance criterion 3.
It is **not yet demonstrated**: the readback has never been exercised on this
device, the stock Android build may expose `/sys/fs/pstore` with different
permissions (on the stock Android 17 build it was observed as
`Permission denied` for the `adb shell` user), and the region does not
survive a full power loss. If the readback is not available, the fallback
evidence is the device's behaviour itself — whether it stays in fastboot,
reboots, or enumerates a new USB device — together with the reproducible
build and hash records in this document.

### State at the end of 2026-11-23

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
  against it — this is what candidate B and the pmbootstrap package lack;
* the stock `vendor_boot` has a **second** vendor ramdisk fragment,
  `vendor_ramdisk01`, type `0x3` (`dlkm`), 5 955 534 B at offset 26 110 597.
  Candidate A does not carry it, because the pmOS initramfs replaces the
  vendor ramdisk contents. The bootloader's handling of a missing `dlkm`
  fragment is not known.

The pmbootstrap package additionally contains a flashable root filesystem
(`google-raven.img`, 966 787 072 B, `8afc0d6a…`), which is what a *flashable*
Linux package needs. Candidate A is a **RAM-boot test artifact only**: it
carries the kernel and the initramfs, not the root filesystem, so it is not
by itself a flashable package.

## Safety notes

* The bootloader was never re-locked and `vbmeta`/`AVB` verification was not
  weakened. The `avbtool make_vbmeta_image --flags 2` step from the previous
  session is **not** part of this candidate and is not required for it.
* No writes to `bootloader`, `modem`, `radio`, `efs`, `persist` or any other
  partition were performed.
* The device serial number and any device-specific data are not recorded in
  this repository.

## References

* [Issue #1](https://github.com/omnipha/linux-google-gs101/issues/1) — parent issue
* [Issue #2](https://github.com/omnipha/linux-google-gs101/issues/2) — this analysis
* `arch/arm64/boot/dts/exynos/google/gs101.dtsi` — ramoops reservation
* `drivers/tty/serial/samsung_tty.c` — `OF_EARLYCON_DECLARE(gs101, ...)`
* `scripts/setlocalversion` — source of the `+` kernel release suffix
