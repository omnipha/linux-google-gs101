# GS101 / Pixel 6 Pro (`raven`): display and console output

This document records the work for
[issue #4](https://github.com/omnipha/linux-google-gs101/issues/4): making the
`raven` screen show Linux boot output.

**Status (2026-11-24):** the framebuffer console path is **proven on the
device**. Text written to `/dev/tty1` is rendered into `/dev/fb0` and is
visible on the physical panel (owner photo). The console can be switched to a
16x32 font at runtime, which makes the output legible on a 1440x3120 display.

What is **not** done yet: the kernel command line still carries the
bootloader's `console=null`, so `printk()` output is not routed to the
framebuffer console during boot. Only the *userspace* path (writing to
`/dev/tty1`) is proven so far. See
[Boot-time printk to the framebuffer](#boot-time-printk-to-the-framebuffer)
for the analysed, not-yet-flashed fix.

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

Two separate gaps exist in it on the current candidate:

1. **printk is not routed to the VT console.** The bootloader appends
   `console=null` to the command line, which makes the kernel register the
   `ttynull` console instead of a real one, so nothing is printed to the
   screen during boot. `/proc/consoles` on the running device lists only the
   ramoops console:

   ```
   $ cat /proc/consoles
   ramoops-1            -W- (EC  p a)
   ```

2. **The VT console is not bound to the framebuffer for printk purposes**,
   but it *is* bound as a VT: `vtcon1` is `(M) frame buffer device` with
   `bind=1`, and writing to `/dev/tty1` renders glyphs into `/dev/fb0`.

Because of (2), the userspace path works today. This was verified on the
device by writing to `/dev/tty1` and observing that the framebuffer content
changed (md5 of `/dev/fb0` changed, ~6000 non-zero bytes appeared) and that
the text was visible on the panel.

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

The fix for this is analysed in
[Boot-time printk to the framebuffer](#boot-time-printk-to-the-framebuffer).

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

With `CONFIG_FONTS=n` (the current `.config`), only the default VGA fonts are
available and `fbcon=font:TER16x32` would silently fall back to
`get_default_font()`. To use the built-in Terminus font, enable:

```
CONFIG_FONTS=y
CONFIG_FONT_TER16x32=y
```

`fbcon=font:` is parsed in `fb_console_setup()`
(`drivers/video/fbdev/core/fbcon.c`) and consumed in `fbcon_setup()` /
`fbcon_set_up_fb()`, where `find_font(fontname)` resolves the name.

### 3. Boot-time printk to the framebuffer

**This part is analysed from the kernel source but is not yet flashed and
verified on the device.** It is recorded here so the next candidate is
reproducible.

The root cause is described in
[Why `console=null` blocks printk](#why-consolenull-blocks-printk): the
bootloader's `console=null` is parsed **last**, so it is the entry that ends
up as `preferred_console`, and it does not match the VT console driver's name
`"tty"`.

The fix is to add an **earlier** `console=tty0` token. `console_setup()`
decodes `console=tty0` to name `"tty"` and index `0`, and
`try_enable_preferred_console()` compares the *name* first:

```c
if (strcmp(c->name, newcon->name) != 0)
        continue;
if (newcon->index >= 0 && newcon->index != c->index)
        continue;
if (newcon->index < 0)
        newcon->index = c->index;
```

The VT console driver has `index = -1`, so the index check is skipped and the
driver adopts index 0. The console is then enabled with `CON_ENABLED`, and
`printk()` output reaches the VT layer, then fbcon, then `/dev/fb0`.

Two properties of this fix are worth stating explicitly, because they are the
reason the fix is not simply "remove `console=null`":

* the token must appear **before** the bootloader's suffix in the final
  command line. The bootloader appends its suffix last, so the token has to
  come from `/chosen/bootargs` (DTB) or from `vendor_boot`'s `vendor_cmdline`.
* `preferred_console` will still point at the `ttynull` entry, because
  `__add_preferred_console()` sets `preferred_console` for every
  user-specified entry it adds, and `console=null` is added last. The
  consequence is that the VT console is enabled but does **not** get
  `CON_CONSDEV`. `CON_CONSDEV` marks the console that owns `/dev/console`;
  its absence means `/dev/console` will not be the VT console. That is
  acceptable here, because the framebuffer console is a *display* channel
  and the device's SSH access does not depend on `/dev/console`. It does mean
  `getty@tty1.service` may still not start on its own, which is a separate
  issue from the display.

Adding `consoleblank=0` is also advisable: `consoleblank` is a read-only
`core_param` and must therefore be on the command line, and the default
blanking timeout would otherwise blank the framebuffer console.

The candidate therefore needs these tokens, in the DTB `bootargs` **and** in
the `vendor_boot` `vendor_cmdline` (belt and braces, because whether the
bootloader strips `console=` tokens from `/chosen/bootargs` is **not
verified** — the DTS comment claims it strips `console=` and `earlycon=` from
the bootargs, while the stock live command line still shows `console=ttynull`
surviving somewhere):

```
console=tty0 fbcon=font:TER16x32 consoleblank=0
```

**This has not been flashed.** Until it is, the honest statement is that the
*userspace* framebuffer console path is proven on the device and the
*boot-time printk* path is an analysed but unverified fix.

## Evidence

The captures live in the session's evidence directory (not committed, as they
contain device-specific data).

| observation | how it was established |
|---|---|
| `/dev/fb0` is the live panel scanout | 4-band colour bars written to `/dev/fb0`; owner confirmed the bars are visible on the phone screen |
| VT -> fbcon -> `/dev/fb0` renders glyphs | text written to `/dev/tty1`; `md5sum /dev/fb0` changed and ~6000 non-zero bytes appeared; owner photo shows the text on the panel |
| 16x32 font applies at runtime | `setfont -C /dev/tty1 .../ter-p32n.psf.gz`; `stty` geometry changed from 180x195 to 90x97 |
| the indent is honoured | framebuffer dump: 10 leading spaces put the first glyph at x=162 |
| printk is *not* on the framebuffer yet | `/proc/consoles` lists only `ramoops-1`; the live command line contains `console=null` |

## Safety notes

* Nothing in this document changed a partition. The runtime font change is
  volatile (it is lost on reboot) and touches no persistent storage.
* The device's USB SSH path was used for all of the above and stayed
  functional throughout.
* No bootloader, AVB, `efs` or `persist` change is involved, and none is
  required for the console work.

## References

* [Issue #4](https://github.com/omnipha/linux-google-gs101/issues/4) — this work
* [`raven-boot-failure-analysis.md`](raven-boot-failure-analysis.md) — the boot
  candidate and its early-boot evidence
* `arch/arm64/boot/dts/exynos/google/gs101-raven.dts` — `bootargs`, framebuffer node
* `arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi` — `framebuffer0`, `cont_splash_mem`
* `kernel/printk/printk.c` — `console_setup()`, `__add_preferred_console()`,
  `try_enable_preferred_console()`, `register_console()`
* `drivers/tty/vt/vt.c` — `vt_console_driver`, `vt_console_print()`
* `drivers/video/fbdev/core/fbcon.c` — `fb_console_setup()`, `fbcon_setup()`,
  `fbcon_set_font()`
* `lib/fonts/font_ter16x32.c` — the built-in `TER16x32` font
* `drivers/gpu/drm/sysfb/simpledrm.c` — the `/dev/fb0` provider
