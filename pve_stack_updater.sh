#!/usr/bin/env bash
# ============================================================
#  ProxSweep — pve_stack_updater.sh
#  Updates a Proxmox VE host, its LXC containers, its VMs (through the
#  QEMU guest agent) and the Docker containers running inside any of them.
#  Run on the Proxmox HOST as root.
#
#  Usage:   pve_stack_updater.sh [--dry-run] [--check] [--config FILE]
#           ONLY_IDS="105 110" pve_stack_updater.sh   # limit to some guests
#  Config:  /etc/proxsweep.conf (optional; plain VAR=value lines, survives
#           script updates). Settings are listed under SETTINGS below.
#  Logs:    /var/log/pve_stack_updater/YYYY-MM-DD.log
#  Exit:    0 = no errors, 1 = at least one error (see log), 2 = bad option
# ============================================================

set -o pipefail

# cron (and some systemd units) start jobs with a minimal PATH such as
# /usr/bin:/bin, which leaves out /usr/sbin, where Proxmox keeps pct and qm.
# Put the standard system directories first so scheduled runs find them.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

PROXSWEEP_VERSION="1.2.1"

usage() {
    cat <<'EOF'
ProxSweep — updates a Proxmox host, its containers, VMs and Docker.

Usage:
  pve_stack_updater.sh [--dry-run] [--check] [--config FILE]

Options:
  --dry-run       Show what would be updated; change nothing.
  --check         Check this host has what ProxSweep needs, then exit.
  --config FILE   Read settings from FILE instead of /etc/proxsweep.conf.
  --version       Print the version.
  -h, --help      Show this help.

Settings can also be given as environment variables, e.g. ONLY_IDS="105 110".
EOF
}

CHECK_ONLY=0; CLI_DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  CLI_DRY_RUN=1 ;;
        --check)    CHECK_ONLY=1 ;;
        --config)   shift; CONFIG_FILE="${1:-}" ;;
        --config=*) CONFIG_FILE="${1#*=}" ;;
        --version)  echo "ProxSweep $PROXSWEEP_VERSION"; exit 0 ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

CONFIG_FILE="${CONFIG_FILE:-/etc/proxsweep.conf}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
[ "$CLI_DRY_RUN" = 1 ] && DRY_RUN=1

# ── SETTINGS (override in /etc/proxsweep.conf or the environment) ──────
: "${LOG_DIR:=/var/log/pve_stack_updater}"
: "${SKIP_IDS:=600}"          # space-separated guest IDs to skip. Preferred: tag the
                              # guest "no-auto-update" in the Proxmox GUI instead
: "${ONLY_IDS:=}"             # if set, only these guest IDs are processed
: "${DRY_RUN:=0}"             # 1 = report what would happen, change nothing
: "${HOST_MODE:=safe}"        # safe = Debian packages only, Proxmox/kernel left for you
                              # full = apt dist-upgrade (the Proxmox-supported way)
                              # off  = leave the host alone
: "${UPDATE_VMS:=1}"          # update running VMs that have the QEMU guest agent
: "${APT_MODE:=dist-upgrade}" # dist-upgrade (nothing held back) or upgrade
: "${SNAPSHOT:=1}"            # snapshot each guest before changing it
: "${SNAPSHOT_REQUIRED:=0}"   # 1 = skip a guest whose snapshot fails
: "${KEEP_SNAPSHOTS:=3}"      # ProxSweep snapshots kept per guest
: "${RESTART_STALE:=reboot}"  # LXC still running old code after an update:
                              # reboot = restart the container, report = only log it
: "${REBOOT_VMS:=0}"          # 1 = also restart VMs that need it
: "${UPDATE_DOCKER:=1}"       # update Docker containers inside guests
: "${WATCHTOWER_IMAGE:=containrrr/watchtower:latest}"
: "${DOCKER_PRUNE:=1}"        # remove dangling images after updating
: "${RESTORE_DOCKER:=1}"      # start containers that were running before the update
                              # but are stopped afterwards
: "${FIX_RESTART_POLICY:=0}"  # 1 = give running non-compose containers with no
                              # restart policy "unless-stopped"
: "${FIX_ONBOOT:=0}"          # 1 = turn on "Start at boot" for running guests without it
: "${MIN_FREE_MB:=1024}"       # skip upgrades in a guest with less free space on /
: "${EXEC_TIMEOUT:=1800}"     # seconds allowed for one step inside a guest
: "${APT_LOCK_WAIT:=600}"     # seconds apt waits for another package run to finish
: "${SETTLE_SECONDS:=20}"     # wait before checking Docker containers came back
: "${STATE_DIR:=/var/lib/proxsweep}"   # guest inventory kept between runs
: "${SERVICE_CHECK_TIMEOUT:=8}"        # seconds per web check attempt
: "${SERVICE_CHECK_TRIES:=3}"          # attempts (10 s apart) before a check fails
: "${HEALTH_CHECKS:=1}"                # check disk, swap and out-of-memory kills per guest
: "${DISK_WARN_PCT:=85}"               # warn when a guest's / is this full (%)
: "${DISK_ERR_PCT:=95}"                # error when a guest's / is this full (%)
: "${SWAP_WARN_PCT:=90}"               # warn when a guest's swap is this full (%)
: "${CGROUP_LXC_ROOT:=/sys/fs/cgroup/lxc}"  # where Proxmox keeps container memory counters
# SERVICE_CHECKS: web pages that must respond after the run, as Name=URL.
#   In /etc/proxsweep.conf:  SERVICE_CHECKS=("Plex=http://10.0.0.5:32400/web" "Sonarr=http://10.0.0.6:8989")
#   Or a space-separated string in the environment.
if declare -p SERVICE_CHECKS 2>/dev/null | grep -q '^declare -a'; then
    SVC_LIST=("${SERVICE_CHECKS[@]}")
else
    read -r -a SVC_LIST <<<"${SERVICE_CHECKS:-}"
fi

LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"
LOCK_FILE="/run/proxsweep.lock"
INV_FILE="$STATE_DIR/inventory.tsv"
OOM_FILE="$STATE_DIR/oom_kills.tsv"
LEGACY_INV_FILE="/var/lib/proxmox-stack-maintainer/inventory.tsv"

# ── --check: report whether this host is ready, then exit ─────────────
runtime_check() {
    local rc=0 c
    say() { printf '%-5s %s\n' "$1" "$2"; }
    echo "ProxSweep $PROXSWEEP_VERSION — host check"
    if [ "$EUID" -eq 0 ]; then say OK "running as root"; else say FAIL "must run as root"; rc=1; fi
    for c in pct qm flock timeout perl curl apt-get; do
        if command -v "$c" >/dev/null 2>&1; then say OK "command found: $c"; else say FAIL "missing command: $c"; rc=1; fi
    done
    if perl -MJSON::PP -e 1 2>/dev/null; then say OK "Perl JSON::PP available (needed for VMs)"
    else say WARN "Perl JSON::PP missing: VMs will not be updated"; fi
    if [ -f "$CONFIG_FILE" ]; then say OK "config: $CONFIG_FILE"; else say INFO "no config file at $CONFIG_FILE (defaults in use)"; fi
    say INFO "log dir: $LOG_DIR"
    say INFO "state dir: $STATE_DIR"
    say INFO "service checks configured: ${#SVC_LIST[@]}"
    if [ "$HEALTH_CHECKS" = 1 ]; then say INFO "health checks: disk warn ${DISK_WARN_PCT}% / error ${DISK_ERR_PCT}%, swap warn ${SWAP_WARN_PCT}%"
    else say INFO "health checks: off"; fi
    if grep -qs 'pve_stack_updater' /etc/cron.d/* /var/spool/cron/crontabs/root 2>/dev/null \
        || systemctl list-timers --all --no-pager 2>/dev/null | grep -q proxsweep; then
        say OK "scheduled (cron or systemd timer found)"
    else
        say WARN "not scheduled: see the README for the nightly cron line"
    fi
    if systemctl is-enabled proxmox-stack-maintainer.timer >/dev/null 2>&1; then
        say WARN "old proxmox-stack-maintainer.timer is still enabled: two updaters would run"
    fi
    if (exec 8>"$LOCK_FILE" && flock -n 8) 2>/dev/null; then say OK "no ProxSweep run in progress"
    else say INFO "a ProxSweep run is in progress"; fi
    return "$rc"
}
if [ "$CHECK_ONLY" = 1 ]; then runtime_check; exit $?; fi

# ── OUTPUT ────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[1;34m'; NC='\033[0m'
else
    RED=''; GRN=''; YLW=''; BLU=''; NC=''
fi

TOTAL_CHECKED=0; TOTAL_WITH_UPDATES=0; TOTAL_SKIPPED=0; TOTAL_ERRORS=0; TOTAL_WARNINGS=0
SNAPPED=0

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    printf '%b\n' "$line"
    printf '%b\n' "$line" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}
ok()    { log "${GRN}[ OK] $1${NC}"; }
info()  { log "[---] $1"; }
warn()  { log "${YLW}[WRN] $1${NC}"; TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1)); }
err()   { log "${RED}[ERR] $1${NC}"; TOTAL_ERRORS=$((TOTAL_ERRORS + 1)); }
title() { log ""; log "${BLU}===  $1${NC}"; }

# Value of a "PS:KEY=value" line in guest output
getval() { grep "^PS:$1=" <<<"$2" | tail -n 1 | cut -d= -f2-; }

# Single-quote a value for the guest shell
q() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

# Print guest output: PS:OK/WARN/ERR/INFO lines become log entries,
# other PS: lines are data for the caller, everything else is indented.
relay() {
    local p=$1 line
    while IFS= read -r line; do
        case "$line" in
            "PS:OK "*)   ok   "$p ${line#PS:OK }" ;;
            "PS:WARN "*) warn "$p ${line#PS:WARN }" ;;
            "PS:ERR "*)  err  "$p ${line#PS:ERR }" ;;
            "PS:INFO "*) info "$p ${line#PS:INFO }" ;;
            PS:*|"")     ;;
            *)           log "      $line" ;;
        esac
    done <<<"$2"
}

# ── SANITY CHECKS ─────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then echo "ERROR: Must be run as root."; exit 1; fi
for c in pct qm flock timeout perl; do
    command -v "$c" &>/dev/null || { echo "ERROR: '$c' not found. Run this on the Proxmox host."; exit 1; }
done
mkdir -p "$LOG_DIR"
VM_NOTE=""
if [ "$UPDATE_VMS" = 1 ] && ! perl -MJSON::PP -e 1 2>/dev/null; then
    UPDATE_VMS=0; VM_NOTE="Perl JSON::PP module missing, so VMs were not updated"
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then echo "ERROR: ProxSweep is already running."; exit 1; fi

# ── RUNNING COMMANDS INSIDE GUESTS ────────────────────────────────────
# gexec <ct|vm> <id>: runs the shell script given on stdin inside the guest,
# prints its output and returns its exit code (124 = timed out).
gexec() {
    local kind=$1 id=$2 json
    if [ "$kind" = ct ]; then
        timeout "$EXEC_TIMEOUT" pct exec "$id" -- sh -s 2>&1
        return
    fi
    json=$(timeout $((EXEC_TIMEOUT + 60)) qm guest exec "$id" --pass-stdin 1 --timeout "$EXEC_TIMEOUT" -- sh -s 2>&1)
    local rc=$?
    if [ $rc -ne 0 ]; then printf '%s\n' "$json"; return $((rc == 124 ? 124 : 125)); fi
    printf '%s' "$json" | perl -MJSON::PP -0777 -ne '
        my $j = eval { decode_json($_) };
        if (!$j) { print; exit 125 }
        print $j->{"out-data"} // "";
        print $j->{"err-data"} // "";
        exit 124 unless $j->{exited};
        exit($j->{exitcode} // 1);'
}

GUEST_ENV="export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
DRY_RUN=$(q "$DRY_RUN")
APT_MODE=$(q "$APT_MODE")
WATCHTOWER_IMAGE=$(q "$WATCHTOWER_IMAGE")
DOCKER_PRUNE=$(q "$DOCKER_PRUNE")
RESTORE_DOCKER=$(q "$RESTORE_DOCKER")
FIX_RESTART_POLICY=$(q "$FIX_RESTART_POLICY")
SETTLE_SECONDS=$(q "$SETTLE_SECONDS")
APT_LOCK_WAIT=$(q "$APT_LOCK_WAIT")"

# guest_run <kind> <id> <script> [extra variable lines]
# The script body is wrapped in { ... } </dev/null so the guest shell reads
# the whole script first, and nothing inside it can swallow its stdin.
guest_run() {
    {
        printf '%s\n' "$GUEST_ENV" "${4:-}" '{'
        printf '%s\n' "$3"
        printf '%s\n' '} </dev/null'
    } | gexec "$1" "$2"
}

# run_step <kind> <id> <prefix> <label> <script> [extra]: output in STEP_OUT
run_step() {
    local rc
    STEP_OUT=$(guest_run "$1" "$2" "$5" "${6:-}"); rc=$?
    relay "$3 —" "$STEP_OUT"
    if [ $rc -ne 0 ] && ! grep -q '^PS:ERR ' <<<"$STEP_OUT"; then
        if [ $rc -eq 124 ]; then err "$3 — $4 timed out after ${EXEC_TIMEOUT}s"
        else err "$3 — $4 failed (exit $rc)"; fi
    fi
    return $rc
}

# ── GUEST SCRIPTS (POSIX sh, run inside each guest) ───────────────────
read -r -d '' S_PROBE <<'EOF'
pm=none
for m in apt-get apk dnf opkg; do
    if command -v "$m" >/dev/null 2>&1; then pm=$m; break; fi
done
echo "PS:PM=$pm"
echo "PS:FREEMB=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "PS:DOCKER=1"
    docker ps --format '{{.Names}}' | sed 's/^/PS:RUNNING=/'
else
    echo "PS:DOCKER=0"
fi
EOF

read -r -d '' S_PKG_CHECK <<'EOF'
list=""
case "$PM" in
apt-get)
    if [ "$DRY_RUN" != 1 ]; then
        dpkg --configure -a >/dev/null 2>&1 || echo "PS:WARN dpkg --configure -a reported problems"
    fi
    if ! out=$(apt-get -o DPkg::Lock::Timeout="$APT_LOCK_WAIT" update -q 2>&1); then
        printf '%s\n' "$out" | tail -n 5
        echo "PS:ERR apt-get update failed"; exit 1
    fi
    printf '%s\n' "$out" | grep -E '^(W|E):' | head -n 5 | sed 's/^/PS:WARN apt: /'
    printf '%s\n' "$out" | grep -qE '^W: (Failed to fetch|.*signature)|^E: ' && echo "PS:STALEINDEX=1"
    if ! sim=$(apt-get -s "$APT_MODE" 2>&1); then
        printf '%s\n' "$sim" | tail -n 5
        echo "PS:ERR apt cannot plan the upgrade (broken packages?)"; exit 1
    fi
    list=$(printf '%s\n' "$sim" | awk '/^Inst /{print $2}')
    held=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
    [ -n "$held" ] && echo "PS:WARN held packages are never upgraded: $held"
    ;;
apk)
    apk update -q >/dev/null 2>&1 || { echo "PS:ERR apk update failed"; exit 1; }
    list=$(apk version -l '<' 2>/dev/null | awk 'NR>1{print $1}')
    ;;
dnf)
    dnf -q makecache >/dev/null 2>&1
    list=$(dnf -q check-update 2>/dev/null | awk 'NF==3 && $1 ~ /\./ {print $1}')
    ;;
opkg)
    if ! out=$(opkg update 2>&1); then
        printf '%s\n' "$out" | tail -n 3
        echo "PS:WARN opkg update could not reach the package feeds"
        echo "PS:PENDING=0"; exit 0
    fi
    list=$(opkg list-upgradable 2>/dev/null | awk '{print $1}')
    ;;
esac
n=$(printf '%s\n' "$list" | grep -c .)
echo "PS:PENDING=$n"
[ "$n" -gt 0 ] && echo "PS:LIST=$(echo $list)"
exit 0
EOF

read -r -d '' S_PKG_UPGRADE <<'EOF'
case "$PM" in
apt-get)
    out=$(apt-get -y -q -o DPkg::Lock::Timeout="$APT_LOCK_WAIT" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$APT_MODE" 2>&1); rc=$? ;;
apk)
    out=$(apk upgrade --no-progress 2>&1); rc=$? ;;
dnf)
    out=$(dnf -y -q upgrade 2>&1); rc=$? ;;
opkg)
    opkg update >/dev/null 2>&1
    pkgs=$(opkg list-upgradable 2>/dev/null | awk '{print $1}')
    out=$(opkg upgrade $pkgs 2>&1); rc=$?
    printf '%s\n' "$out" | grep -q 'Collected errors' && rc=1 ;;
esac
printf '%s\n' "$out" | tail -n 15
if [ "$rc" -eq 0 ]; then echo "PS:OK packages upgraded ($PM)"
else echo "PS:ERR package upgrade failed ($PM, exit $rc)"; fi
exit "$rc"
EOF

read -r -d '' S_STALE <<'EOF'
n=0; names=""
for p in /proc/[0-9]*; do
    [ -r "$p/maps" ] || continue
    if grep -qE '/(usr|lib|lib64|bin|sbin)/[^ ]* \(deleted\)$' "$p/maps" 2>/dev/null; then
        n=$((n + 1))
        c=$(cat "$p/comm" 2>/dev/null)
        case " $names " in *" $c "*) ;; *) names="$names $c" ;; esac
    fi
done
echo "PS:STALE=$n"
[ "$n" -gt 0 ] && echo "PS:STALE_NAMES=$(echo $names)"
[ -f /var/run/reboot-required ] && echo "PS:REBOOTREQ=1"
if ls /boot/vmlinuz-* >/dev/null 2>&1; then
    new=$(ls /boot/vmlinuz-* | sed 's|.*/vmlinuz-||' | sort -V 2>/dev/null | tail -n 1)
    [ -n "$new" ] && [ "$new" != "$(uname -r)" ] && echo "PS:KERNEL=$new"
fi
exit 0
EOF

read -r -d '' S_DOCKER_UPDATE <<'EOF'
tmp=$(mktemp -d) || { echo "PS:ERR mktemp failed"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fail=0
docker ps --format '{{.Names}}' | sort > "$tmp/before"
: > "$tmp/handled"

if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else DC=""; fi
# Services with both image: and build: must still be pulled, so --ignore-buildable
# is only a fallback for projects whose build-only services can't be pulled.
IGNB=""
[ -n "$DC" ] && $DC pull --help 2>/dev/null | grep -q -- '--ignore-buildable' && IGNB="--ignore-buildable"

# Compose projects: pull + "up -d" recreates changed services and anything that
# depends on them (e.g. containers sharing a VPN container's network).
docker ps --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' \
    | grep -v '^|' | sort -u > "$tmp/projects"
while IFS='|' read -r proj wd files; do
    [ -n "$proj" ] || continue
    if [ -z "$DC" ]; then
        echo "PS:WARN compose project '$proj': docker compose is not installed, using Watchtower instead"; continue
    fi
    set --
    found=1
    oldifs=$IFS; IFS=','
    for f in $files; do
        case "$f" in /*) ;; *) f="$wd/$f" ;; esac
        [ -f "$f" ] || found=0
        set -- "$@" -f "$f"
    done
    IFS=$oldifs
    if [ "$found" != 1 ] || [ ! -d "$wd" ]; then
        echo "PS:WARN compose project '$proj': compose file not found here (Portainer stack?), using Watchtower instead"; continue
    fi
    services=$(cd "$wd" && $DC -p "$proj" "$@" ps --services --filter status=running 2>/dev/null | tr '\n' ' ')
    services=${services% }
    [ -n "$services" ] || continue
    docker ps --filter "label=com.docker.compose.project=$proj" --format '{{.Names}}' >> "$tmp/handled"
    if [ "$DRY_RUN" = 1 ]; then
        echo "PS:INFO compose '$proj': would pull and recreate changed services: $services"; continue
    fi
    if ! out=$(cd "$wd" && $DC -p "$proj" "$@" pull --quiet $services 2>&1); then
        if [ -n "$IGNB" ] && out2=$(cd "$wd" && $DC -p "$proj" "$@" pull --quiet $IGNB $services 2>&1); then
            echo "PS:WARN compose '$proj': some services can't be pulled (built locally?), so only the others were updated"
        else
            printf '%s\n' "$out" | tail -n 5
            echo "PS:ERR compose '$proj': pull failed"; fail=1; continue
        fi
    fi
    if ! out=$(cd "$wd" && $DC -p "$proj" "$@" up -d $services 2>&1); then
        printf '%s\n' "$out" | tail -n 5
        echo "PS:ERR compose '$proj': up -d failed"; fail=1; continue
    fi
    n=$(printf '%s\n' "$out" | grep -c 'Recreate')
    echo "PS:OK compose '$proj': $n container(s) recreated"
done < "$tmp/projects"

# Everything else: Watchtower, limited to the containers not handled above.
others=$(grep -vxF -f "$tmp/handled" "$tmp/before")
if [ -n "$others" ]; then
    count=$(printf '%s\n' "$others" | grep -c .)
    if [ "$DRY_RUN" = 1 ]; then
        echo "PS:INFO would run Watchtower for: $(echo $others)"
    else
        api=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null)
        set -- --rm -v /var/run/docker.sock:/var/run/docker.sock
        [ -n "$api" ] && set -- "$@" -e "DOCKER_API_VERSION=$api"
        docker pull -q "$WATCHTOWER_IMAGE" >/dev/null 2>&1
        wt=$(docker run "$@" "$WATCHTOWER_IMAGE" --run-once --cleanup $others 2>&1)
        printf '%s\n' "$wt" | grep -iE 'level=(error|fatal|warn)|Found new|too old' | tail -n 10
        done_line=$(printf '%s\n' "$wt" | grep 'Session done' | tail -n 1)
        failed=$(printf '%s\n' "$done_line" | grep -oE 'Failed=[0-9]+' | cut -d= -f2)
        updated=$(printf '%s\n' "$done_line" | grep -oE 'Updated=[0-9]+' | cut -d= -f2)
        if [ -z "$done_line" ]; then
            printf '%s\n' "$wt" | grep -v '^goroutine\|^\s' | tail -n 5
            echo "PS:ERR Watchtower did not finish (see output above)"; fail=1
        elif [ "${failed:-0}" -gt 0 ]; then
            echo "PS:ERR Watchtower failed to update $failed container(s)"; fail=1
        else
            echo "PS:OK Watchtower checked $count container(s), updated ${updated:-0}"
        fi
    fi
fi

if [ "$DOCKER_PRUNE" = 1 ] && [ "$DRY_RUN" != 1 ]; then
    r=$(docker image prune -f 2>/dev/null | tail -n 1)
    [ -n "$r" ] && echo "PS:INFO image prune: $r"
fi
exit $fail
EOF

# Needs BEFORE (newline-separated container names that were running at the start)
read -r -d '' S_HEALTH <<'EOF'
df -Pm / 2>/dev/null | awk 'NR==2{sub("%","",$5); print "PS:DISKSIZE="$2; print "PS:DISKFREE="$4; print "PS:DISKPCT="$5}'
awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} /^MemTotal:/{m=$2} /^MemAvailable:/{a=$2}
     END{print "PS:SWAPTOTAL="int(t/1024); print "PS:SWAPUSED="int((t-f)/1024); print "PS:MEMTOTAL="int(m/1024); print "PS:MEMAVAIL="int(a/1024)}' /proc/meminfo 2>/dev/null
exit 0
EOF

read -r -d '' S_DOCKER_VERIFY <<'EOF'
i=0
while ! docker info >/dev/null 2>&1; do
    i=$((i + 1))
    [ $i -ge 18 ] && { echo "PS:ERR Docker daemon is not running"; exit 1; }
    sleep 5
done
[ "$DRY_RUN" = 1 ] || sleep "$SETTLE_SECONDS"
now=$(docker ps --format '{{.Names}}')
for c in $BEFORE; do
    printf '%s\n' "$now" | grep -qxF "$c" && continue
    if [ "$DRY_RUN" != 1 ] && [ "$RESTORE_DOCKER" = 1 ] && docker start "$c" >/dev/null 2>&1; then
        echo "PS:WARN $c stopped during the update, started it again"
    else
        echo "PS:ERR $c was running before the update and is not running now"
    fi
done
for c in $(docker ps --filter health=unhealthy --format '{{.Names}}'); do echo "PS:WARN $c reports unhealthy"; done
for c in $(docker ps --filter status=restarting --format '{{.Names}}'); do echo "PS:ERR $c is stuck restarting"; done
nopol=0
for c in $(docker ps --format '{{.Names}}'); do
    pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)
    case "$pol" in always|unless-stopped|on-failure) continue ;; esac
    proj=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)
    case "$proj" in "<no value>") proj="" ;; esac
    if [ -n "$proj" ]; then
        echo "PS:WARN $c has no restart policy: add 'restart: unless-stopped' to it in compose project '$proj'"
    elif [ "$FIX_RESTART_POLICY" = 1 ] && [ "$DRY_RUN" != 1 ] && docker update --restart unless-stopped "$c" >/dev/null 2>&1; then
        echo "PS:OK $c restart policy set to unless-stopped"
    else
        echo "PS:WARN $c has no restart policy, so it stays down after a reboot or Docker restart (FIX_RESTART_POLICY=1 sets unless-stopped)"
    fi
    nopol=$((nopol + 1))
done
if [ "$nopol" -eq 0 ]; then
    if [ "$DRY_RUN" = 1 ]; then echo "PS:OK all running Docker containers have a restart policy"
    else echo "PS:OK all running Docker containers came back and have a restart policy"; fi
fi
exit 0
EOF

# ── SNAPSHOTS ─────────────────────────────────────────────────────────
take_snapshot() {
    local kind=$1 id=$2 P=$3 tool sn out
    [ "$SNAPSHOT" = 1 ] || return 0
    [ "$SNAPPED" = 1 ] && return 0
    SNAPPED=1
    tool=pct; [ "$kind" = vm ] && tool=qm
    sn="proxsweep_$(date +%Y%m%d_%H%M%S)"
    if out=$($tool snapshot "$id" "$sn" --description "ProxSweep: before automatic update" 2>&1 </dev/null); then
        ok "$P — snapshot $sn taken (undo with: $tool rollback $id $sn)"
        local snaps i excess
        mapfile -t snaps < <($tool listsnapshot "$id" 2>/dev/null </dev/null | grep -oE 'proxsweep_[0-9]{8}_[0-9]{6}' | sort -u)
        excess=$(( ${#snaps[@]} - KEEP_SNAPSHOTS ))
        for (( i = 0; i < excess; i++ )); do
            if $tool delsnapshot "$id" "${snaps[$i]}" >/dev/null 2>&1 </dev/null; then
                info "$P — removed old snapshot ${snaps[$i]}"
            else
                warn "$P — could not remove old snapshot ${snaps[$i]}"
            fi
        done
        return 0
    fi
    if [ "$SNAPSHOT_REQUIRED" = 1 ]; then
        err "$P — no snapshot possible ($(tail -n 1 <<<"$out")), so this guest was skipped (SNAPSHOT_REQUIRED=1)"
        return 1
    fi
    warn "$P — no snapshot possible ($(tail -n 1 <<<"$out")), updating without one. Containers with bind mounts, or on storage without snapshots, can't be snapshotted"
    return 0
}

wait_guest() {
    local kind=$1 id=$2 i
    for (( i = 0; i < 36; i++ )); do
        sleep 5
        if [ "$kind" = ct ]; then
            pct status "$id" 2>/dev/null </dev/null | grep -q running \
                && timeout 10 pct exec "$id" -- true </dev/null >/dev/null 2>&1 && return 0
        else
            timeout 10 qm guest cmd "$id" ping </dev/null >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

# ── ONE GUEST ─────────────────────────────────────────────────────────
process_guest() {
    local kind=$1 id=$2 name=$3 P="[$2] $3" tool pm docker before pending=0 changed=0 rc
    tool=pct; [ "$kind" = vm ] && tool=qm
    SNAPPED=0
    title "$P ($([ "$kind" = ct ] && echo LXC || echo VM))"

    STEP_OUT=$(guest_run "$kind" "$id" "$S_PROBE"); rc=$?
    if [ $rc -ne 0 ]; then
        if [ "$kind" = vm ]; then
            warn "$P — cannot run a shell through the guest agent (Windows guest?), skipped"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        else
            err "$P — cannot run commands inside the container: $(tail -n 2 <<<"$STEP_OUT")"
        fi
        return
    fi
    pm=$(getval PM "$STEP_OUT")
    docker=$(getval DOCKER "$STEP_OUT")
    before=$(grep '^PS:RUNNING=' <<<"$STEP_OUT" | cut -d= -f2-)

    # Too little disk space to upgrade safely? (opkg packages are tiny, so not for opkg)
    local free lowspace=0
    free=$(getval FREEMB "$STEP_OUT")
    if [ "$pm" != opkg ] && [[ "$free" =~ ^[0-9]+$ ]] && [ "$free" -lt "$MIN_FREE_MB" ]; then
        lowspace=1
    fi

    # Packages (also for guests that run Docker: their OS and Docker itself need updates too)
    if [ "$pm" = none ] || [ -z "$pm" ]; then
        info "$P — no supported package manager (apt/apk/dnf/opkg)"
    elif run_step "$kind" "$id" "$P" "package check" "$S_PKG_CHECK" "PM=$(q "$pm")"; then
        pending=$(getval PENDING "$STEP_OUT")
        [[ "$pending" =~ ^[0-9]+$ ]] || pending=0
        if [ "$pending" -eq 0 ] && [ -n "$(getval STALEINDEX "$STEP_OUT")" ]; then
            warn "$P — no updates found, but a package source failed to refresh (see above), so some packages may be out of date"
        elif [ "$pending" -eq 0 ]; then
            ok "$P — packages up to date ($pm)"
        else
            TOTAL_WITH_UPDATES=$((TOTAL_WITH_UPDATES + 1))
            [ -n "$(getval STALEINDEX "$STEP_OUT")" ] && warn "$P — a package source failed to refresh (see above), so some packages may still be out of date"
            info "$P — $pending package(s) to upgrade via $pm: $(getval LIST "$STEP_OUT")"
            if [ "$DRY_RUN" = 1 ]; then
                info "$P — DRY RUN: not upgrading"
            elif [ "$lowspace" = 1 ]; then
                :
            else
                take_snapshot "$kind" "$id" "$P" || return
                run_step "$kind" "$id" "$P" "package upgrade" "$S_PKG_UPGRADE" "PM=$(q "$pm")"
                changed=1
            fi
        fi
    fi

    if [ "$lowspace" = 1 ]; then
        if [ "${pending:-0}" -gt 0 ] || { [ "$docker" = 1 ] && [ "$UPDATE_DOCKER" = 1 ]; }; then
            local msg="$P — only $free MB free on /, below the $MIN_FREE_MB MB needed to upgrade safely, so packages and Docker images were not updated. Free some space or grow the disk"
            if [ "$DRY_RUN" = 1 ]; then warn "$msg"; else err "$msg"; fi
        else
            warn "$P — only $free MB free on / (below $MIN_FREE_MB MB). Nothing was due today, but updates will be held back until space is freed"
        fi
    fi

    # Docker
    if [ "$docker" = 1 ] && [ "$UPDATE_DOCKER" = 1 ] && [ "$lowspace" != 1 ]; then
        if [ "$DRY_RUN" != 1 ]; then take_snapshot "$kind" "$id" "$P" || return; fi
        run_step "$kind" "$id" "$P" "Docker update" "$S_DOCKER_UPDATE"
    fi

    # Anything still running old code after a package upgrade?
    if [ "$changed" = 1 ]; then
        run_step "$kind" "$id" "$P" "restart check" "$S_STALE"
        local stale names rebootreq kernel why=""
        stale=$(getval STALE "$STEP_OUT"); names=$(getval STALE_NAMES "$STEP_OUT")
        rebootreq=$(getval REBOOTREQ "$STEP_OUT"); kernel=$(getval KERNEL "$STEP_OUT")
        [[ "$stale" =~ ^[0-9]+$ ]] && [ "$stale" -gt 0 ] && why="$stale process(es) still running old code ($names)"
        [ -n "$rebootreq" ] && why="${why:+$why; }reboot-required flag set"
        [ -n "$kernel" ] && why="${why:+$why; }new kernel $kernel installed"
        if [ -n "$why" ]; then
            if { [ "$kind" = ct ] && [ "$RESTART_STALE" = reboot ]; } || { [ "$kind" = vm ] && [ "$REBOOT_VMS" = 1 ]; }; then
                info "$P — restarting: $why"
                if $tool reboot "$id" --timeout 120 >/dev/null 2>&1 </dev/null && wait_guest "$kind" "$id"; then
                    ok "$P — restarted and running again"
                else
                    err "$P — restart did not complete, check this guest now"
                fi
            else
                warn "$P — needs a restart: $why"
            fi
        else
            ok "$P — no restart needed"
        fi
    fi

    # Did every Docker container that was running come back?
    if [ "$docker" = 1 ] && [ "$UPDATE_DOCKER" = 1 ]; then
        run_step "$kind" "$id" "$P" "Docker check" "$S_DOCKER_VERIFY" "BEFORE=$(q "$before")"
    fi

    guest_health "$kind" "$id" "$P"
    TOTAL_CHECKED=$((TOTAL_CHECKED + 1))
}

# Decide whether a guest is processed, then process it
consider_guest() {
    local kind=$1 id=$2 tool cfg name status tags lock
    tool=pct; [ "$kind" = vm ] && tool=qm
    if [ -n "$ONLY_IDS" ] && [[ " $ONLY_IDS " != *" $id "* ]]; then return; fi
    cfg=$($tool config "$id" 2>/dev/null </dev/null)
    if [ "$kind" = ct ]; then name=$(awk '/^hostname:/{print $2}' <<<"$cfg")
    else name=$(awk '/^name:/{print $2}' <<<"$cfg"); fi
    name=${name:-$kind$id}
    local P="[$id] $name"
    tags=$(awk '/^tags:/{print $2}' <<<"$cfg")
    status=$($tool status "$id" 2>/dev/null </dev/null | awk '{print $2}')
    grep -q '^template: 1' <<<"$cfg" && status=template
    inventory_record "$kind" "$id" "$name" "${status:-unknown}" "$tags"
    [ "$status" = template ] && return

    if [ "$status" != running ]; then
        info "$P — skipped (status: ${status:-unknown})"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)); return
    fi

    # Running guests should come back after a host reboot
    if ! grep -q '^onboot: 1' <<<"$cfg"; then
        if [ "$FIX_ONBOOT" = 1 ] && [ "$DRY_RUN" != 1 ] && $tool set "$id" --onboot 1 >/dev/null 2>&1 </dev/null; then
            ok "$P — turned on Start at boot"
        else
            warn "$P — Start at boot is off, so it stays down after a host reboot (Options → Start at boot, or FIX_ONBOOT=1)"
        fi
    fi

    if grep -qw "no-auto-update" <<<"$tags"; then
        info "$P — skipped (tagged no-auto-update)"
        [ "$kind" = ct ] && guest_health "$kind" "$id" "$P"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)); return
    fi
    if [[ " $SKIP_IDS " == *" $id "* ]]; then
        info "$P — skipped (in SKIP_IDS)"
        [ "$kind" = ct ] && guest_health "$kind" "$id" "$P"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)); return
    fi
    lock=$(awk '/^lock:/{print $2}' <<<"$cfg")
    if [ -n "$lock" ]; then
        warn "$P — skipped (locked: $lock)"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)); return
    fi
    if [ "$kind" = vm ]; then
        if ! grep -qE '^agent:[[:space:]]*(1|enabled=1)' <<<"$cfg" \
            || ! timeout 15 qm guest cmd "$id" ping </dev/null >/dev/null 2>&1; then
            info "$P — skipped (QEMU guest agent not enabled or not responding; install qemu-guest-agent to have it updated)"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)); return
        fi
    fi
    process_guest "$kind" "$id" "$name"
}

# ── INVENTORY (guests seen between runs) ──────────────────────────────
# One line per guest in $STATE_DIR/inventory.tsv:
#   type  id  name  status  tags  first-seen  last-seen
# The format matches the old proxmox-stack-maintainer inventory, which is
# imported on the first run so existing guests aren't reported as new.
declare -A INV_NAME INV_STATUS INV_FIRST INV_LAST INV_SEEN
INV_LINES=(); INV_HAD_PREV=0; INV_IMPORTED=0

inventory_load() {
    local src="$INV_FILE" type id name status tags first last
    if [ ! -f "$src" ] && [ -f "$LEGACY_INV_FILE" ]; then src=$LEGACY_INV_FILE; INV_IMPORTED=1; fi
    [ -f "$src" ] || return 0
    INV_HAD_PREV=1
    local line
    while IFS= read -r line; do
        # Tabs count as whitespace to read(), so empty fields would collapse; split on \x1f instead
        IFS=$'\x1f' read -r type id name status tags first last <<<"${line//$'\t'/$'\x1f'}"
        [ -n "$type" ] && [ -n "$id" ] || continue
        INV_NAME[$type:$id]=$name; INV_STATUS[$type:$id]=$status
        INV_FIRST[$type:$id]=$first; INV_LAST[$type:$id]=$last
    done < "$src"
}

inventory_record() {
    local kind=$1 id=$2 name=$3 status=$4 tags=$5 type now first label k
    type=lxc; label=Container
    [ "$kind" = vm ] && { type=vm; label=VM; }
    k="$type:$id"; now=$(date '+%Y-%m-%d %H:%M:%S')
    name=${name//$'\t'/ }; tags=${tags//$'\t'/ }
    if [ -z "${INV_NAME[$k]+set}" ]; then
        first=$now
        [ "$INV_HAD_PREV" = 1 ] && info "NEW $label: [$id] $name (status: $status)"
    else
        first=${INV_FIRST[$k]}
        [ "${INV_NAME[$k]}" != "$name" ] && info "$label renamed: [$id] ${INV_NAME[$k]} → $name"
        [ "${INV_STATUS[$k]}" != "$status" ] && info "$label status changed: [$id] $name (${INV_STATUS[$k]} → $status)"
    fi
    INV_SEEN[$k]=1
    INV_LINES+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$type" "$id" "$name" "$status" "$tags" "$first" "$now")")
}

inventory_finish() {
    local k type label tmp
    [ -n "$ONLY_IDS" ] && return 0     # a partial run says nothing about the rest
    title "INVENTORY"
    for k in "${!INV_NAME[@]}"; do
        if [ -z "${INV_SEEN[$k]+set}" ]; then
            type=${k%%:*}; label=Container; [ "$type" = vm ] && label=VM
            info "REMOVED $label: [${k#*:}] ${INV_NAME[$k]} (last status: ${INV_STATUS[$k]}, last seen: ${INV_LAST[$k]})"
        fi
    done
    [ "$INV_HAD_PREV" = 0 ] && info "First inventory: recording ${#INV_LINES[@]} guest(s)"
    [ "$INV_IMPORTED" = 1 ] && info "Imported the previous inventory from proxmox-stack-maintainer"
    ok "${#INV_LINES[@]} guest(s) on this host"
    [ "$DRY_RUN" = 1 ] && return 0
    mkdir -p "$STATE_DIR"
    tmp=$(mktemp "$STATE_DIR/inventory.XXXXXX") || return 0
    printf '%s\n' "${INV_LINES[@]}" | sort -t $'\t' -k1,1 -k2,2n > "$tmp" && mv "$tmp" "$INV_FILE"
}

# ── SERVICE CHECKS (web pages that must respond after the run) ────────
service_checks() {
    local entry name url code t
    [ ${#SVC_LIST[@]} -gt 0 ] || return 0
    title "SERVICE CHECKS"
    for entry in "${SVC_LIST[@]}"; do
        name=${entry%%=*}; url=${entry#*=}
        if [ "$name" = "$entry" ] || [ -z "$name" ] || [ -z "$url" ]; then
            warn "Service check '$entry' ignored: write it as Name=URL"; continue
        fi
        for (( t = 1; t <= SERVICE_CHECK_TRIES; t++ )); do
            code=$(curl -sk -L -o /dev/null -m "$SERVICE_CHECK_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null)
            [[ "$code" =~ ^[23][0-9][0-9]$ ]] && break
            [ "$t" -lt "$SERVICE_CHECK_TRIES" ] && sleep 10
        done
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then ok "$name — responding (HTTP $code) at $url"
        else err "$name — not responding (HTTP ${code:-000}) at $url"; fi
    done
}

# ── HEALTH (disk, swap, out-of-memory kills) ──────────────────────────
# Docker's own "healthy" only says the app answers. A guest can look healthy
# while its disk fills, its swap is full or the kernel keeps killing
# processes for lack of memory, so those are checked separately.
declare -A OOM_PREV OOM_NOW

oom_load() {
    local id n
    [ -f "$OOM_FILE" ] || return 0
    while read -r id n; do
        [[ "$id" =~ ^[0-9]+$ ]] && [[ "$n" =~ ^[0-9]+$ ]] && OOM_PREV[$id]=$n
    done < "$OOM_FILE"
}

oom_save() {
    local id tmp
    [ "$DRY_RUN" = 1 ] && return 0
    [ ${#OOM_NOW[@]} -gt 0 ] || return 0
    for id in "${!OOM_NOW[@]}"; do OOM_PREV[$id]=${OOM_NOW[$id]}; done
    mkdir -p "$STATE_DIR"
    tmp=$(mktemp "$STATE_DIR/oom.XXXXXX") || return 0
    for id in "${!OOM_PREV[@]}"; do printf '%s %s\n' "$id" "${OOM_PREV[$id]}"; done | sort -n > "$tmp" && mv "$tmp" "$OOM_FILE"
}

guest_health() {
    local kind=$1 id=$2 P=$3 out size free pct st su ma spct="" kills prev new since bad=0
    [ "$HEALTH_CHECKS" = 1 ] || return 0
    if ! out=$(guest_run "$kind" "$id" "$S_HEALTH"); then
        warn "$P — health check could not run"; return
    fi
    size=$(getval DISKSIZE "$out"); free=$(getval DISKFREE "$out"); pct=$(getval DISKPCT "$out")
    st=$(getval SWAPTOTAL "$out"); su=$(getval SWAPUSED "$out"); ma=$(getval MEMAVAIL "$out")

    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if [ "$pct" -ge "$DISK_ERR_PCT" ]; then
            err "$P — disk ${pct}% full (${free} MB free of ${size} MB). Free space or grow the disk"; bad=1
        elif [ "$pct" -ge "$DISK_WARN_PCT" ]; then
            warn "$P — disk ${pct}% full (${free} MB free of ${size} MB)"; bad=1
        fi
    fi
    if [[ "$st" =~ ^[0-9]+$ ]] && [[ "$su" =~ ^[0-9]+$ ]] && [ "$st" -gt 0 ]; then
        spct=$(( su * 100 / st ))
        if [ "$spct" -ge "$SWAP_WARN_PCT" ]; then
            warn "$P — swap ${spct}% full (${su} of ${st} MB): it is short of memory, or something is leaking"; bad=1
        fi
    fi
    if [ "$kind" = ct ] && [ -r "$CGROUP_LXC_ROOT/$id/memory.events" ]; then
        kills=$(awk '$1=="oom_kill"{print $2}' "$CGROUP_LXC_ROOT/$id/memory.events")
        if [[ "$kills" =~ ^[0-9]+$ ]]; then
            prev=${OOM_PREV[$id]:-}
            if [ -z "$prev" ]; then new=$kills; since="since the container started"
            elif [ "$kills" -lt "$prev" ]; then new=$kills; since="since the container restarted"
            else new=$(( kills - prev )); since="since the last run"; fi
            OOM_NOW[$id]=$kills
            if [ "$new" -gt 0 ]; then
                warn "$P — $new process(es) killed for running out of memory $since: give it more memory or swap, or restart what is leaking"; bad=1
            fi
        fi
    fi
    if [ "$bad" = 0 ]; then
        ok "$P — health: disk ${pct:-?}% used, swap ${spct:-0}% used, ${ma:-?} MB memory available"
    fi
}

# ── HOST ──────────────────────────────────────────────────────────────
is_pve_pkg() {
    [[ "$1" =~ (pve|proxmox|^linux-(image|headers)|kernel|^qemu|^lxc|corosync|ceph|zfs|zpool|knet) ]]
}

# A package run holding the lock for hours is stuck, not busy: say so and skip
stuck_lock_check() {
    local f p age
    command -v fuser >/dev/null 2>&1 || return 0
    for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock; do
        for p in $(fuser "$f" 2>/dev/null); do
            age=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')
            if [[ "$age" =~ ^[0-9]+$ ]] && [ "$age" -gt 21600 ]; then
                err "HOST — the package lock has been held for $((age / 3600)) hours by PID $p ($(ps -o args= -p "$p" 2>/dev/null)). It looks stuck, so host updates were skipped. Find out what it is waiting for before stopping it"
                return 1
            fi
        done
    done
    return 0
}

host_update() {
    local out rc all=() pve=() other=() p
    title "PROXMOX HOST — $(hostname)"
    if [ "$HOST_MODE" = off ]; then info "HOST — updates turned off (HOST_MODE=off)"; return; fi
    export DEBIAN_FRONTEND=noninteractive
    stuck_lock_check || return
    [ "$DRY_RUN" = 1 ] || dpkg --configure -a >/dev/null 2>&1 </dev/null

    if ! out=$(apt-get -o DPkg::Lock::Timeout="$APT_LOCK_WAIT" update -q 2>&1 </dev/null); then
        err "HOST — apt-get update failed"; relay "HOST —" "$(tail -n 5 <<<"$out")"; return
    fi
    while IFS= read -r p; do [ -n "$p" ] && warn "HOST — apt: $p"; done < <(grep -E '^(W|E):' <<<"$out" | head -n 5)

    mapfile -t all < <(apt-get -s dist-upgrade 2>/dev/null </dev/null | awk '/^Inst /{print $2}')
    for p in "${all[@]}"; do
        if is_pve_pkg "$p"; then pve+=("$p"); else other+=("$p"); fi
    done

    if [ "$HOST_MODE" = full ]; then
        if [ ${#all[@]} -eq 0 ]; then ok "HOST — up to date"; return; fi
        info "HOST — ${#all[@]} package(s) to upgrade: ${all[*]}"
        if [ "$DRY_RUN" = 1 ]; then info "HOST — DRY RUN: not upgrading"; return; fi
        out=$(apt-get -y -q -o DPkg::Lock::Timeout="$APT_LOCK_WAIT" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade 2>&1 </dev/null); rc=$?
        relay "HOST —" "$(tail -n 15 <<<"$out")"
        if [ $rc -eq 0 ]; then ok "HOST — upgraded ${#all[@]} package(s)"
        else err "HOST — upgrade failed (exit $rc)"; fi
        return
    fi

    # safe mode
    if [ ${#pve[@]} -gt 0 ]; then
        warn "HOST — ${#pve[@]} Proxmox/kernel package(s) waiting, not installed in safe mode: ${pve[*]}"
        warn "HOST — install them with 'apt full-upgrade' when you can reboot, or set HOST_MODE=full"
    fi
    if [ ${#other[@]} -eq 0 ]; then ok "HOST — Debian packages up to date"; return; fi
    # Keep only packages whose upgrade doesn't drag in Proxmox packages
    local safe=() held=()
    for p in "${other[@]}"; do
        if pulls_pve "$p"; then held+=("$p"); else safe+=("$p"); fi
    done
    if [ ${#held[@]} -gt 0 ]; then
        warn "HOST — ${#held[@]} Debian package(s) left for 'apt full-upgrade' because they also need Proxmox packages: ${held[*]}"
    fi
    if [ ${#safe[@]} -gt 0 ] && pulls_pve "${safe[@]}"; then
        warn "HOST — together the remaining upgrades would change Proxmox packages, so none were installed; run 'apt full-upgrade' when you can"
        return
    fi
    if [ ${#safe[@]} -eq 0 ]; then return; fi
    info "HOST — ${#safe[@]} Debian package(s) to upgrade: ${safe[*]}"
    if [ "$DRY_RUN" = 1 ]; then info "HOST — DRY RUN: not upgrading"; return; fi
    out=$(apt-get -y -q -o DPkg::Lock::Timeout="$APT_LOCK_WAIT" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install --only-upgrade "${safe[@]}" 2>&1 </dev/null); rc=$?
    relay "HOST —" "$(tail -n 15 <<<"$out")"
    if [ $rc -eq 0 ]; then ok "HOST — upgraded ${#safe[@]} Debian package(s)"
    else err "HOST — upgrade failed (exit $rc)"; fi
}

# True if upgrading the given packages would also install or upgrade a Proxmox package
pulls_pve() {
    local p
    while IFS= read -r p; do is_pve_pkg "$p" && return 0; done < <(
        apt-get -s install --only-upgrade "$@" 2>/dev/null </dev/null | awk '/^Inst /{print $2}')
    return 1
}

host_reboot_check() {
    local running newest
    title "HOST — restart check"
    running=$(uname -r)
    newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n 1)
    if [ -f /var/run/reboot-required ]; then
        warn "HOST — reboot required by: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)"
    elif [ -n "$newest" ] && [ "$newest" != "$running" ]; then
        warn "HOST — running kernel $running, newest installed $newest: reboot to use it"
    else
        ok "HOST — no reboot needed"
    fi
    info "HOST — ProxSweep never reboots the host. Guests with Start at boot come back on their own."
}

# ── MAIN ──────────────────────────────────────────────────────────────
log ""
log "============================================================"
log "  ProxSweep $PROXSWEEP_VERSION — Proxmox stack updater"
log "  Host : $(hostname)    Date : $(date)"
[ "$DRY_RUN" = 1 ] && log "  DRY RUN — nothing will be changed"
log "============================================================"

inventory_load
oom_load
host_update

mapfile -t CT_IDS < <(pct list 2>/dev/null </dev/null | awk 'NR>1{print $1}')
for id in "${CT_IDS[@]}"; do consider_guest ct "$id"; done

if [ "$UPDATE_VMS" = 1 ]; then
    mapfile -t VM_IDS < <(qm list 2>/dev/null </dev/null | awk 'NR>1{print $1}')
    for id in "${VM_IDS[@]}"; do consider_guest vm "$id"; done
elif [ -n "$VM_NOTE" ]; then
    warn "$VM_NOTE"
fi

service_checks
inventory_finish
oom_save
host_reboot_check

log ""
log "============================================================"
if [ "$DRY_RUN" = 1 ]; then UPD_LABEL="with package updates waiting"; else UPD_LABEL="had package updates"; fi
SUMMARY="$TOTAL_CHECKED guests checked | $TOTAL_WITH_UPDATES $UPD_LABEL | $TOTAL_SKIPPED skipped | $TOTAL_WARNINGS warnings"
if [ "$TOTAL_ERRORS" -gt 0 ]; then
    log "${RED}  RESULT: $SUMMARY | $TOTAL_ERRORS ERROR(S)${NC}"
else
    log "${GRN}  RESULT: $SUMMARY | 0 errors${NC}"
fi
log "  Log saved to: $LOG_FILE"
log "============================================================"

find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null
[ "$TOTAL_ERRORS" -eq 0 ]
