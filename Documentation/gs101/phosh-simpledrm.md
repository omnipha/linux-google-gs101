# Phosh on simpledrm (software rendering) — issue #5

Verified on-device 2026-11-24, Pixel 6 Pro (`raven`, gs101), rootfs
`Nura edge` (postmarketOS edge, aarch64), kernel `7.3.0-rc6-gs101 #4`.

Status: **Phosh runs and renders on the panel.** Touch input does not (a
kernel/DT defect, tracked separately — see *Touch input* below). GPU
acceleration is not used and not needed for this step.

## Smallest verified path

Software rendering all the way, no kernel change required:

| Layer | Choice | Evidence |
| --- | --- | --- |
| Display | `simpledrm` on `/dev/dri/card0` | sysfs `DRIVER=simple-framebuffer`, `card0-Unknown-1` reports `connected`, mode `1440x3120` |
| Compositor | `phoc` 0.59 (wlroots0.20 statically linked) | `WLR_BACKENDS=drm,libinput` |
| Renderer | wlroots **pixman** | `WLR_RENDERER=pixman` — EGL/GLES2 init fails (no render node), Vulkan is unavailable, pixman works |
| Output | connector `Unknown-1` | modeset with 1440x3120 @ 60 Hz succeeded |
| Shell | `phosh` 0.59 | `Phosh ready after 1.08s` |
| Seat | `seatd` 0.9 via libseat | `Seat opened with backend 'seatd'` |

The panel path is independent of the GPU: `panfrost` does not bind the Mali
id `0x9202` (no `/dev/dri/renderD128`), so phoc falls back exactly as intended.
pixman rasterises on the CPU and commits through the simpledrm KMS plane.

### Package set

```
phoc phosh seatd libinput-tools grim
```

### Reproduce

```sh
Documentation/gs101/tests/setup-phosh-simpledrm.sh
```

The script installs packages, writes the `seatd.service` unit (missing on the
postmarketOS systemd image), writes `/etc/phosh/phoc.ini`, writes the systemd
user unit and enables linger.

## Key findings

1. **Connector name is `Unknown-1`.** `/etc/phosh/phoc.ini` must address
   `[output:Unknown-1]`, otherwise phoc falls back to defaults and the scale
   is wrong for the 3120-px-tall panel.
2. **EGL cannot initialise.** phoc logs `Failed to open DRM node
   '/dev/dri/card0': Permission denied` and `Could not initialize GLES2
   renderer: no DRM FD available` — there is no render node on simpledrm, so
   the user needs the `seat` group and the pixman renderer has to be forced.
3. **`Type=notify` does not work.** phosh-session does not send
   `sd_notify(READY)`, the unit stays in `activating` and is eventually
   killed. Use `Type=simple`.
4. **`dmesg -n 1` hides probe logs.** The console loglevel must be raised to
   reproduce kernel messages (`dmesg -n 8`) — see the touch diagnosis.

## Boot / autostart

```sh
systemctl --user is-enabled phosh-session   # enabled
systemctl --user is-active  phosh-session   # active
loginctl show-user user -p Linger           # Linger=yes
```

Linger makes `user@.service` start at boot, so the Phosh unit starts without
an interactive login. **The reboot test itself is still outstanding** — it
needs an operator-controlled power cycle and a panel photo to confirm.

## Evidence

- `evidence/issue5-phosh/device-state.txt` — processes, unit state, phoc log
- `evidence/issue5-phosh/phosh-lockscreen-1926.png` — grim screenshot, 1440x3120,
  OCR of the lock screen: `19:36`, `Tuesday, November 24`, `Slide up to unlock`
- `evidence/issue5-phosh/phosh-after-synth-swipe.png` — same session after an
  injected touch swipe (hash differs; screen had blanked, swipe woke it)
- `evidence/issue5-phosh/touch-diagnosis.txt` — the touch root cause (below)

## Input

`gpio-keys` is the only input device; phoc holds `/dev/input/event0`.
No touchscreen exists, so the panel is view-only for now.

**Input proved in both directions through the compositor:**

- a synthetic uinput touchscreen (`gs101-touch`, direct/MT) was accepted by
  phoc (`event1` opened) and a swipe woke the shell;
- the lock screen does not dismiss — consistent with the missing *hardware*
  touch device, not with an input-stack problem.

USB HID mouse/keyboard would work today (the `libinput` backend is active);
it only needs a port, which the USB gadget/SSH link currently occupies.

## Touch input — kernel issue (separate)

Root cause identified, userspace exhausted:

- DT node `.../spi@10d40000/touchscreen@0`, `compatible = "sec,sec_ts"`,
  `modalias = spi:sec_ts`.
- fts driver expects `st,spi` in both `of_match_table` and `spi_device_id`
  (`drivers/input/touchscreen/fts_spi/fts.c:5151,5181`), so the normal OF
  match never happens; boot logs `SPI driver fts has no spi_device_id for st,spi`.
- Forcing `driver_override=fts` + `echo spi0.0 > .../drivers/fts/bind`
  *does* reach `really_probe`, but aborts with:

  ```
  spi spi0.0: bus: 'spi': really_probe: probing driver fts with device
  fts spi0.0: no pinctrl handle
  tee: /sys/bus/spi/drivers/fts/bind: I/O error
  ```

- Cause: the panel's `pinctrl-0`/`pinctrl-1` phandles (0x1f7–0x1ff) resolve to
  nodes under `/gs101-overlay-anchors/anchor-pinctrl_{0,5}/`, which have **no
  pinctrl controller parent**. `dt_to_map_one_config()` walks
  `of_get_next_parent()` up to the root and returns `-ENODEV`/`-EPROBE_DEFER`,
  `pinctrl_bind_pins()` fails, and the device core aborts the probe before
  `fts_probe()` runs (that is why no fts log line appears).

Neither `driver_override`, nor `driver_override` + bind, nor any package /
module / udev change can fix a device-tree parent-chain problem: the fix is a
DT change (move the pin groups under a real `pinctrl@` node, or fix the
overlay anchor resolution) or an fts driver change. Tracked as its own issue.

## Not done yet

- Reboot autostart confirmation (needs operator + panel photo).
- Owner photo of the running Phosh session.
- Touch (kernel/DT), GPU (panfrost 0x9202) — later, per issue #5.
