<p align="center">
  <img src="docs/logo.svg" alt="ProxSweep logo" width="112">
</p>

<h1 align="center">ProxSweep</h1>

<p align="center"><b>One command updates your whole Proxmox homelab — the host, every LXC, VMs and Docker — then checks everything came back.</b></p>

<p align="center">
<a href="https://github.com/sponsors/AkuchiS"><img alt="Sponsor" src="https://img.shields.io/badge/Sponsor-%E2%9D%A4-8A2BE2"></a>
<a href="https://github.com/AkuchiS/ProxSweep/releases"><img alt="Release" src="https://img.shields.io/github/v/release/AkuchiS/ProxSweep?color=8A2BE2"></a>
<a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/AkuchiS/ProxSweep?color=8A2BE2"></a>
<a href="https://github.com/AkuchiS/ProxSweep/commits"><img alt="Last commit" src="https://img.shields.io/github/last-commit/AkuchiS/ProxSweep?color=8A2BE2"></a>
<a href="https://github.com/AkuchiS/ProxSweep/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/AkuchiS/ProxSweep?color=8A2BE2"></a>
</p>

<p align="center"><a href="https://github.akuchis.com/ProxSweep/">Website</a> · <a href="#installation">Install</a> · <a href="#settings">Settings</a> · <a href="CHANGELOG.md">Changelog</a></p>

---

A single Bash script for Proxmox VE homelabs. It runs on the Proxmox host and updates the host, every LXC container, every VM with the QEMU guest agent, and the Docker containers inside any of them — snapshotting first, then checking everything came back up.

## What it does

| Target | Method | Details |
|--------|--------|---------|
| Proxmox host | `apt` | Safe mode (default): Debian packages only, minus any whose upgrade would also change Proxmox packages. Proxmox/kernel packages are listed, not installed. `HOST_MODE=full` runs `apt dist-upgrade`, the Proxmox-supported way |
| LXC and VMs (Debian/Ubuntu) | `apt-get dist-upgrade` | Non-interactive, keeps your existing config files, finishes interrupted `dpkg` runs first |
| LXC and VMs (Alpine / Fedora) | `apk` / `dnf` | Auto-detected |
| LXC (opkg-based) | `opkg` | OpenWRT, Entware and other embedded Linux |
| VMs | QEMU guest agent | Commands run through `qm guest exec`; VMs without the agent are skipped with a note |
| Docker (inside any guest) | `docker compose` + Watchtower | Compose projects: `pull` + `up -d`, so dependent containers (e.g. ones sharing a VPN container's network) are recreated too. Other containers: Watchtower `--run-once --cleanup` |

Guests that run Docker get their OS packages updated as well — Docker itself included.

### Safety and recovery

- **Snapshot before every change.** Each guest is snapshotted (`proxsweep_YYYYMMDD_HHMMSS`) before it is touched; the last 3 are kept. The log prints the exact rollback command. Storage without snapshot support gets a warning (or the guest is skipped with `SNAPSHOT_REQUIRED=1`).
- **Restarts when needed.** After a package upgrade the script looks for processes still running deleted (old) libraries, the reboot-required flag, or a newer kernel. LXC containers are restarted and checked; VMs are reported (or restarted with `REBOOT_VMS=1`). The host is never rebooted.
- **Docker containers come back.** Containers that were running before the update and are stopped afterwards are started again. Unhealthy or restart-looping containers are flagged.
- **Persistent restart settings are checked.** Running guests without *Start at boot* (`onboot`) and Docker containers without a restart policy (`unless-stopped`/`always`) are flagged, because they stay down after a reboot. `FIX_ONBOOT=1` and `FIX_RESTART_POLICY=1` fix them.
- **Honest results.** A package source that fails to refresh (an expired or rejected signing key, say) is flagged instead of reported as up to date. Failures (including Watchtower errors) are reported as errors, and the script exits `1` if anything failed — so cron mail or monitoring can catch it.
- **Disk-space guard.** A guest with less than 1 GB free is not upgraded, so a nearly full disk can't leave it half-upgraded. That's an error when updates were held back, and a warning when nothing was due.
- **Busy or stuck package locks.** apt waits up to `APT_LOCK_WAIT` seconds for another package run to finish. A lock held for hours is reported as stuck, naming the process, instead of failing cryptically.
- **Service checks.** List your web apps in `SERVICE_CHECKS`; each must answer (HTTP 2xx/3xx) after the run, or it's an error.
- **Inventory.** New, removed, renamed and stopped/started guests since the last run are reported.
- **One run at a time.** A lock stops overlapping cron runs.

## Requirements

- Proxmox VE 7+ host
- Run as `root` on the Proxmox host (not inside a container)
- Internet access from the host and guests
- For VMs: `qemu-guest-agent` installed in the VM and *QEMU Guest Agent* enabled in its Options

## Installation

```bash
curl -fsSL -o /usr/local/bin/pve_stack_updater.sh \
  https://raw.githubusercontent.com/AkuchiS/ProxSweep/main/pve_stack_updater.sh
chmod +x /usr/local/bin/pve_stack_updater.sh
pve_stack_updater.sh --check
```

`--check` confirms the host has everything ProxSweep needs and whether it's scheduled.

## Usage

```
pve_stack_updater.sh [--dry-run] [--check] [--config FILE] [--version] [--help]
```

Try it first without changing anything:
```bash
/usr/local/bin/pve_stack_updater.sh --dry-run
```

Run for real:
```bash
/usr/local/bin/pve_stack_updater.sh
```

Limit a run to some guests:
```bash
ONLY_IDS="105 110" /usr/local/bin/pve_stack_updater.sh
```

Nightly at 3am:
```bash
echo '0 3 * * * root /usr/local/bin/pve_stack_updater.sh >> /var/log/pve_stack_updater/cron.log 2>&1' \
  > /etc/cron.d/proxsweep
```

## Settings

Put any of these in `/etc/proxsweep.conf` (plain `NAME=value` lines; survives script updates) or set them in the environment.

| Setting | Default | Meaning |
|---------|---------|---------|
| `HOST_MODE` | `safe` | `safe`, `full` (dist-upgrade) or `off` |
| `UPDATE_VMS` | `1` | Update running VMs that have the guest agent |
| `APT_MODE` | `dist-upgrade` | Or `upgrade` to hold back packages that need new dependencies |
| `SNAPSHOT` / `SNAPSHOT_REQUIRED` / `KEEP_SNAPSHOTS` | `1` / `0` / `3` | Snapshot before changes; skip the guest if it fails; how many to keep |
| `RESTART_STALE` | `reboot` | LXC running old code after an update: `reboot` or `report` |
| `REBOOT_VMS` | `0` | Also restart VMs that need it |
| `UPDATE_DOCKER` | `1` | Update Docker containers inside guests |
| `WATCHTOWER_IMAGE` | `containrrr/watchtower:latest` | Image used for non-compose containers |
| `RESTORE_DOCKER` | `1` | Start containers that stopped during the update |
| `FIX_RESTART_POLICY` | `0` | Set `unless-stopped` on non-compose containers that have no restart policy |
| `FIX_ONBOOT` | `0` | Turn on *Start at boot* for running guests without it |
| `MIN_FREE_MB` | `1024` | Don't upgrade a guest with less free space than this on `/` (reported as an error) |
| `SERVICE_CHECKS` | *(none)* | Web pages that must respond after the run, as `Name=URL` (see below) |
| `APT_LOCK_WAIT` | `600` | Seconds apt waits for another package run to finish |
| `STATE_DIR` | `/var/lib/proxsweep` | Where the guest inventory is kept |
| `SKIP_IDS` | `600` | Guest IDs to skip |
| `DRY_RUN` | `0` | Report only |

Example `/etc/proxsweep.conf`:

```bash
SKIP_IDS="600"
FIX_ONBOOT=1
SERVICE_CHECKS=(
  "Plex=http://10.0.0.10:32400/web"
  "Sonarr=http://10.0.0.11:8989"
)
```

## Skipping guests

### Preferred — Proxmox GUI tag

Select the container or VM → **Options** → **Tags** → add `no-auto-update`. The script skips it with a clear log message (it still checks *Start at boot*).

### Fallback — SKIP_IDS

```bash
SKIP_IDS="100 200 300"   # in /etc/proxsweep.conf
```

Stopped guests, templates and locked guests (e.g. during a backup) are skipped automatically.

## Logs

Logs are written to `/var/log/pve_stack_updater/YYYY-MM-DD.log` (no colour codes) and removed after 30 days.

```
[2026-11-22 03:00:01] ===  [101] plex (LXC)
[2026-11-22 03:00:04] [---] [101] plex — 2 package(s) to upgrade via apt-get: plexmediaserver libc6
[2026-11-22 03:00:05] [ OK] [101] plex — snapshot proxsweep_20261122_030005 taken (undo with: pct rollback 101 proxsweep_20261122_030005)
[2026-11-22 03:00:31] [ OK] [101] plex — packages upgraded (apt-get)
[2026-11-22 03:00:31] [---] [101] plex — restarting: 3 process(es) still running old code (Plex Media Server)
[2026-11-22 03:00:42] [ OK] [101] plex — restarted and running again
[2026-11-22 03:00:42] ===  [102] arr (LXC)
[2026-11-22 03:01:10] [ OK] [102] arr — compose 'arr': 2 container(s) recreated
[2026-11-22 03:01:31] [WRN] [102] arr — qbit stopped during the update, started it again
[2026-11-22 03:01:31] [WRN] [102] arr — portainer has no restart policy, so it stays down after a reboot or Docker restart
...
[2026-11-22 03:03:02]   RESULT: 19 guests checked | 5 had package updates | 2 skipped | 3 warnings | 0 errors
```

## Moving from proxmox-stack-maintainer

ProxSweep 1.1 includes everything the old `proxmox-stack-maintainer.sh` did (inventory, service checks, `--dry-run` / `--check` / `--config`) and imports its inventory on the first run. To switch:

```bash
systemctl disable --now proxmox-stack-maintainer.timer
# move SERVICE_CHECKS and SKIP_IDS from /etc/proxmox-stack-maintainer/config.env into /etc/proxsweep.conf
pve_stack_updater.sh --check     # warns if the old timer is still enabled
```

## Notes

### Snapshots and bind mounts
Proxmox can't snapshot a container with a bind mount (for example a NAS share mounted with `mp0: /mnt/...`). ProxSweep warns and updates without a snapshot, or skips the guest if you set `SNAPSHOT_REQUIRED=1`.

### Watchtower
The original `containrrr/watchtower` project is no longer maintained, and older builds fail on newer Docker Engine releases with "client version is too old". The script passes the daemon's API version to Watchtower to avoid that, and reports a real error if Watchtower still fails. You can point `WATCHTOWER_IMAGE` at a maintained fork if you prefer. Compose projects don't use Watchtower at all.

### Portainer stacks
Compose projects whose compose file isn't on the guest's filesystem (for example Portainer stacks) are updated by Watchtower instead.

### opkg-based containers
A single exec call is used per step to work around tmpfs `/tmp` not persisting between exec sessions. Upgrading every opkg package is not officially recommended on OpenWRT; tag the container `no-auto-update` if you'd rather manage it by hand. Major OpenWRT version upgrades are out of scope.

### Apps installed outside a package manager
Apps installed as tarballs in `/opt` (common with community helper scripts) are not updated by apt. Most of them (*arr apps, for example) update themselves.

## Contributing

PRs welcome. Package-manager detection follows a simple `command -v <package-manager>` pattern, so adding another one is straightforward.

## License

MIT

---

<sub>An [AkuchiS](https://github.com/AkuchiS) tool · more at [github.akuchis.com](https://github.akuchis.com) · [Sponsor the work](https://github.com/sponsors/AkuchiS)</sub>
