#!/usr/bin/env bash
#
# nvme-write-monitor.sh
#
# Monitor NVMe "Data Units Written" SMART counter.
#
# Default behavior:
#   - Logs immediately on startup.
#   - Logs again every INTERVAL seconds.
#   - Can be forced to log immediately by writing a newline to the wake FIFO:
#
#       printf '\n' > "${XDG_RUNTIME_DIR:-/tmp}/nvme-write-monitor-${UID}/wake"
#
#       printf '\n' > /tmp/nvme-write-monitor-$(id -u)/wake
#       printf '\n' > /run/user/$(id -u)/nvme-write-monitor-$(id -u)/wake   --> use this when launching from terminal
#
# Optional environment overrides:
#
#   NVME_DEVICE       Device to query.
#                     Default: /dev/nvme0n1
#
#   NVME_BIN          Full path to nvme CLI.
#                     Default: /usr/bin/nvme
#
#   NVME_LOGFILE      Log file location.
#                     Default: /mnt/Fedora/nvme_writes.log
#
#   NVME_INTERVAL     Sample interval in seconds.
#                     Default: 300
#
#   NVME_SMART_TIMEOUT
#                     Timeout for the nvme smart-log command.
#                     Default: 10
#
set -u -o pipefail

# Predictable numeric and text formatting.
export LC_ALL=C

DEVICE="${NVME_DEVICE:-/dev/nvme0n1}"
NVME_BIN="${NVME_BIN:-/usr/bin/nvme}"
LOGFILE="${NVME_LOGFILE:-/mnt/RED2TB/Download_Fedora/nvme_writes_v2.log}"
INTERVAL="${NVME_INTERVAL:-300}"
SMART_TIMEOUT="${NVME_SMART_TIMEOUT:-10}"

# Each NVMe data unit is 512,000 bytes.
# 1 GiB = 1024^3 = 1,073,741,824 bytes.
BYTES_PER_UNIT=512000
BYTES_PER_GIB=1073741824

# Use a private runtime directory where possible.
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
FIFO_DIR="$RUNTIME_DIR/nvme-write-monitor-${UID}"
WAKE_FIFO="$FIFO_DIR/wake"
LOCKFILE="$FIFO_DIR/monitor.lock"

previous_units=""

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

# Validate interval.
if ! [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Invalid INTERVAL "%s"; using 300.\n' "$INTERVAL" >&2
    INTERVAL=300
fi

# Make sure the log location is usable.
LOGDIR=$(dirname -- "$LOGFILE")

if [[ ! -d "$LOGDIR" ]]; then
    die "Log directory does not exist: $LOGDIR"
fi

if ! touch "$LOGFILE" 2>/dev/null; then
    die "Cannot write to log file: $LOGFILE"
fi

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"
}

# Check required commands.
for cmd in awk date dirname flock mkfifo sudo timeout; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Required command not found: $cmd"
    fi
done

# Private runtime files.
umask 077

if [[ -L "$FIFO_DIR" ]]; then
    die "Refusing to use symlinked FIFO directory: $FIFO_DIR"
fi

if [[ -e "$FIFO_DIR" && ! -d "$FIFO_DIR" ]]; then
    die "FIFO path exists but is not a directory: $FIFO_DIR"
fi

if ! mkdir -p "$FIFO_DIR"; then
    die "Failed to create FIFO directory: $FIFO_DIR"
fi

if ! chmod 700 "$FIFO_DIR"; then
    die "Failed to set FIFO directory permissions: $FIFO_DIR"
fi

# Prevent multiple instances.
#
# The lock file is intentionally left in place. With flock, the lock is
# associated with the open file descriptor and is released when the process
# exits.
exec 9>>"$LOCKFILE" || die "Failed to open lock file: $LOCKFILE"

if ! flock -n 9; then
    die "NVMe monitor is already running."
fi

# Create or validate the wake-up FIFO.
if [[ -L "$WAKE_FIFO" ]]; then
    die "Refusing to use symlinked wake FIFO: $WAKE_FIFO"
fi

if [[ -e "$WAKE_FIFO" && ! -p "$WAKE_FIFO" ]]; then
    die "Wake path exists but is not a FIFO: $WAKE_FIFO"
fi

if [[ ! -p "$WAKE_FIFO" ]]; then
    if ! mkfifo -m 600 "$WAKE_FIFO"; then
        die "Failed to create FIFO: $WAKE_FIFO"
    fi
fi

chmod 600 "$WAKE_FIFO" 2>/dev/null || true

# Open the FIFO read/write so opening it does not block waiting for a writer.
exec 3<>"$WAKE_FIFO" || die "Failed to open wake FIFO: $WAKE_FIFO"

cleanup() {
    local code="${1:-0}"

    trap - INT TERM

    log "Monitor stopped."

    # Close wake FIFO descriptor.
    exec 3>&- 2>/dev/null || true

    exit "$code"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# Ignore SIGHUP so the monitor survives terminal close/logout.
#
# If you prefer SIGHUP to stop the monitor, replace the next line with:
#
#   trap 'cleanup 129' HUP
#
trap '' HUP

get_data_units_written() {
    # Close FD 3 and FD 9 for the child process so the wake FIFO and lock
    # descriptor are not unnecessarily inherited.
    timeout "$SMART_TIMEOUT" sudo -n "$NVME_BIN" smart-log "$DEVICE" \
        2>/dev/null 3>&- 9>&- |
    awk '
        {
            line = tolower($0)
            if (line ~ /data units written/) {
                sub(/^.*data units written[[:space:]]*:[[:space:]]*/, "", line)
                sub(/[[:space:]].*$/, "", line)
                gsub(/,/, "", line)
                sub(/^0+/, "", line)
                if (line == "") line = 0
                if (line ~ /^[0-9]+$/) print line
                exit
            }
        }
    '
}

units_to_gib() {
    awk -v units="$1" -v bytes_per_unit="$BYTES_PER_UNIT" -v bytes_per_gib="$BYTES_PER_GIB" '
        BEGIN {
            printf "%.4f", units * bytes_per_unit / bytes_per_gib
        }
    '
}

sample_once() {
    local timestamp current_units current_gib delta_units delta_gib

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    current_units=$(get_data_units_written || true)

    if [[ "$current_units" =~ ^[0-9]+$ ]]; then
        current_gib=$(units_to_gib "$current_units")

        if [[ -n "$previous_units" ]]; then
            if (( current_units >= previous_units )); then
                delta_units=$((current_units - previous_units))
            else
                # This can happen if the counter is reset, cleared, or wraps.
                delta_units="$current_units"
                log "WARNING: Data Units Written counter decreased; assuming reset/wrap."
            fi

            delta_gib=$(units_to_gib "$delta_units")

            printf '%s total=%s units (%s GiB) delta=%s units (%s GiB)\n' \
                "$timestamp" \
                "$current_units" \
                "$current_gib" \
                "$delta_units" \
                "$delta_gib" >> "$LOGFILE"
        else
            printf '%s total=%s units (%s GiB) delta=N/A (first sample)\n' \
                "$timestamp" \
                "$current_units" \
                "$current_gib" >> "$LOGFILE"
        fi

        previous_units="$current_units"
    else
        log "ERROR: Failed to read NVMe SMART data from $DEVICE."
    fi
}

# Compare the inode FD 3 is bound to against the inode currently at
# WAKE_FIFO. Returns 0 (valid) / 1 (needs reopen).
#
# Handles three cases:
#   1. Path deleted, not recreated        -> stat of path fails.
#   2. Path deleted and recreated         -> inode mismatch.
#   3. Path replaced with non-FIFO          -> -p test fails.
#
# Linux-specific (/proc fd symlinks). On systems without this layout,
# this returns failure and the caller falls back.
wake_fd_is_live() {
    local path_ino fd_ino

    [[ -p "$WAKE_FIFO" ]] || return 1

    path_ino=$(stat -c %i -- "$WAKE_FIFO" 2>/dev/null) || return 1
    fd_ino=$(stat -Lc %i -- "/proc/$$/fd/3" 2>/dev/null) || return 1

    [[ "$path_ino" == "$fd_ino" ]]
}

# Swap in a fresh FD 3 for the current FIFO, keeping the loop running
# even if the swap fails.
refresh_wake_fifo() {
    if wake_fd_is_live; then
        return 0
    fi

    log "WARNING: Wake FIFO no longer matches FD 3 ($WAKE_FIFO); recreating."

    # Drop the stale FD 3 (it points at an unlinked inode or a removed
    # path; nothing can reach it anyway).
    exec 3>&- 2>/dev/null || true

    if [[ -e "$WAKE_FIFO" && ! -p "$WAKE_FIFO" ]]; then
        log "ERROR: Wake path exists but is not a FIFO: $WAKE_FIFO"
        return 1
    fi

    if [[ ! -p "$WAKE_FIFO" ]]; then
        if ! mkfifo -m 600 "$WAKE_FIFO" 2>/dev/null; then
            log "ERROR: Failed to recreate wake FIFO: $WAKE_FIFO"
            return 1
        fi
    fi

    chmod 600 "$WAKE_FIFO" 2>/dev/null || true

    if ! exec 3<>"$WAKE_FIFO"; then
        log "ERROR: Failed to reopen wake FIFO: $WAKE_FIFO"
        return 1
    fi

    log "INFO: Wake FIFO recreated successfully."
}

reopen_wake_fifo() {
    # If the FIFO file was deleted or replaced with a non-FIFO,
    # we must close FD 3 first so we can safely recreate it.
    if [[ -e "$WAKE_FIFO" && ! -p "$WAKE_FIFO" ]]; then
        log "ERROR: Wake path exists but is not a FIFO: $WAKE_FIFO"
        return 1
    fi

    if [[ ! -p "$WAKE_FIFO" ]]; then
        exec 3>&- 2>/dev/null || true
        if ! mkfifo -m 600 "$WAKE_FIFO" 2>/dev/null; then
            log "ERROR: Failed to recreate wake FIFO: $WAKE_FIFO"
            return 1
        fi
        chmod 600 "$WAKE_FIFO" 2>/dev/null || true
    fi

    # Open the FIFO on temporary file descriptor 4 first.
    # Because FD 3 is still open (if it was valid), there is never a
    # moment where the FIFO has zero readers.
    if ! exec 4<>"$WAKE_FIFO"; then
        log "ERROR: Failed to open wake FIFO on temporary descriptor: $WAKE_FIFO"
        return 1
    fi

    # Atomically move FD 4 to FD 3 and close FD 4.
    exec 3<&4 4>&-
}

log "Monitor started for $DEVICE (interval=${INTERVAL}s)."

while true; do
    sample_once

    # Wait for either:
    #
    #   1. A wake-up line written to the FIFO.
    #   2. The normal interval timeout.
    #
    # This read is from FD 3, not the terminal, so it will not cause the
    # background job to receive SIGTTIN and become Stopped.
    if IFS= read -r -t "$INTERVAL" -u 3 _ 2>/dev/null; then
        # Wake-up received; immediately begin the next sample.
        #
        # If you want to coalesce multiple pending wake-up events into one
        # immediate sample, uncomment the following block:
        #
        # while IFS= read -r -t 0 -u 3; do
        #     IFS= read -r -u 3 _
        # done
        :
    else
        status=$?

        # Bash read -t timeouts return a status >= 128.
        # EOF/FD errors are normally lower than 128.
        if (( status >= 128 )); then
            # Normal timeout: verify the FIFO is still the one we hold.
            refresh_wake_fifo || sleep "$INTERVAL"
        else
            log "WARNING: Wake FIFO read returned status $status; reopening FIFO."
            sleep 1

            if ! reopen_wake_fifo; then
                # If the FIFO cannot be reopened, fall back to ordinary sleeping
                # so the script does not spin in a tight loop.
                sleep "$INTERVAL"
            fi
        fi
    fi
done
