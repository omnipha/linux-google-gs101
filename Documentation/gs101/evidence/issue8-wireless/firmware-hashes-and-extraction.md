# GS101 Wireless Firmware Audit & Extraction Evidence (Issue #8)

**Date**: 2026-11-25  
**Target Hardware**: Google Pixel 6 Pro (`raven`, GS101 SoC)  
**Host Extraction Path**: `/home/gregor/.local/share/gs101-stock-fw/` (Permissions `0700` dir / `0600` files)  
**Target Deployment Path**: `/lib/firmware/` (on device `172.16.42.1`)  

---

## 1. Proprietary Blob Compliance & Policy

Per repository safety rules:
- **No binary firmware blobs are committed to the git repository**.
- All blobs are extracted read-only from the device's original partitions or reference stock image and deployed exclusively to `/lib/firmware/` in the device root filesystem and local host storage.
- Firmware hashes and provenance are fully documented below for bit-for-bit reproducibility.

---

## 2. Extraction Methodology

Firmware files were extracted directly from the Android `super` partition using linear logical partition extents dumped via `lpdump`:

- **Block Device**: `/dev/disk/by-partlabel/super` (on-device `/dev/sda27`)
- **`vendor_a` Logical Partition Extents**:
  - Start 512-byte sector: `11462656` (`0x57700000`)
  - End 512-byte sector: `12735552`
  - Sector count: `1272896` sectors (651,722,752 bytes = 621.5 MiB)
  - Filesystem: `ext4`
- **`vendor_dlkm_a` Logical Partition Extents**:
  - Start 512-byte sector: `12736512`
  - End 512-byte sector: `12845600`
  - Sector count: `109088` sectors (55,853,056 bytes = 53.25 MiB)
  - Filesystem: `ext4`

### Extraction Command Sequence
```bash
# Set up read-only loop device with partition offset and limit
sudo losetup -r -f --offset $((11462656 * 512)) --sizelimit $(((12735552 - 11462656) * 512)) /dev/disk/by-partlabel/super

# Mount read-only without replay (noload)
sudo mkdir -p /mnt/stock-vendor
sudo mount -o ro,noload /dev/loopX /mnt/stock-vendor

# Copy firmware files to host archive and target rootfs
# /mnt/stock-vendor/firmware/wlan/bcmdhd.cal -> /lib/firmware/bcmdhd.cal
# /mnt/stock-vendor/firmware/wlan/bcmdhd.cal_ROW -> /lib/firmware/bcmdhd.cal_ROW
# /mnt/stock-vendor/firmware/wlan/bcmdhd_clm.blob -> /lib/firmware/bcmdhd_clm.blob
# /mnt/stock-vendor/firmware/wlan/bcmdhd_clm.blob_ROW -> /lib/firmware/bcmdhd_clm.blob_ROW
# /mnt/stock-vendor/firmware/wlan/fw_bcmdhd.bin -> /lib/firmware/fw_bcmdhd.bin
# /mnt/stock-vendor/firmware/brcm/BCM.hcd -> /lib/firmware/brcm/BCM.hcd
# /mnt/stock-vendor/firmware/brcm/BTFW_B.hcd -> /lib/firmware/brcm/BTFW_B.hcd
# /mnt/stock-vendor/firmware/brcm/BTFW_D.hcd -> /lib/firmware/brcm/BTFW_D.hcd

# Unmount cleanly
sudo umount /mnt/stock-vendor
sudo losetup -d /dev/loopX
```

---

## 3. Cryptographic Hashes (SHA-256)

All files deployed to the target device `/lib/firmware/` and host storage match the following verified SHA-256 checksums:

| File Name | Size (Bytes) | SHA-256 Checksum | Description / Chip |
| :--- | :--- | :--- | :--- |
| `bcmdhd.cal` | 24,530 | `a16987752c7de8b026d18c1348f350a48ec062e2570c44d6c778847fab8cc801` | BCM4389 Wi-Fi NVRAM calibration table |
| `bcmdhd.cal_ROW` | 24,497 | `e2950a43669d5e8654d49e891bf69753b986fe01dfde4bf818d50c8a224ad0ad` | BCM4389 Wi-Fi Rest-of-World calibration |
| `bcmdhd_clm.blob` | 16,260 | `5ae4086e69f310f7a67df3a1e8e3537f229205c1ce2d7ad520e4217b04044d64` | BCM4389 Country Locale Matrix (CLM) blob |
| `bcmdhd_clm.blob_ROW` | 16,260 | `5ae4086e69f310f7a67df3a1e8e3537f229205c1ce2d7ad520e4217b04044d64` | BCM4389 CLM blob (ROW variant) |
| `fw_bcmdhd.bin` | 1,764,018 | `3a6dbf5a726304f83e154ff1b265a06c77d669506eb5c784fd864f10bdda6533` | BCM4389 Wi-Fi 6E operational microcode |
| `brcm/BCM.hcd` | 474,858 | `33124cc86e78563c3c730c76f1630ec2790be63cadc441bcda352c44b07c223c` | BCM4389 Bluetooth RAM patch file |
| `brcm/BTFW_B.hcd` | 474,047 | `429e254d0c139f7e3ed8b04fc369d8b3bfcd1aaf2c31c389359c6ddbe21a5d62` | BCM4389 Bluetooth RAM patch (Rev B) |
| `brcm/BTFW_D.hcd` | 474,861 | `7d029d2fd3f7a8dbc70f5623eb7fa896f3beee48c9247c3f98231a36d8a6210b` | BCM4389 Bluetooth RAM patch (Rev D) |

---

## 4. On-Device Verification

Measured on `raven` (`172.16.42.1`) on 2026-11-25:
```
# sha256sum /lib/firmware/bcmdhd* /lib/firmware/fw_bcmdhd.bin /lib/firmware/brcm/*
a16987752c7de8b026d18c1348f350a48ec062e2570c44d6c778847fab8cc801  /lib/firmware/bcmdhd.cal
e2950a43669d5e8654d49e891bf69753b986fe01dfde4bf818d50c8a224ad0ad  /lib/firmware/bcmdhd.cal_ROW
5ae4086e69f310f7a67df3a1e8e3537f229205c1ce2d7ad520e4217b04044d64  /lib/firmware/bcmdhd_clm.blob
5ae4086e69f310f7a67df3a1e8e3537f229205c1ce2d7ad520e4217b04044d64  /lib/firmware/bcmdhd_clm.blob_ROW
3a6dbf5a726304f83e154ff1b265a06c77d669506eb5c784fd864f10bdda6533  /lib/firmware/fw_bcmdhd.bin
33124cc86e78563c3c730c76f1630ec2790be63cadc441bcda352c44b07c223c  /lib/firmware/brcm/BCM.hcd
429e254d0c139f7e3ed8b04fc369d8b3bfcd1aaf2c31c389359c6ddbe21a5d62  /lib/firmware/brcm/BTFW_B.hcd
7d029d2fd3f7a8dbc70f5623eb7fa896f3beee48c9247c3f98231a36d8a6210b  /lib/firmware/brcm/BTFW_D.hcd
```
All firmware blobs are verified on the target filesystem ready for runtime loading by the wireless and Bluetooth subsystems.
