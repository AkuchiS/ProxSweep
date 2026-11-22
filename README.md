# ProxSweep

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-8A2BE2)](https://github.com/sponsors/AkuchiS)
[![License](https://img.shields.io/github/license/AkuchiS/proxsweep?color=8A2BE2)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/AkuchiS/proxsweep?color=8A2BE2)](https://github.com/AkuchiS/proxsweep/commits)
[![Stars](https://img.shields.io/github/stars/AkuchiS/proxsweep?color=8A2BE2)](https://github.com/AkuchiS/proxsweep/stargazers)

Automated update script for Proxmox VE homelab stacks. Runs on the Proxmox host and updates the host, every LXC container, every VM with the QEMU guest agent, and the Docker containers inside any of them — then checks everything came back up.

## What it does

| Target | Method | Details |
|--------|--------|---------|
| Proxmox host | `apt` | Safe mode (default): Debian packages only. Proxmox/kernel packages are listed, not installed. `HOST_MODE=full` runs `apt dist-upgrade`, the Proxmox-supported way |
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
- **Honest results.** Failures (including Watchtower errors) are reported as errors, and the script exits `1` if anything failed — so cron mail or monitoring can catch it.
- **One run at a time.** A lock stops overlapping cron runs.

## Requirements

- Proxmox VE 7+ host
- Run as `root` on the Proxmox host (not inside a container)
- Internet access from the host and guests
- For VMs: `qemu-guest-agent` installed in the VM and *QEMU Guest Agent* enabled in its Options

## Installation

```bash
curl -o /usr/local/bin/pve_stack_updater.sh \
  https://raw.githubusercontent.com/AkuchiS/ProxSweep/main/pve_stack_updater.sh
chmod +x /usr/local/bin/pve_stack_updater.sh
```

## Usage

Try it first without changing anything:
```bash
DRY_RUN=1 /usr/local/bin/pve_stack_updater.sh
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
| `SKIP_IDS` | `600` | Guest IDs to skip |
| `DRY_RUN` | `0` | Report only |

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
[2026-11-22 03:03:02]   RESULT: 5 updated | 2 skipped | 3 warnings | 0 errors
```

## Notes

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
