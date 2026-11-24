# SPDX-License-Identifier: GPL-2.0

dtb-$(CONFIG_ARCH_EXYNOS) += \
	gs101-oriole.dtb \
	gs101-raven.dtb \
	gs101-bluejay.dtb

# The stock bootloader applies a vendor dtbo overlay on top of the base
# device tree from vendor_boot.  That requires the base blob to carry a
# "/__symbols__" node, which is only emitted by dtc's "-@" option.
# See gs101-overlay-anchors.dtsi for the label anchors that the vendor
# overlays additionally require.
DTC_FLAGS_gs101-raven := -@
