#!/bin/sh
# Persistent Phosh lockscreen and passcode disablement for Pixel 6 Pro (gs101, raven)
# Issue #9: userspace only, dconf system defaults + autologin + no PAM prompt on resume.

set -eu

echo "==> Configuring dconf system defaults profile"
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d/locks /usr/local/bin

cat > /etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
system-db:ibus
EOF

echo "==> Configuring dconf keyfile defaults"
cat > /etc/dconf/db/local.d/00-no-lockscreen << 'EOF'
[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
lock-delay=uint32 0

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/lockdown]
disable-lock-screen=true

[mobi/phosh/shell/lockscreen]
require-unlock=false

[mobi/phosh/shell]
enable-suspend=false

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
idle-dim=false
ambient-enabled=false
power-button-action='nothing'
EOF

echo "==> Locking keys against user session override"
cat > /etc/dconf/db/local.d/locks/00-no-lockscreen << 'EOF'
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/idle-activation-enabled
/org/gnome/desktop/screensaver/lock-delay
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/lockdown/disable-lock-screen
/mobi/phosh/shell/lockscreen/require-unlock
/mobi/phosh/shell/enable-suspend
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout
/org/gnome/settings-daemon/plugins/power/idle-dim
/org/gnome/settings-daemon/plugins/power/ambient-enabled
/org/gnome/settings-daemon/plugins/power/power-button-action
EOF

echo "==> Compiling dconf system database"
dconf update

echo "==> Configuring console autologin on tty1"
cat > /usr/local/bin/autologin << 'EOF'
#!/bin/sh
exec /usr/sbin/login -f user
EOF
chmod 755 /usr/local/bin/autologin

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/getty -n -l /usr/local/bin/autologin 0 %I ${TERM}
EOF

echo "==> Configuring PAM prompt bypass for Phosh on resume"
cat > /etc/pam.d/phosh << 'EOF'
#%PAM-1.0
auth      sufficient pam_permit.so
account   sufficient pam_permit.so
password  sufficient pam_permit.so
session   sufficient pam_permit.so
EOF

echo "==> Enabling user manager lingering"
loginctl enable-linger user
systemctl daemon-reload

echo "==> Verifying system dconf database"
dconf read /org/gnome/desktop/screensaver/lock-enabled
dconf read /org/gnome/desktop/session/idle-delay
dconf read /org/gnome/desktop/lockdown/disable-lock-screen
dconf read /mobi/phosh/shell/lockscreen/require-unlock

echo "Phosh persistent no-lock configuration complete."
