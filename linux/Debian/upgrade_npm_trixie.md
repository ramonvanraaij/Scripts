# Nginx Proxy Manager Upgrade & Troubleshooting Log (Debian Bookworm -> Trixie)

## Background & Motivation
This LXC container was originally created using the [Proxmox VE Community Script](https://community-scripts.github.io/ProxmoxVE/scripts?id=nginxproxymanager).

Before proceeding with the upgrade, a full backup was performed using **Proxmox Backup Server (PBS)** to allow for a safe rollback if needed.

The decision to perform an in-place upgrade of the operating system and the application (from v2.12.6 to v2.13.5), rather than a fresh install, was motivated by the fact that Nginx Proxy Manager (NPM) lacks a native import/export function for its configuration, hosts, and SSL certificates. Migrating data to a fresh instance manually would have been error-prone and time-consuming.

## Overview
This document logs the specific errors, failed attempts, and final solutions encountered while upgrading the host from Debian 12 (Bookworm) to Debian 13 (Trixie) and updating NPM.

## 1. Operating System Upgrade
**Goal:** Upgrade Debian Bookworm to Debian Trixie (Testing).

**Impact:**
*   **Python:** System Python updated from 3.11 to 3.13.
*   **PCRE:** `libpcre3` (PCRE 1) was removed/obsoleted. `libpcre2` (PCRE 2) became the standard.
*   **Node.js:** The manually installed Node.js v16 became outdated.

---

## 2. Post-Upgrade Troubleshooting

### Issue A: Certbot Crash Loop (Python Mismatch)
**Symptom:**
The NPM backend service failed to start. Logs indicated errors attempting to load Python modules.

**Cause:**
The existing virtual environment (`/opt/certbot`) was created using Python 3.11. When Debian upgraded to Python 3.13, the binary links and shared libraries in the venv became invalid.

**Solution:**
Recreate the virtual environment using the new system Python.
```bash
rm -rf /opt/certbot
python3 -m venv /opt/certbot
/opt/certbot/bin/pip install certbot certbot-dns-cloudflare
```

---

### Issue B: OpenResty Compilation & PCRE Hell
**Context:**
Nginx Proxy Manager relies on OpenResty. The existing binary was broken by the OS upgrade (missing shared libraries). Compiling from source was required.

#### Attempt 1: Standard Compilation
**Error:**
```text
you need to have ldconfig in your PATH env when enabling luajit.
```
**Cause:**
In the non-interactive SSH/sudo environment, `/sbin` and `/usr/sbin` were missing from the `$PATH`.
**Solution:** `export PATH=$PATH:/sbin:/usr/sbin`

#### Attempt 2: Using System Libraries
**Command:** `./configure --with-pcre ...`
**Error:**
```text
checking for PCRE library ... not found
./configure: error: the HTTP rewrite module requires the PCRE library.
```
**Cause:**
OpenResty's Nginx core defaults to looking for **PCRE 1**. Debian Trixie only provides `libpcre2-dev` (PCRE 2). The configure script could not find the legacy `pcre.h`.

#### Attempt 3: Forcing PCRE 2
**Command:** `./configure --with-pcre2 ...`
**Error:**
```text
./configure: error: invalid option "--with-pcre2"
```
**Cause:**
While OpenResty supports PCRE 2, the configure wrapper does not accept a `--with-pcre2` flag. It expects to auto-detect it if `pcre.h` (legacy) is absent, but this auto-detection failed or conflicted with other flags.

#### Attempt 4: Static Linking against PCRE 2 Source
**Action:** Downloaded PCRE 2 source (`pcre2-10.42`) and pointed OpenResty to it: `--with-pcre=/tmp/pcre2-10.42`.
**Error (during `make`):**
```text
/usr/bin/ld: required symbol `pcre_version' not defined
collect2: error: ld returned 1 exit status
```
**Cause:**
The Nginx `http_rewrite_module` (legacy version used by default) relies on the symbol `pcre_version`, which is specific to PCRE 1. PCRE 2 uses different symbols. Pointing the `--with-pcre` flag to a PCRE 2 source tree caused a mismatch between the expected and provided symbols.

#### Final Solution: Static Linking against PCRE 1
Since Debian Trixie does not provide `libpcre3-dev`, we must compile the legacy library from source.
1.  Downloaded **PCRE 8.45** (Legacy).
2.  Configured OpenResty to build it statically:
    ```bash
    ./configure --with-pcre=/tmp/pcre-8.45 --with-pcre-jit ...
    ```

---

### Issue C: Node.js Version Incompatibility
**Symptom:**
Building the frontend failed immediately.
**Error:**
```text
npm WARN EBADENGINE Unsupported engine {
npm WARN EBADENGINE   package: '@tabler/core@1.4.0',
npm WARN EBADENGINE   required: { node: '>=20' },
npm WARN EBADENGINE   current: { node: 'v16.20.2', npm: '8.19.4' }
```
**Cause:**
Nginx Proxy Manager v2.13.5 requires Node.js v20+. The host had v16 installed manually in `/usr/local/bin`.

**Solution:**
1.  Install Debian's Node.js package (Trixie includes v20.19+): `apt-get install nodejs npm`.
2.  Remove conflicting manual binaries: `rm /usr/local/bin/node`.
3.  Symlink system binaries to `/usr/local/bin` to satisfy hardcoded paths in the existing systemd service file.

---

### Issue D: Incorrect Version Display
**Symptom:**
After upgrade, the UI displayed "v2.0.0" in the footer.
**Cause:**
The git tags for NPM releases often contain a placeholder version (`2.0.0`) in `package.json`. The real version is usually injected during their CI/CD build process. Building strictly from source uses the placeholder.
**Solution:**
Manually patch `package.json` before building:
```bash
sed -i 's/"version": "2.0.0"/"version": "2.13.5"/' package.json
```

---

### Issue E: Service Name Confusion & Port Conflicts
**Symptom:**
Running `systemctl restart nginx` failed with `Unit nginx.service not found`. Even after using the correct `openresty` service, it failed with `Address already in use` errors (bind failed on 0.0.0.0:80).

**Cause:**
Two things were happening:
1.  The Proxmox community script uses `openresty` as the service name, not `nginx`.
2.  The old nginx process from before the upgrade was still running in the background, holding onto port 80 and 443. The new service couldn't start because the ports were occupied by this "zombie" process.

**Solution:**
Identify the rogue process, kill it, and then restart the correct service.

```bash
# Find the process holding port 80
lsof -i :80

# If 'killall' is missing, install it (required for minimal installs)
apt-get install -y psmisc

# Kill the old nginx processes
killall nginx

# Restart the correct OpenResty service
systemctl restart openresty
```

Restart Services:
```bash
systemctl restart npm
systemctl restart openresty
```

## 3. Automation
A script `upgrade_npm_trixie.sh` has been created in this directory. It automates:
1.  OS Upgrade prompts.
2.  OpenResty + Legacy PCRE compilation.
3.  Node.js upgrade and cleanup.
4.  NPM patching and deployment.
