# Steer 9 Investigation: GPU (#11), Ghost Noise (#7), Image Checklist (#10)

## 1. GPU Live-Check (#11)
- `/dev/dri/card0` present (simpledrm, `chosen:framebuffer-0`).
- `/dev/dri/renderD128` absent.
- Running kernel #14 has `CONFIG_DRM_PANFROST=y` built into `vmlinux`.
- Dmesg during probe:
  - `panfrost 1c500000.gpu: clock rate = 24576000`
  - `panfrost 1c500000.gpu: [drm:panfrost_devfreq_init] More than 1 supply is not supported yet`
  - `panfrost 1c500000.gpu: GPU model not found: mali-unknown id rev 0x9202 0x10`
  - `panfrost 1c500000.gpu: Fatal error during GPU init`
- Attempting to build and insmod `panfrost.ko` against running kernel #14 fails:
  `ERROR: modpost: panfrost.ko: symbol 'panfrost_pm_ops' exported twice. Previous export was in vmlinux`
- Root cause: Mali-G78 (core ID `0x9202`, masked `0x9002`) is absent from `gpu_models[]` in `drivers/gpu/drm/panfrost/panfrost_gpu.c`.
- Resolution path: Add `GPU_MODEL(g78, 0x9002, GPU_REV(g78, 0, 1))` to `gpu_models[]` and rebuild `boot.img`.

## 2. Ghost/Noise Analysis (#7)
- The 1572s dataset with 287/479 multi-touch ghost frames occurred during supervisor test of mainline `s6sy761` driver (`s6sy761_core` + `s6sy761_spi` bound via `driver_override`).
- `s6sy761` lacks all hardware noise filtering and edge/grip deadzones:
  - Ghost contacts concentrated at extreme corners/edges (`norm_x=99.9%`, `norm_y=99.8%`).
- Samsung `sec_ts` driver (`sec_touch.ko`) features:
  - `SEC_TS_CMD_SET_NOISE_MODE` (0xBB / 0x33)
  - `SEC_TS_CMD_SET_GRIP_DETEC` (0xBC, value 0x1F)
  - `SEC_TS_CMD_EDGE_DEADZONE` (0xE5)
  - `SEC_TS_CMD_LONGPRESS_DROP_AREA` (10 mm curved edge deadzone on left/right)
- Restored `sec_ts` on `spi0.0` (cleared `driver_override`).
- Verified sysfs commands:
  - `echo set_noise_mode_enable,1 > /sys/class/sec/tsp/cmd` -> `OK`
  - `echo set_grip_detection_enable,1 > /sys/class/sec/tsp/cmd` -> `OK`
  - `echo dead_zone_enable,1 > /sys/class/sec/tsp/cmd` -> `OK`
  - `echo set_palm_detection_enable,1 > /sys/class/sec/tsp/cmd` -> `OK`

## 3. Image Checklist (#10)
- `systemd-modules-load.service` failure resolved:
  - Stale `uhid.ko.zst` and `hci_uart.ko.zst` had mismatched struct module sizes (Exec format error).
  - Rebuilt `uhid.ko` cleanly; installed to `/lib/modules/7.3.0-rc6-gs101/kernel/drivers/hid/uhid.ko`.
  - Removed obsolete `/etc/modules-load.d/s6sy761.conf`.
  - Disabled `hci_uart` in `/etc/modules-load.d/bluetooth.conf` pending issue #8.
  - Configured `/etc/modules-load.d/sec_touch.conf`.
  - Ran `depmod -a` and restarted `systemd-modules-load`: `status=0/SUCCESS`.
- `sec_touch=y/m` decision:
  - `sec_touch=y` hangs during early boot (cand13 failure, clocks/regulators not ready).
  - `sec_touch=m` in initramfs/vendor_boot initializes cleanly in ~4.16s across consecutive cold boots.
  - Decision: `sec_touch=m` is required.
- Structured test points:
  - Squeekboard: Verified active (PID 4165), DBus `SetVisible b true` renders OSK, screenshot verified.
  - Backlight: Simpledrm does not export `/sys/class/backlight/` (panel DSI driver needed for hardware backlight).
  - Rotation: Gyro/accel sensors absent from DT; software orientation lock toggle functional in Phosh.
  - Power Key: `gpio-keys` on `/dev/input/event0` has keycode 116 (`KEY_POWER`). `HandlePowerKey=ignore` in logind passes events to Phosh.
