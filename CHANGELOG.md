# Changelog

Notable changes to this project. Newest first.

## [1.1.0] - 2026-11-22
- New logo, refreshed website and README.
- Absorbs proxmox-stack-maintainer: guest inventory between runs (new, removed, renamed, started/stopped; its old inventory is imported), `SERVICE_CHECKS` web checks after the run, and `--dry-run`, `--check`, `--config`, `--version`, `--help`.
- apt waits for a busy package lock (`APT_LOCK_WAIT`), and a lock stuck for hours is reported with the process holding it.
- VMs are now updated through the QEMU guest agent; Alpine (`apk`) and Fedora (`dnf`) guests are supported.
- Guests running Docker now get their OS packages updated too, Docker included.
- apt uses `dist-upgrade`, keeps existing config files and repairs interrupted `dpkg` runs, so packages are no longer silently held back or stuck on prompts.
- Fixed: commands run inside guests could read the loop's input, so one prompt could break the rest of the run.
- Each guest is snapshotted before changes (last 3 kept), with the rollback command in the log.
- Containers still running old code after an update are restarted and checked; VMs are reported.
- Docker compose projects are updated with `pull` + `up -d`, so dependent containers (e.g. behind a VPN container) are recreated correctly. Watchtower handles the rest with `--cleanup`.
- Fixed: Watchtower failures were always reported as OK. Real errors are now reported and the script exits 1 if anything failed.
- Docker containers that stop during an update are started again; missing restart policies and *Start at boot* settings are flagged (optional fixes: `FIX_RESTART_POLICY=1`, `FIX_ONBOOT=1`).
- Host: Proxmox packages waiting are listed; `HOST_MODE=full` runs the Proxmox-supported dist-upgrade. Running vs installed kernel is checked.
- Host safe mode installs the Debian updates that don't need Proxmox packages and lists the ones it held back, instead of skipping all of them.
- A package source that fails to refresh is flagged instead of the guest being reported as up to date.
- Guests with less than `MIN_FREE_MB` (1 GB) free are not upgraded and are reported as an error, so a full disk can't break an upgrade halfway.
- Clearer summary: guests checked and guests with package updates (waiting, in a dry run).
- Added `DRY_RUN`, `ONLY_IDS`, `/etc/proxsweep.conf`, a run lock and colour-free log files. README install URL and log path corrected.

## [1.0.0] - 2026-06-28
- One command updates a whole Proxmox homelab: the host, every LXC, and Docker, in a single pass.
- Detects each container's package manager (apt/opkg and the `command -v` pattern) and reports reboot-required clearly — it never reboots automatically.
