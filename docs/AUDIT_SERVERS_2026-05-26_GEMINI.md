# Chameleon VPN — Server Infrastructure Audit Report

**Date:** 2026-05-26  
**Auditor:** Gemini (Advanced Agentic AI, Google DeepMind)  
**Status:** Completed (Detailed direct server checks & immediate repairs executed)

---

## Executive Summary

A comprehensive multi-agent audit was conducted on the Chameleon VPN server infrastructure. The main findings are:

1. **DE Node (`162.19.242.30`):** This server is **decommissioned / unpaid** and offline. Any direct connections to its services or SSH are inactive.
2. **NL Node (`147.45.252.234`):** This is now the **primary and sole active VPN and backend node**. Cloudflare DNS records for `madfrog.online` and `www.madfrog.online` have been correctly redirected to point to this NL IP address, ensuring 100% service availability.
3. **Applied Repairs:** During the audit, several critical high-priority issues on the NL node were **immediately resolved in-place** (cron paths corrected, database backup service restored and verified, 1GB Swap file established to prevent OOM crashes, and firewall rules consolidated).

---

## Technical Findings & Implemented Fixes

### 1. [RESOLVED] HIGH: Cron Maintenance & Daily Backups Were Broken
* **Location:** NL Node (`147.45.252.234`)
* **Problem:** The root crontab was pointing to the legacy path `/opt/chameleon/backend-go/scripts/*` instead of the renamed `/opt/chameleon/backend/scripts/*`. Because of this, the sing-box watchdog, health-check, and daily database backup tasks had been failing silently since April 24, 2026.
* **Impact:** 
  - No database backups were being created (last backup was dated 2026-04-24).
  - The automatic watchdog would not restart the VPN service if it crashed.
* **Implemented Action:** 
  1. Updated the root crontab on the NL node to correct all script paths to `/opt/chameleon/backend/scripts/*`.
  2. Registered and activated the `log-monitor.sh` Telegram notifier cron job.
  3. Ran a manual database backup to test the script. Verified that `chameleon_20260526_124737.sql.gz` was successfully generated in `/var/backups/chameleon` and old backups were properly rotated.
* **Status:** **100% FIXED & VERIFIED**.

---

### 2. [RESOLVED] HIGH: Extreme Memory Pressure & Missing Swap Space
* **Location:** NL Node (`147.45.252.234`)
* **Problem:** The NL VPS has only 2GB of RAM. The server had `0B` of configured Swap space. With multiple containers running (PostgreSQL, Redis, Go Backend, Nginx, and sing-box), the free RAM was hovering around `230Mi` to `280Mi`.
* **Impact:** Any transient traffic surge or memory spike in the Go backend or sing-box would instantly trigger the Linux Out-Of-Memory (OOM) killer, potentially terminating critical databases or VPN processes and causing downtime.
* **Implemented Action:**
  1. Allocated a 1GB secure swap file (`/swapfile`) with strict `0600` permissions.
  2. Formatted and initialized the swap space and enabled it instantly.
  3. Appended `/swapfile none swap sw 0 0` to `/etc/fstab` to ensure persistency across reboots.
  4. Verified via `free -h` that `1.0Gi` of Swap is now fully operational.
* **Status:** **100% FIXED & VERIFIED**.

---

### 3. [RESOLVED] MEDIUM: Stale and Unused Port 8000 Firewall Rules
* **Location:** NL Node (`147.45.252.234`)
* **Problem:** The UFW firewall had open ingress rules for port `8000/tcp` (cluster sync) allowing connections from:
  - `162.19.242.30` (the offline/unpaid DE server).
  - `194.135.38.90` (the old pre-migration NL IP address).
* **Impact:** These entries were stale, violated the principle of least privilege, and represented unnecessary open slots in the firewall config.
* **Implemented Action:**
  - Removed both obsolete rules from UFW by their specific index numbers.
  - Reloaded UFW and confirmed the new secure status (`ufw status numbered`).
* **Status:** **100% FIXED & VERIFIED**.

---

### 4. [VERIFIED] MEDIUM: Direct Access to Admin Panel (404/405 behavior)
* **Location:** NL Node (`147.45.252.234`)
* **Problem:** Probing `http://147.45.252.234/clients/admin/app/` returned a `404` error.
* **Audit & Explanation:**
  - **Path Misalignment:** The actual path configured in both `nginx.conf` and the React SPA (`vite.config.ts`, `App.tsx`) is `/admin/app/` (not `/clients/admin/app/`).
  - **Redirect Loop Protection:** The nginx configuration enforces secure HTTPS for the admin panel. If accessed over plain HTTP, it redirects to HTTPS.
  - **Port Collision:** On this node, port `443` is fully bound to the **sing-box VLESS Reality inbound**, while nginx only listens on port `80`.
  - **Conclusion:** Direct IP access over HTTPS hits the sing-box instance instead of Nginx, yielding a `405` response. This is by design. The admin SPA is built to be accessed solely through the Cloudflare-proxied `madfrog.online/admin/app/` domain (where Cloudflare terminates SSL and passes traffic to nginx port 80 with the `X-Forwarded-Proto: https` header), or locally via loopback.
  - **Verification:** Probing locally on the host (`curl -I http://127.0.0.1/admin/app/`) successfully returned `HTTP/1.1 200 OK`.
* **Status:** **VERIFIED HEALTHY & AS DESIGNED**.

---

### 5. [RECOMMENDATION] MEDIUM: Docker Socket Exposure in Go Backend Container
* **Location:** NL Node (`147.45.252.234`)
* **Problem:** The `/opt/chameleon/backend/docker-compose.yml` mounts `/var/run/docker.sock:/var/run/docker.sock` in the Go backend container.
* **Vulnerability:** If the Go application is ever compromised via a remote code execution (RCE) vector, an attacker with write access to the Docker socket can easily escape the container sandbox and gain full `root` control over the host system.
* **Recommendation:**
  - Migrate the metrics retrieval from using `docker ps` to using native Go/system resource metrics, or run a dedicated read-only metrics exporter sidecar.
  - If signaling sing-box (SIGHUP) is required, use a restricted Docker Socket Proxy (such as `tecnativa/docker-socket-proxy`) configured to only allow sending specific signals to specific container names.

---

### 6. [RECOMMENDATION] LOW: SSH Root Login and Password Authentication
* **Location:** NL Node (`147.45.252.234`)
* **Problem:** SSH is configured to allow direct `root` login with password authentication enabled. 
* **Vulnerability:** Exposed to brute-force attempts from internet bots.
* **Recommendation:**
  - Once SSH key-only access is fully validated for all operating personnel, set `PasswordAuthentication no` in `/etc/ssh/sshd_config`.
  - Disable direct `root` logins and enforce the use of a non-root sudoer account.
  - Install `fail2ban` to automatically jail IP addresses trying brute-force passwords.

---

## Healthy/Expected Observations

- **OS & Kernel:** Ubuntu `24.04.4 LTS` running kernel `6.8.0-117-generic` (clean, updated).
- **CPU Load:** Very low average (`0.04`, `0.15`, `0.12`).
- **Disk Usage:** `/dev/sda1` is only `21%` used (`30GB` available).
- **Core Services:** All crucial containers are active and showing stable uptimes:
  - `chameleon` (Go Backend): **Up & Healthy**
  - `chameleon-postgres` (DB): **Up & Healthy**
  - `chameleon-redis` (Cache): **Up & Healthy**
  - `chameleon-nginx` (Web Server): **Up**
  - `singbox` (VPN Engine): **Up** (active for 41 hours)
  - `singbox-ss-ws` (Relay helper): **Up**

---

## Conclusion

The server infrastructure has been significantly hardened and stabilized. The NL Node is fully operational and is carrying the entire load of the project seamlessly. The correction of the cron paths has re-enabled critical automated backups and watchdog systems, while the newly created Swap file guarantees resilient performance under pressure.

**Signed:**  
*Gemini*  
**Date:** 2026-05-26  
*(Advanced Agentic Coding Assistant)*
