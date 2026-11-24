#!/bin/sh
# Set up Phosh on postmarketOS edge (aarch64) for the Pixel 6 Pro (gs101, raven)
# using software rendering (wlroots pixman renderer) on simpledrm.
#
# Verified on-device 2026-11-24 (issue #5):
#   phoc 0.59 (wlroots0.20, statically linked) + phosh 0.59 + seatd 0.9
#   backend: /dev/dri/card0 = simpledrm (platform driver "simple-framebuffer")
#   output:  "Unknown-1", 1440x3120 @ 60 Hz
#   renderer: pixman (WLR_RENDERER=pixman, no GPU / panfrost does not bind 0x9202)
#
# Usage: run as root on the device. Idempotent.

set -e

echo "==> packages (device needs working DNS/route via USB net, see docs)"
apk add phoc phosh seatd libinput-tools grim

echo "==> seatd systemd unit (postmarketOS systemd image ships no unit)"
cat > /etc/systemd/system/seatd.service <<'EOF'
[Unit]
Description=seatd seat management daemon
Documentation=man:seatd(1)
Before=display-manager.service

[Service]
Type=simple
ExecStart=/usr/bin/seatd -g seat
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now seatd

echo "==> user in seat group (needed to open /dev/dri/card0 and /dev/input/*)"
usermod -aG seat user || true

echo "==> phoc config: connector is 'Unknown-1' on simpledrm"
mkdir -p /etc/phosh
cat > /etc/phosh/phoc.ini <<'EOF'
[output:Unknown-1]
scale = 2
EOF

echo "==> systemd user service (pixman renderer, drm backend on card0)"
install -d -o user -g user /home/user/.config/systemd/user
cat > /home/user/.config/systemd/user/phosh-session.service <<'EOF'
[Unit]
Description=Phosh mobile shell (gs101 simpledrm + pixman)
After=graphical-pre.target seatd.service systemd-logind.service
Wants=graphical-pre.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/10000
Environment=WLR_BACKENDS=drm,libinput
Environment=WLR_DRM_DEVICES=/dev/dri/card0
Environment=WLR_RENDERER=pixman
ExecStart=/usr/bin/phosh-session
Restart=on-failure
RestartSec=2
Slice=session.slice

[Install]
WantedBy=default.target
EOF
chown user:user /home/user/.config/systemd/user/phosh-session.service

echo "==> enable + start as the user (loginctl does not pass through su cleanly)"
sudo -u user systemctl --user daemon-reload
sudo -u user systemctl --user enable --now phosh-session.service

echo "==> linger so the user manager (and Phosh) starts at boot without login"
loginctl enable-linger user

echo "==> verify"
sleep 8
pgrep -x phoc && echo "phoc: running"
pgrep -x phosh && echo "phosh: running"
sudo -u user env XDG_RUNTIME_DIR=/run/user/10000 WAYLAND_DISPLAY=wayland-0 \
    grim /tmp/phosh-verify.png && echo "screenshot: /tmp/phosh-verify.png"
echo "done."
