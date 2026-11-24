# GS101 / Pixel 6 Pro (`raven`): display and console output

This document records the work for
[issue #4](https://github.com/omnipha/linux-google-gs101/issues/4): making the
`raven` screen show Linux boot output.

**Status (2026-11-24, candidate `cand6`):** the full console chain is **proven
on the device**. Boot-time `printk()` now reaches the framebuffer console and a
working login prompt is rendered on the panel. Verified on the device after
flashing `cand6` (`boot_a` only):

* `/proc/cmdline` ends with `console=tty0`
* `/proc/consoles` lists `tty0 -WU (EC p )` (`E` = enabled, `C` = preferred)
* `dmesg` contains `printk: legacy console [tty0] enabled` at `0.000933s` and
  `Console: switching to colour frame buffer device 90x97` at `0.897913s`
* a dump of `/dev/fb0` decodes (with the kernel's own `TER16x32` font data from
  `lib/fonts/font_ter16x32.c`) to a real boot log and a login prompt:

  ```
  Welcome to Nura!
  Kernel 7.3.0-rc6-gs101 on an aarch64 (/dev/tty1)
  mb010 login:
  ```
* `getty@tty1` is `active (running)` with a busybox getty process.

The fix, how it was applied, and the **Phosh** feasibility assessment are
documented in the sections below.

## What the display hardware actually is

The kernel does **not** drive the `raven` panel. There is no `exynos_drm` /
`samsung-s6e3hc3` panel support in this tree, so the DSI link and the panel
timings are not programmed by mainline.

What *is* present is the framebuffer the **bootloader** leaves behind:

| property | value |
|----------|-------|
| node | `/chosen/framebuffer-0`, `compatible = "simple-framebuffer"` |
| backing region | `cont_splash_mem` at `0xfac00000` |
| driver | `simpledrm` (`drivers/gpu/drm/sysfb/simpledrm.c`) |
| `/dev/fb0` | `simpledrmdrmfb` |
| resolution | 1440 x 3120, 32 bpp, stride 5760 |
| DRM connector | `card0-Unknown-1`, `dpms=On`, `status=connected` |
| backlight | none (`/sys/class/backlight` is empty) |

The bootloader leaves the display scanning that region, so **anything written
to `/dev/fb0` appears on the physical screen**. That was confirmed on the
device: a 4-band colour-bar pattern (red / green / blue / white, each
780 rows) was written to `/dev/fb0` and the owner confirmed the bars were
visible on the panel.

This is a useful property and it is also the reason the display "works" today:
the kernel is a guest on the bootloader's framebuffer, not the owner of the
display pipeline.

## The console chain

The relevant chain is:

```
printk()  ->  console driver  ->  VT (tty layer)  ->  fbcon  ->  /dev/fb0  ->  panel
```

Two separate gaps existed in it before `cand6`:

1. **printk was not routed to the VT console.** The bootloader appends
   `console=null` to the command line, which makes the kernel register the
   `ttynull` console instead of a real one, so nothing was printed to the
   screen during boot. `/proc/consoles` on the running device listed only the
   ramoops console:

   ```
   $ cat /proc/consoles
   ramoops-1            -W- (EC  p a)
   ```

2. **The VT console was not bound to the framebuffer for printk purposes**,
   but it *is* bound as a VT: `vtcon1` is `(M) frame buffer device` with
   `bind=1`, and writing to `/dev/tty1` renders glyphs into `/dev/fb0`.

Because of (2), the userspace path worked first. This was verified on the
device by writing to `/dev/tty1` and observing that the framebuffer content
changed (md5 of `/dev/fb0` changed, ~6000 non-zero bytes appeared) and that
the text was visible on the panel.

Both gaps are now closed. The printk route is described in
[Boot-time printk to the framebuffer](#boot-time-printk-to-the-framebuffer);
the getty route in [A login prompt on the panel](#a-login-prompt-on-the-panel).

### Why `console=null` blocks printk

`kernel/printk/printk.c`:

* `console_setup()` maps `console=null` to
  `__add_preferred_console("ttynull", 0, ...)` and marks the console as
  user-specified.
* `try_enable_preferred_console()` matches a registering console driver
  against the command-line entries by **name** and **index**. The VT console
  driver in `drivers/tty/vt/vt.c` is registered as

  ```c
  static struct console vt_console_driver = {
  	.name		= "tty",
  	.setup		= vt_console_setup,
  	.write		= vt_console_print,
  	.device		= vt_console_device,
  	.unblank	= unblank_screen,
  	.flags		= CON_PRINTBUFFER,
  	.index		= -1,
  };
  ```

  The name `tty` never matches `ttynull`, so the VT console is never
  enabled and never receives `CON_ENABLED`.
* `of_console_check()` in `drivers/of/base.c` cannot help either, because
  `console_set_on_cmdline` is already set by the `console=` token.

### The bootloader strips every `console=` token

This is the decisive finding of the `cand5` investigation, and it invalidated
the earlier "put `console=tty0` in the DTB" plan.

`cand5` carried `console=tty0` in **both** `/chosen/bootargs` (DTB) and the
`vendor_boot` `vendor_cmdline`. Before flashing, both sources were verified
to contain it. After booting `cand5`, the live command line did **not**
contain `console=tty0` — it contained only the bootloader's injected
`console=null`:

```
$ cat /proc/cmdline | tr ' ' '\n' | grep console=
console=null
$ cat /proc/device-tree/chosen/bootargs | tr ' ' '\n' | grep console=
console=null
```

Both the live `/proc/cmdline` and the live
`/proc/device-tree/chosen/bootargs` were byte-identical (917 bytes) and
contained `fbcon=font:TER16x32` and `consoleblank=0` **twice** (once from the
DTB, once from `vendor_boot`) but **no** `console=` token from either source.
The bootloader therefore rewrites `/chosen/bootargs` and drops every
`console=` (and, per the DTS comment, `earlycon=`) token before handing over to
the kernel. `fbcon=` and `consoleblank=` are not filtered.

Consequences:

* anything the DTB or `vendor_boot` puts in `console=` is discarded;
* the *only* surviving `console=` token is the bootloader's own
  `console=null`;
* a kernel-side fix is required — the command line has to be completed
  **after** the bootloader has filtered it.

## Font selection

The framebuffer is 1440x3120. The default VGA 8x16 font gives
`1440/8 = 180` columns and `3120/16 = 195` rows, which is legible only when
viewed closely — on a phone-sized display in a hand it is too small.

The device rootfs ships the Terminus console font set in
`/usr/share/consolefonts/` (448 files), including PSF2 fonts up to 16x32.
Switching the running console to the 16x32 font:

```
$ setfont -C /dev/tty1 /usr/share/consolefonts/ter-p32n.psf.gz
```

changes the console geometry as follows:

| font | columns | rows | `stty` reports |
|------|---------|------|----------------|
| VGA 8x16 (default) | 180 | 195 | `rows 195; columns 180` |
| Terminus 16x32 (`ter-p32n`) | 90 | 97 | `rows 97; columns 90` |

The font is confirmed in the kernel's own font cache afterwards
(`setfont -o` returns a 16 416-byte PSF2 dump with a 16x32 glyph cell).

### Left margin

At 16x32 the glyph cell is 16 px wide, so the first column starts at x=0 and
the leftmost glyph column sits flush against the panel edge. In the owner's
photo the first word of the first line was visibly cropped. The fix is to
indent the output, not to change the font: 8 leading spaces put the first
glyph at x=130, and 10 spaces at x=162 (measured from the framebuffer dump).
A general-purpose helper that keeps the text inside the visible area is:

```sh
printf '\033[2J\033[H' > /dev/tty1     # clear, home
{
    printf '        GS101 FB CONSOLE TEST\n'
    printf '        ====================\n'
    printf '        Large font 16x32 test\n'
    printf '        ABCDEFGHIJKLMNOPQRSTUVWXYZ\n'
    printf '        abcdefghijklmnopqrstuvwxyz\n'
    printf '        0123456789\n'
    printf '        The quick brown fox jumps\n'
    printf '        over the lazy dog.\n'
    printf '        !@#$%%^&*()_+-=[]{};:,.<>?/\n'
    printf '\n'
} > /dev/tty1
```

Note the `%%` in the `printf` format string: a literal `%` has to be escaped
in the shell's `printf`.

## Reproducible setup

Two independent mechanisms give a readable framebuffer console. Both are
recorded here so the setup can be reproduced without a device.

### 1. Userspace, at runtime (no rebuild)

This is what was verified on the device:

```sh
# 1. switch the console to the 16x32 font
setfont -C /dev/tty1 /usr/share/consolefonts/ter-p32n.psf.gz

# 2. write indented text to the console
printf '\033[2J\033[H' > /dev/tty1
printf '        GS101 FB CONSOLE TEST\n' > /dev/tty1
```

This requires `CONFIG_FONT_SUPPORT` and write access to `/dev/tty1`
(`video` group, or `root`). It does **not** require the printk route to work.

### 2. Kernel, at boot time

For the console to be populated by `printk()` during boot, the kernel needs

* `CONFIG_VT=y`, `CONFIG_VT_CONSOLE=y` (already set),
* `CONFIG_FRAMEBUFFER_CONSOLE=y` (already set),
* `CONFIG_FONT_SUPPORT=y` (already set), and
* a `console=` token that selects the VT console, and
* an `fbcon=font:` option to pick the font.

The kernel's built-in 16x32 font is named `TER16x32`
(`lib/fonts/font_ter16x32.c`, `CONFIG_FONT_TER16x32`). The built-in fonts are
selected by name with `fbcon=font:<name>`:

```
fbcon=font:TER16x32
```

With the stock upstream default `CONFIG_FONTS=n`, only the default VGA fonts
are available and `fbcon=font:TER16x32` would silently fall back to
`get_default_font()`. The current `.config` enables the built-in Terminus
font:

```
CONFIG_FONTS=y
CONFIG_FONT_TER16x32=y
```

`fbcon=font:` is parsed in `fb_console_setup()`
(`drivers/video/fbdev/core/fbcon.c`) and consumed in `fbcon_setup()` /
`fbcon_set_up_fb()`, where `find_font(fontname)` resolves the name.

### 3. Boot-time printk to the framebuffer

**This is implemented, flashed and verified on the device (`cand6`).**

Because the bootloader filters every `console=` token out of both the DTB and
the `vendor_boot` command line, the token has to be added *by the kernel*,
after the bootloader is done. The kernel already supports exactly this:
`CONFIG_CMDLINE_EXTEND` appends a built-in command line to the bootloader's.

`drivers/of/fdt.c`, `early_init_dt_scan_chosen()`:

```c
#if defined(CONFIG_CMDLINE_EXTEND)
		if (scnprintf(cmdline, sizeof(cmdline), "%s ", cmdline) < 0)
			return -ENOMEM;
		strlcat(cmdline, CONFIG_CMDLINE, sizeof(cmdline));
#endif
```

The configuration used:

```
CONFIG_CMDLINE="console=tty0"
CONFIG_CMDLINE_EXTEND=y
# CONFIG_CMDLINE_FROM_BOOTLOADER is not set
# CONFIG_CMDLINE_FORCE is not set
```

`arch/arm64/Kconfig` gained a `config CMDLINE_EXTEND` entry in the "Kernel
command line type" choice block, so the option is selectable on arm64 (the
`cmdline_early_init()` helpers in `drivers/of/fdt.c` and the EFI stub in
`drivers/firmware/efi/libstub/efi-stub.c:139` already honoured it).

#### Why appending works, despite `console=null`

The order of the entries in the final command line matters:

```
... bootconfig console=null console=tty0
```

`console_setup()` is called for each `console=` token in turn and each call
appends to the preferred-console list:

1. `console=null` → `__add_preferred_console("ttynull", 0, …)` →
   `preferred_console` = *ttynull* entry.
2. `console=tty0` → `__add_preferred_console("tty", 0, …)` → `preferred_console`
   = *tty* entry.

The bootloader's `console=null` is still the **first** entry in the list, but
it is no longer the *preferred* one. When the VT console driver registers in
`con_init()` (`drivers/tty/vt/vt.c:3909`), `try_enable_preferred_console()`
compares the driver name `"tty"` against the entries: the `"tty"` entry
matches, so the VT console is enabled with `CON_ENABLED` and becomes the
head of `console_list`. The `ttynull` entry never matches any driver, and
`ramoops` registers later without `CON_CONSDEV`, so it lands behind the VT
console.

The result on the device:

```
$ cat /proc/consoles
tty0                 -WU (EC  p  )    4:1
ramoops-1            -W- (E   p a)
```

`E` = enabled, `C` = preferred console, `W` = the VT console is the one that
owns `/dev/console`.

#### Consequences for `/dev/console` and getty

Because `console=tty0` is *appended* rather than prepended, the resulting
command line still contains `console=null` first. That is harmless: the
`console=null` entry simply never matches a driver. `/dev/console` is owned
by the VT console (`CON_CONSDEV`), so `getty@tty1` starts normally.

`consoleblank=0` was added for a different reason: `consoleblank` is a
read-only `core_param` and must be on the command line, otherwise the default
blanking timeout blanks the framebuffer console.

#### What was flashed

Only `boot_a` was flashed for `cand6`. The fix is entirely in the kernel, so
`vendor_boot` (DTB + `vendor_cmdline`) is unchanged and was reused
byte-identically from `cand5` — which avoids a second writer on the same
partition.

| item | value |
|---|---|
| kernel `Image.lz4` | sha256 `0379c6ee57a8290322d472dc808c5f352b3fe690412cf736300b66cb3118de3a` |
| `cand6/boot.img` | sha256 `c2029af4dea0c30ba2d881d8535764d3404e4507c91d01e29a9cc014372bd069` |
| `cand5/vendor_boot.img` (reused) | sha256 `97424a4dbad07269eabdca206cda885738e30c78f8f76cb3ec25cf5155465c55` |
| boot image recipe | `mkbootimg --header_version 4 --kernel kernel.lz4 --ramdisk empty-ramdisk --cmdline ''` |

`unpack_bootimg` confirms the repacked image: header version 4, empty
command line, and the kernel payload hashes to the `Image.lz4` above. The
release string stays `7.3.0-rc6-gs101` (`LOCALVERSION=`), which matches the
vermagic of the modules shipped in `/lib/modules`.

## A login prompt on the panel

`printk` output is only half of a usable console; a login prompt needs a
getty on the VT.

The device image has **no** `agetty` binary (`/usr/sbin/agetty` does not
exist), so the upstream `getty@.service` unit fails:

```
ExecStart=-/usr/sbin/agetty --noreset --noclear - ${TERM}
```

What the device *does* have is the busybox `getty` applet
(`/sbin/getty -> /bin/busybox`) and a real `/bin/login`. The unit was
overridden with a systemd drop-in rather than by editing the packaged unit:

```ini
# /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/getty 0 %I ${TERM}
```

The leading `-` keeps the unit from failing if busybox getty exits
non-zero. After `systemctl daemon-reload` and `systemctl restart
getty@tty1`:

```
$ systemctl is-active getty@tty1
active
$ systemctl status getty@tty1
● getty@tty1.service - Getty on tty1
     Drop-In: /etc/systemd/system/getty@tty1.service.d
             └─override.conf
     Active: active (running) since ...
```

The process is `/sbin/getty 0 tty1 linux`, and `/sys/class/tty/tty0/active`
reports `tty1`.

Security note: the drop-in only changes *which* getty binary is used. The
root password stays locked (`root:!` in `/etc/shadow`), so the console prompt
cannot be used to log in as root without a password, and no
unauthenticated root login was configured. The `user` account keeps its
`$6$` (SHA-512) hash.

## Phosh feasibility

Assessed on the running device (post-`cand6`). The conclusion is that Phosh
is **not** reachable with the current kernel and userland, and the reason is
not packaging.

### What is present

| item | status |
|---|---|
| rootfs | 266 Alpine packages, `/` on `loop0p2` (ext4), **102.2 G free** after the resize |
| dbus | `dbus`, `dbus-broker`, `dbus-broker-systemd`, `dbus-systemd` installed |
| glib | `glib-2.90.1` installed |
| libinput | `libinput-libs`, `libinput-udev` installed |
| display | `/dev/fb0` (`simpledrmdrmfb`), 1440x3120, **writing to it changes the panel** |
| DRM | `/dev/dri/card0` only — **no render node** (`/dev/dri/renderD128` absent) |
| GPU | `panfrost 1c500000.gpu`: `GPU model not found: mali-unknown id rev 0x9202 0x10` → `Fatal error during GPU init` |
| input | `/dev/input/event0` only, from `gpio-keys`; **no touchscreen** |
| power | `max170xx_battery`, `max77759-charger` present |
| wayland/mesa/phosh | **none** of mesa, wayland, weston, phosh, phoc, sway, wlroots, GTK, NetworkManager, feedbackd |

### The blocking gap: there is no GPU

`panfrost` is the only GPU driver in this tree, and it does not know the
GS101's Mali. In `drivers/gpu/drm/panfrost/panfrost_gpu.c` the supported
models are enumerated in `gpu_models[]`:

```c
GPU_MODEL(t600, 0x600, …)   … GPU_MODEL(t880, 0x880, …)
GPU_MODEL(g71,  0x6000, …)  … GPU_MODEL(g57,  0x9001, …)
GPU_MODEL(g57,  0x9003, …)  GPU_MODEL(g57, 0x9093, …)
```

There is no entry for the GS101's GPU (`id rev 0x9202 0x10`, i.e. a Mali-G78
class part). `panfrost_gpu_init_features()` therefore fails with
`-ENODEV` and the driver aborts with `Fatal error during GPU init`. The
consequence is concrete: **no `/dev/dri/renderD128`, hence no EGL/GLES and no
hardware-accelerated Wayland compositor.**

The kernel source does contain a `arm,mali-valhall-jm` compatible
(`drivers/gpu/drm/panfrost/panfrost_drv.c:1183`), but Valhall (Mali-G77/G78)
support in this tree is not complete enough to initialise the GS101 part —
the model table lookup happens before any Valhall-specific code path is
reached.

Two independent hard blockers therefore exist for a *usable* Phosh:

1. **no GPU acceleration** — mesa's Panfrost (`libgallium` / `panfrost_dri.so`)
   and therefore phoc/phosh's GL rendering have no hardware to run on. A
   software rasteriser (`llvmpipe`/`swrast`) would need mesa built with
   `gallium-softpipe`/`llvmpipe` for aarch64, which Alpine does not ship for
   this platform in a usable form, and it would be unusably slow for a
   full-screen phone UI at 1440x3120.
2. **no touch input** — the only input device is `gpio-keys`
   (`/proc/bus/input/devices`: `N: Name="gpio-keys"`). The GS101's touch
   controller driver (`CONFIG_TOUCHSCREEN_S6SY761`, `CONFIG_TOUCHSCREEN_STMFTS`)
   is compiled in but does not probe: no `s6sy761`/`fts` touch device appears
   in `/proc/bus/input/devices`, and `/dev/input/` contains only `event0`
   (the gpio-keys). Phosh without a touchscreen is a mouse-less desktop UI;
   even the login screen would be unusable.

A third, softer gap: the kernel does not program the panel at all. The
display is the **bootloader's** framebuffer (`simple-framebuffer` on
`cont_splash_mem`), driven by `simpledrm`. There is no `exynos_drm`/DPU/DSIM
support for this SoC in this tree, so:

* the panel's native refresh/timings are not owned by the kernel;
* `simpledrm` gives a plain framebuffer with no KMS plane management, no
  vblank, and no hardware cursor;
* there is no backlight control (`/sys/class/backlight` is empty), so
  brightness/screen-timeout handling in a mobile shell is not available.

### What would be needed, in order

1. **GPU**: either port enough of Valhall/Mali-G78 support to `panfrost` so
   that the GS101 GPU initialises and exposes `/dev/dri/renderD128`, or write
   a new kernel driver for this GPU. This is the long pole and it is
   upstream-kernel work, not configuration.
2. **Touch**: get the GS101 touch controller to probe as an input device
   (the `s6sy761`/`stmfts` drivers need the correct bus, reset sequence and
   interrupt configuration for this board), so that a `/dev/input/event*`
   touchscreen node exists.
3. **Userland**: mesa (Panfrost or llvmpipe) + wayland + weston or phoc +
   phosh + its dependencies, packaged for the device's Alpine userland. The
   device has 102.2 G free, so **space is not the constraint**; the
   constraint is that the packages must be fetchable (the device currently has
   **no working DNS**: `/etc/resolv.conf` points at `127.0.0.53`, and
   `apk update` fails with `DNS: transient error`, while the host can reach
   `dl-cdn.alpinelinux.org` — so packages would have to be staged on the host
   and sideloaded).

Because items 1 and 2 are kernel-driver work and the current kernel only
reaches the panel through the bootloader's framebuffer, the honest statement
is: **the device currently boots into a working text console with a login
prompt on screen; it does not boot into Phosh, and the missing pieces are a
working GPU driver and a working touch driver, not packages.**

## Evidence

The captures live in the session's evidence directory (not committed, as they
contain device-specific data).

| observation | how it was established |
|---|---|
| `/dev/fb0` is the live panel scanout | 4-band colour bars written to `/dev/fb0`; owner confirmed the bars are visible on the phone screen |
| VT -> fbcon -> `/dev/fb0` renders glyphs | text written to `/dev/tty1`; `md5sum /dev/fb0` changed and ~6000 non-zero bytes appeared; owner photo shows the text on the panel |
| 16x32 font applies at runtime | `setfont -C /dev/tty1 .../ter-p32n.psf.gz`; `stty` geometry changed from 180x195 to 90x97 |
| the indent is honoured | framebuffer dump: 10 leading spaces put the first glyph at x=162 |
| the bootloader strips every `console=` token | `cand5` shipped `console=tty0` in both `/chosen/bootargs` and `vendor_boot vendor_cmdline`; live `/proc/cmdline` and live `/proc/device-tree/chosen/bootargs` were byte-identical (917 B) and contained `console=null` only, while `fbcon=font:TER16x32` and `consoleblank=0` survived twice |
| `console=tty0` is reached by the kernel's own command line | `CONFIG_CMDLINE_EXTEND=y` appends `CONFIG_CMDLINE`; live `/proc/cmdline` ends with `console=tty0` |
| the VT console is the preferred console | `/proc/consoles` shows `tty0 -WU (EC  p  )`; `dmesg` shows `printk: legacy console [tty0] enabled` at `0.000933s` and `Console: switching to colour frame buffer device 90x97` at `0.897913s` |
| boot output is really on the panel | a `/dev/fb0` dump decoded with the kernel's `TER16x32` font data gives the boot log and `mb010 login:` |
| a getty prompt is on the console | `systemctl is-active getty@tty1` → `active`, process `/sbin/getty 0 tty1 linux` (busybox), `/sys/class/tty/tty0/active` → `tty1` |
| there is no GPU | `dmesg`: `GPU model not found: mali-unknown id rev 0x9202 0x10` / `Fatal error during GPU init`; `/dev/dri/` has `card0` only, no `renderD128` |
| there is no touch input | `/proc/bus/input/devices` lists only `gpio-keys`; `/dev/input/` holds only `event0` |
| the device has no network for package installs | `apk update` fails with `DNS: transient error`; the stub resolver at `127.0.0.53` has no reachable upstream, while the host reaches `dl-cdn.alpinelinux.org` fine |

## Safety notes

* Only `boot_a` was written, and only for `cand6`. `vendor_boot` was reused
  byte-identically from `cand5`, so no partition received two writers.
* The device's USB SSH path was used throughout and stayed functional; it
  was the only way in after the reboot.
* The getty change is a systemd drop-in in the rootfs; the root password stays
  locked and no unauthenticated root login was configured.
* The rootfs `/` filesystem was resized earlier in the session (402.8 M to
  106.9 G) to make room for packages. It is a resize of the existing ext4
  filesystem, not a new filesystem, and the data survived reboots.
* No bootloader, AVB, `efs` or `persist` change is involved, and none is
  required for the console work.

## References

* [Issue #4](https://github.com/omnipha/linux-google-gs101/issues/4) — this work
* [`raven-boot-failure-analysis.md`](raven-boot-failure-analysis.md) — the boot
  candidate and its early-boot evidence
* `arch/arm64/boot/dts/exynos/google/gs101-raven.dts` — `bootargs`, framebuffer node
* `arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi` — `framebuffer0`, `cont_splash_mem`
* `arch/arm64/Kconfig` — `CMDLINE_EXTEND` for arm64
* `drivers/of/fdt.c` — `early_init_dt_scan_chosen()`, the `CONFIG_CMDLINE_EXTEND` append
* `kernel/printk/printk.c` — `console_setup()`, `__add_preferred_console()`,
  `try_enable_preferred_console()`, `register_console()`
* `drivers/tty/vt/vt.c` — `vt_console_driver`, `vt_console_print()`
* `drivers/video/fbdev/core/fbcon.c` — `fb_console_setup()`, `fbcon_setup()`,
  `fbcon_set_font()`
* `lib/fonts/font_ter16x32.c` — the built-in `TER16x32` font
* `drivers/gpu/drm/sysfb/simpledrm.c` — the `/dev/fb0` provider
* `drivers/gpu/drm/panfrost/panfrost_gpu.c` — `gpu_models[]`, the missing GS101 GPU entry
