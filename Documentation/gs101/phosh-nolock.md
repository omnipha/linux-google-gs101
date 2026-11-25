# Persistent Phosh Lock Screen and Passcode Disablement

**Issue:** #9  
**Platform:** Pixel 6 Pro (`raven`, gs101)  
**Rootfs:** Nura edge / postmarketOS edge (aarch64)  
**Scope:** Userspace only (no kernel rebuild or flashing required)  

---

## 1. Problem Statement

On default postmarketOS/Nura installations with Phosh:
- Phosh activates screen locking and requires a numeric PIN/passcode to access the user session.
- Idle blanking and screen timeouts blank the display (`Unknown-1` on simpledrm) after 300 seconds of inactivity.
- Suspend and resume cycles trigger PAM authentication prompts or screen lock reactivation.

Goal: Provide persistent, system-wide defaults so that the device autologins, disables the lock screen and idle timers, removes any passcode requirement, and prevents blanking.

---

## 2. Configuration Architecture

### 2.1 System-wide dconf Defaults and Mandatory Locks

PostmarketOS runs GNOME and Phosh with dconf. User settings are supplemented and enforced via `/etc/dconf/profile/user` and system databases:

1. **Profile configuration (`/etc/dconf/profile/user`):**
   ```ini
   user-db:user
   system-db:local
   system-db:ibus
   ```

2. **System defaults (`/etc/dconf/db/local.d/00-no-lockscreen`):**
   ```ini
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
   ```

3. **Mandatory lock enforcement (`/etc/dconf/db/local.d/locks/00-no-lockscreen`):**
   Keys in this file cannot be overridden by user session configurations.

4. **Compiled database:**
   Compiled with `dconf update` to `/etc/dconf/db/local`.

---

### 2.2 Autologin & Greeter Architecture

- **Session autostart:** Systemd user linger is activated via `loginctl enable-linger user`. The user manager (`user@10000.service`) initializes at boot without manual interactive login.
- **Phosh lifecycle:** `phosh-session.service` runs directly under the user manager without a display manager greeter (e.g. tinydm or greetd).
- **Console autologin:** Console `tty1` uses a systemd drop-in (`/etc/systemd/system/getty@tty1.service.d/autologin.conf`) calling `/usr/local/bin/autologin` (`login -f user`).

---

### 2.3 PAM Resume Prompt Bypass

Phosh links against `libpam.so.0`. To guarantee that any unlock or resume event never prompts for credentials, `/etc/pam.d/phosh` is configured with `pam_permit.so`:

```pam
#%PAM-1.0
auth      sufficient pam_permit.so
account   sufficient pam_permit.so
password  sufficient pam_permit.so
session   sufficient pam_permit.so
```

---

## 3. Setup Script

The automated setup script is tracked at:
`Documentation/gs101/tests/setup-phosh-nolock.sh`

---

## 4. Verification Evidence

### 4.1 Post-Reboot Settings Verification
After system reboot, dconf and gsettings report:
- `org.gnome.desktop.screensaver lock-enabled`: `false`
- `org.gnome.desktop.screensaver idle-activation-enabled`: `false`
- `org.gnome.desktop.session idle-delay`: `uint32 0`
- `org.gnome.desktop.lockdown disable-lock-screen`: `true`
- `mobi.phosh.shell.lockscreen require-unlock`: `false`

### 4.2 5-Minute Idle Verification
- Device remained unattended for 300+ seconds.
- Simpledrm connector `Unknown-1` stayed active (`connected`, no blanking).
- Screenshot captured without session termination or lock screen re-engagement.
