#!/usr/bin/env bash
# prune-cache.sh — keep Zig build caches from eating the disk.
#
# Zig never garbage-collects its cache: every distinct compile lands in
# <cache>/o/<hash>/ and stays there forever. On an active repo (several
# agents + editors rebuilding constantly) that grows to 100GB+ of stale
# test binaries and objects.
#
# This prunes least-recently-used hash dirs down to a size cap, keeping
# anything written recently (so an in-flight or concurrent build never
# loses files out from under it). Cache entries are content-addressed:
# deleting one only costs a rebuild on next use, never correctness.
#
# Usage:
#   tools/prune-cache.sh [--cache-dir DIR]... [--max-gb N] [--min-age-minutes N]
#                        [--dry-run] [--verbose] [--install-timer]
#
# Defaults: --cache-dir ./.zig-cache (must exist), --max-gb 20,
# --min-age-minutes 120.
#
# Examples:
#   tools/prune-cache.sh --dry-run            # show what would go, change nothing
#   tools/prune-cache.sh                      # enforce 20G cap on ./.zig-cache
#   tools/prune-cache.sh --cache-dir ~/.cache/zig --max-gb 5
#   tools/prune-cache.sh --install-timer      # weekly systemd user timer
#
# Cron alternative (weekly, quiet unless something was freed):
#   0 4 * * 0 /path/to/repo/tools/prune-cache.sh --max-gb 20 >/dev/null 2>&1

set -u

CACHE_DIRS=()
MAX_GB=20
MIN_AGE_MIN=120
DRY_RUN=0
VERBOSE=0
INSTALL_TIMER=0

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cache-dir) CACHE_DIRS+=("$2"); shift 2 ;;
        --cache-dir=*) CACHE_DIRS+=("${1#*=}"); shift ;;
        --max-gb) MAX_GB="$2"; shift 2 ;;
        --max-gb=*) MAX_GB="${1#*=}"; shift ;;
        --min-age-minutes) MIN_AGE_MIN="$2"; shift 2 ;;
        --min-age-minutes=*) MIN_AGE_MIN="${1#*=}"; shift ;;
        --global) CACHE_DIRS+=("$HOME/.cache/zig"); shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        --install-timer) INSTALL_TIMER=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
    esac
done

if [ ${#CACHE_DIRS[@]} -eq 0 ]; then
    if [ -d "./.zig-cache" ]; then
        CACHE_DIRS=("./.zig-cache")
    else
        echo "no ./.zig-cache here; pass --cache-dir DIR" >&2
        exit 1
    fi
fi

case "$MAX_GB" in ''|*[!0-9]*) echo "--max-gb must be a non-negative integer" >&2; exit 1;; esac
case "$MIN_AGE_MIN" in ''|*[!0-9]*) echo "--min-age-minutes must be a non-negative integer" >&2; exit 1;; esac

now=$(date +%s)
guard_epoch=$(( now - MIN_AGE_MIN * 60 ))
cap_kb=$(( MAX_GB * 1024 * 1024 ))

debug() { [ "$VERBOSE" = 1 ] && echo "prune-cache: [debug] $1"; }

install_timer() {
    if ! command -v systemctl >/dev/null; then
        echo "systemctl not found; skipping timer install" >&2
        return 1
    fi
    unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"
    repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
    cat > "$unit_dir/zig-prune-cache.service" <<EOF
[Unit]
Description=Prune Zig build caches (size cap)

[Service]
Type=oneshot
ExecStart=$repo_dir/tools/prune-cache.sh --max-gb $MAX_GB --min-age-minutes 1440
Nice=19
IOSchedulingClass=idle
EOF
    cat > "$unit_dir/zig-prune-cache.timer" <<EOF
[Unit]
Description=Weekly Zig build cache prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now zig-prune-cache.timer
    echo "installed weekly timer (zig-prune-cache.timer)"
}

if [ "$INSTALL_TIMER" = 1 ]; then
    install_timer
fi

grand_freed_kb=0
grand_kept_dirs=0
grand_removed_dirs=0

for cache in "${CACHE_DIRS[@]}"; do
    if [ ! -d "$cache" ]; then
        echo "prune-cache: skip missing dir: $cache"
        continue
    fi
    o_dir="$cache/o"
    if [ ! -d "$o_dir" ]; then
        echo "prune-cache: no o/ in $cache, nothing to do"
        continue
    fi
    # Serialize concurrent pruners (not builds: builds only ever need
    # entries newer than the min-age guard, which we never delete).
    exec {lockfd}>"$cache/.prune.lock"
    if ! flock -n "$lockfd"; then
        echo "prune-cache: another pruner holds $cache, skipping"
        exec {lockfd}>&-
        continue
    fi

    # One pass for sizes (du), one for mtimes (find, maxdepth 1 = the hash
    # dirs themselves; dir mtime == artifact write time since each entry
    # is written once and only read afterwards).
    tmp_list="$(mktemp)"
    # du output: "<kb>\t<path>/". Re-emit "<kb> <path-without-trailing-slash>".
    du -sk -- "$o_dir"/*/ 2>/dev/null | while IFS= read -r line; do
        kb=${line%%[[:space:]]*}
        p=${line#*[[:space:]]}
        p=${p%/}
        printf '%s %s\n' "$kb" "$p"
    done > "$tmp_list" || true
    find "$o_dir" -mindepth 1 -maxdepth 1 -printf '%T@ %p\n' 2>/dev/null > "$tmp_list.mtimes" || true

    total_kb=$(awk '{s+=$1} END {print s+0}' "$tmp_list")
    echo "prune-cache: $cache/o: ${total_kb} KiB in $(wc -l < "$tmp_list") entries (cap ${cap_kb} KiB, min-age ${MIN_AGE_MIN}m)"

    if [ "$total_kb" -le "$cap_kb" ]; then
        echo "prune-cache: under cap, nothing to remove"
    else
        # Pair sizes with mtimes (both keyed by hash-dir path), oldest
        # first; delete oldest-until-under-cap, never touching anything
        # newer than the guard. Hash-dir names are hex, so whitespace
        # splitting is safe here.
        removed_kb=0
        removed_n=0
        while IFS= read -r line; do
            mtime=${line%% *}; rest=${line#* }
            kb=${rest%% *}; path=${rest#* }
            mtime_int=${mtime%%.*}
            if [ "$mtime_int" -ge "$guard_epoch" ]; then
                continue
            fi
            if [ "$DRY_RUN" = 1 ]; then
                echo "prune-cache: [dry-run] would remove $path (${kb} KiB, age $(( (now - mtime_int) / 60 ))m)"
            else
                rm -rf -- "$path" || { echo "prune-cache: failed to remove $path" >&2; continue; }
            fi
            removed_kb=$((removed_kb + kb))
            removed_n=$((removed_n + 1))
            if [ $((total_kb - removed_kb)) -le "$cap_kb" ]; then
                break
            fi
        done < <(awk 'NR==FNR {mt[$2]=$1; next} ($2 in mt) {print mt[$2]" "$1" "$2}' "$tmp_list.mtimes" "$tmp_list" | sort -n)
        # Recompute (rm may have raced a concurrent build writing nearby).
        if [ "$DRY_RUN" = 1 ]; then
            echo "prune-cache: [dry-run] would free ${removed_kb} KiB in ${removed_n} entries"
        else
            new_total_kb=$(du -sk "$o_dir" 2>/dev/null | awk '{print $1}')
            freed_kb=$((total_kb - new_total_kb))
            echo "prune-cache: removed ${removed_n} entries, freed ${freed_kb} KiB (now ${new_total_kb} KiB)"
            grand_freed_kb=$((grand_freed_kb + freed_kb))
            grand_removed_dirs=$((grand_removed_dirs + removed_n))
        fi
    fi
    rm -f "$tmp_list" "$tmp_list.mtimes"

    # Stale temp files from killed builds: cheap, always safe past the guard.
    tmp_n=0
    if [ -d "$cache/tmp" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            tmp_n=$(find "$cache/tmp" -mindepth 1 -mmin +"$MIN_AGE_MIN" 2>/dev/null | wc -l)
            [ "$tmp_n" -gt 0 ] && echo "prune-cache: [dry-run] would remove ${tmp_n} stale tmp entries"
        else
            tmp_n=$(find "$cache/tmp" -mindepth 1 -mmin +"$MIN_AGE_MIN" -delete -print 2>/dev/null | wc -l)
            [ "$tmp_n" -gt 0 ] && echo "prune-cache: removed ${tmp_n} stale tmp entries"
        fi
    fi
    grand_kept_dirs=$((grand_kept_dirs + $(find "$o_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)))
    exec {lockfd}>&-
done

if [ "$DRY_RUN" = 1 ]; then
    echo "prune-cache: dry run complete (nothing changed)"
else
    echo "prune-cache: done: removed ${grand_removed_dirs} entries (${grand_freed_kb} KiB freed)"
fi
