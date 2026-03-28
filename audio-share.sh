#!/usr/bin/env bash
#
# audio-share.sh — PipeWire virtual sink for sharing application audio
#
# Creates a null sink and routes application audio streams into it so that
# capture software (Sunshine, OBS, etc.) can read the sink's monitor ports.
#
# The default audio output device continues to receive all audio unless
# --mute-local is passed, in which case captured streams are moved
# exclusively to the virtual sink.
#
# Multiple instances can run simultaneously with different sink names.
# Each instance is tracked via a PID file so they can be listed, stopped,
# and stale sinks from crashed instances are automatically recovered.
#
# Requires: pw-link  pw-dump  pactl  jq  (all part of a standard PipeWire
#           + PipeWire-Pulse + pipewire-tools install)
#
# SPDX-License-Identifier: MIT

set -euo pipefail

# ─── defaults ────────────────────────────────────────────────────────────────

SINK_NAME="audio_share"
SINK_DESCRIPTION="Audio Share"
AUTO_CAPTURE=true
MUTE_LOCAL=false
POLL_INTERVAL=2
VERBOSE=false
declare -a WHITELIST=()
declare -a BLACKLIST=()

# ─── runtime state ───────────────────────────────────────────────────────────

MODULE_ID=""
STARTUP_DEFAULT_SINK=""      # captured once; used only as a last resort
CLEANUP_DONE=false
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/audio-share"
declare -A CAPTURED=()          # node_name → "1"  (streams we are managing)
declare -A SKIPPED=()           # node_name → "1"  (streams we skipped, e.g. peer-owned)
declare -A MOVED_INPUTS=()      # pactl_index → original_sink  (for mute-local restore)

# ─── colours / logging ──────────────────────────────────────────────────────

if [[ -t 2 ]]; then
    _R='\033[0;31m' _G='\033[0;32m' _Y='\033[1;33m' _C='\033[0;36m'
    _B='\033[1m' _D='\033[2m' _N='\033[0m'
else
    _R='' _G='' _Y='' _C='' _B='' _D='' _N=''
fi

_ts()   { date +%H:%M:%S; }
_tag()  { printf '%b%s%b' "$_D" "$SINK_NAME" "$_N"; }
log()   { printf '%b[%s]%b %b(%s)%b %s\n' "$_G" "$(_ts)" "$_N" "$_D" "$SINK_NAME" "$_N" "$*" >&2; }
warn()  { printf '%b[%s] WARN:%b %b(%s)%b %s\n' "$_Y" "$(_ts)" "$_N" "$_D" "$SINK_NAME" "$_N" "$*" >&2; }
err()   { printf '%b[%s] ERROR:%b %b(%s)%b %s\n' "$_R" "$(_ts)" "$_N" "$_D" "$SINK_NAME" "$_N" "$*" >&2; }
debug() { [[ "$VERBOSE" == true ]] && printf '%b[%s] dbg:%b %b(%s)%b %s\n' "$_C" "$(_ts)" "$_N" "$_D" "$SINK_NAME" "$_N" "$*" >&2 || true; }

die() { err "$@"; exit 1; }

# ─── usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
audio-share — route application audio into a virtual PipeWire sink

USAGE
    audio-share.sh [OPTIONS]
    audio-share.sh --status
    audio-share.sh --stop NAME
    audio-share.sh --stop-all

OPTIONS
    -n, --sink-name NAME          PipeWire sink name         (default: audio_share)
    -d, --description DESC        Human-readable description (default: Audio Share)

    -a, --auto-capture            Capture new streams as they appear (default)
    -A, --no-auto-capture         Only capture streams present at start-up

    -w, --whitelist APPS          Comma-separated application patterns to capture
    -b, --blacklist APPS          Comma-separated application patterns to exclude
                                  (whitelist and blacklist are mutually exclusive)

    -m, --mute-local              Do NOT play captured audio on the default output
                                  (moves streams exclusively to the virtual sink)

    -p, --poll-interval SECS      How often to scan for changes (default: 2)
    -v, --verbose                 Print extra debug output
    -h, --help                    Show this help

MANAGEMENT
    --status                      List all running audio-share instances
    --stop NAME                   Stop the instance with the given sink name
    --stop-all                    Stop every running audio-share instance

MATCHING
    Patterns are matched case-insensitively as substrings against both the
    PipeWire node.name (e.g. "alsa_playback.firefox") and the application.name
    (e.g. "Firefox").  Partial matches work: --whitelist "fire" matches Firefox.

HOW IT WORKS
    1.  A module-null-sink is loaded, creating a virtual sink with playback
        (input) ports and monitor (output) ports.

    2.  For every matching audio stream, pw-link adds *additional* links from
        the stream's output ports to the virtual sink's playback ports.
        The existing WirePlumber-managed link to the default hardware sink is
        left in place, so you still hear the audio locally.

    3.  If --mute-local is given, each stream is instead *moved* to the
        virtual sink via `pactl move-sink-input`, which tells WirePlumber to
        route exclusively there.  On exit the streams are moved back.

    4.  Capture software (Sunshine, OBS, …) selects the virtual sink — or its
        monitor source — as its audio input.

MULTIPLE INSTANCES
    You can run several instances simultaneously with different --sink-name
    values and independent filter/mute options.  Each instance is tracked by
    a PID file in $XDG_RUNTIME_DIR/audio-share/.  Stale sinks left behind
    by a crashed instance are automatically cleaned up on the next start.

    When --mute-local is active, an instance will skip streams that are
    already owned by another running audio-share instance to prevent the
    two from fighting over the same sink-input.

EXAMPLES
    # share everything, keep local playback
    audio-share.sh

    # share only firefox and mpv
    audio-share.sh --whitelist "firefox,mpv"

    # share everything except notification sounds
    audio-share.sh --blacklist "notification,alert"

    # share everything, silence local speakers
    audio-share.sh --mute-local

    # multiple instances: one for Sunshine, one for Discord bot
    audio-share.sh -n sunshine_audio -d "Sunshine" --whitelist "firefox,mpv,steam" &
    audio-share.sh -n discord_audio  -d "Discord"  --whitelist "music-player" --mute-local &
    audio-share.sh --status
    audio-share.sh --stop sunshine_audio
    audio-share.sh --stop-all
EOF
}

# ─── argument parsing ────────────────────────────────────────────────────────

# Management sub-commands handled before full parse.
ACTION="run"   # run | status | stop | stop-all

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)            ACTION="status";          shift   ;;
            --stop)              ACTION="stop"; SINK_NAME="$2"; shift 2 ;;
            --stop-all)          ACTION="stop-all";        shift   ;;
            -n|--sink-name)      SINK_NAME="$2";           shift 2 ;;
            -d|--description)    SINK_DESCRIPTION="$2";    shift 2 ;;
            -a|--auto-capture)   AUTO_CAPTURE=true;         shift   ;;
            -A|--no-auto-capture) AUTO_CAPTURE=false;       shift   ;;
            -w|--whitelist)      IFS=',' read -ra WHITELIST <<< "$2"; shift 2 ;;
            -b|--blacklist)      IFS=',' read -ra BLACKLIST <<< "$2"; shift 2 ;;
            -m|--mute-local)     MUTE_LOCAL=true;           shift   ;;
            -p|--poll-interval)  POLL_INTERVAL="$2";        shift 2 ;;
            -v|--verbose)        VERBOSE=true;              shift   ;;
            -h|--help)           usage; exit 0 ;;
            *)                   die "Unknown option: $1 (try --help)" ;;
        esac
    done

    if [[ "$ACTION" == "run" ]]; then
        if (( ${#WHITELIST[@]} > 0 && ${#BLACKLIST[@]} > 0 )); then
            die "Cannot use --whitelist and --blacklist together"
        fi
    fi
}

# ─── dependency check ────────────────────────────────────────────────────────

check_deps() {
    local missing=()
    for cmd in pw-link pw-dump pactl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) || die "Missing required commands: ${missing[*]}"
}

# ─── PID-file / instance management ─────────────────────────────────────────

ensure_runtime_dir() {
    mkdir -p "$RUNTIME_DIR"
}

pid_file() {
    printf '%s/%s.pid' "$RUNTIME_DIR" "$SINK_NAME"
}

# Write PID:MODULE_ID to the lock file.
write_pid_file() {
    printf '%d:%s\n' "$$" "$MODULE_ID" > "$(pid_file)"
}

remove_pid_file() {
    rm -f "$(pid_file)"
}

# Read a PID file → sets _PF_PID and _PF_MODULE.
read_pid_file() {
    local file="$1"
    _PF_PID="" _PF_MODULE=""
    [[ -f "$file" ]] || return 1
    local content
    content=$(<"$file")
    _PF_PID="${content%%:*}"
    _PF_MODULE="${content#*:}"
    [[ -n "$_PF_PID" ]]
}

# Is the given PID alive?
pid_alive() {
    kill -0 "$1" 2>/dev/null
}

# Acquire instance lock for our SINK_NAME.  Handles stale recovery.
acquire_lock() {
    local pf
    pf=$(pid_file)

    if [[ -f "$pf" ]]; then
        if read_pid_file "$pf"; then
            if pid_alive "$_PF_PID"; then
                die "Sink '${SINK_NAME}' is already managed by PID ${_PF_PID}. Use a different --sink-name or run: $0 --stop ${SINK_NAME}"
            else
                warn "Found stale PID file for '${SINK_NAME}' (PID ${_PF_PID} is dead)"
                # Clean up the orphaned sink if possible
                if [[ -n "$_PF_MODULE" && "$_PF_MODULE" != "0" && "$_PF_MODULE" != "" ]]; then
                    log "Unloading orphaned module ${_PF_MODULE} from previous crash"
                    pactl unload-module "$_PF_MODULE" 2>/dev/null || true
                fi
                rm -f "$pf"
            fi
        else
            rm -f "$pf"
        fi
    fi
}

release_lock() {
    remove_pid_file
}

# ── management commands ──────────────────────────────────────────────────────

# Return a list of all known audio-share sink names (from PID files).
all_instance_names() {
    local f
    for f in "$RUNTIME_DIR"/*.pid; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" .pid)
        printf '%s\n' "$name"
    done
}

# Return sink names of *other* live instances (excludes our own SINK_NAME).
peer_sink_names() {
    local f
    for f in "$RUNTIME_DIR"/*.pid; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" .pid)
        [[ "$name" == "$SINK_NAME" ]] && continue
        if read_pid_file "$f" && pid_alive "$_PF_PID"; then
            printf '%s\n' "$name"
        fi
    done
}

cmd_status() {
    ensure_runtime_dir
    local found=false
    printf '%-24s  %-8s  %-14s  %s\n' "SINK NAME" "PID" "MODULE" "STATUS"
    printf '%-24s  %-8s  %-14s  %s\n' "─────────" "───" "──────" "──────"

    local f
    for f in "$RUNTIME_DIR"/*.pid; do
        [[ -f "$f" ]] || continue
        found=true
        local name
        name=$(basename "$f" .pid)
        if read_pid_file "$f"; then
            if pid_alive "$_PF_PID"; then
                printf '%-24s  %-8s  %-14s  %s\n' "$name" "$_PF_PID" "$_PF_MODULE" "running"
            else
                printf '%-24s  %-8s  %-14s  %s\n' "$name" "$_PF_PID" "$_PF_MODULE" "STALE (dead)"
            fi
        else
            printf '%-24s  %-8s  %-14s  %s\n' "$name" "?" "?" "corrupt PID file"
        fi
    done

    if [[ "$found" == false ]]; then
        echo "No audio-share instances found."
    fi
}

cmd_stop() {
    ensure_runtime_dir
    local target="$1"
    local pf="${RUNTIME_DIR}/${target}.pid"

    if [[ ! -f "$pf" ]]; then
        err "No instance found for sink '${target}'"
        return 1
    fi

    if ! read_pid_file "$pf"; then
        err "Corrupt PID file: ${pf}"
        rm -f "$pf"
        return 1
    fi

    if pid_alive "$_PF_PID"; then
        log "Sending SIGTERM to PID ${_PF_PID} (sink '${target}') …"
        kill -TERM "$_PF_PID"
        # Wait a moment for graceful shutdown
        local i
        for i in $(seq 1 30); do
            pid_alive "$_PF_PID" || break
            sleep 0.2
        done
        if pid_alive "$_PF_PID"; then
            warn "PID ${_PF_PID} did not exit; sending SIGKILL"
            kill -KILL "$_PF_PID" 2>/dev/null || true
            sleep 0.5
            # Force-cleanup the sink since the process couldn't do it
            if [[ -n "$_PF_MODULE" && "$_PF_MODULE" != "0" ]]; then
                pactl unload-module "$_PF_MODULE" 2>/dev/null || true
            fi
            rm -f "$pf"
        fi
        log "Stopped '${target}'"
    else
        warn "PID ${_PF_PID} is already dead (stale); cleaning up"
        if [[ -n "$_PF_MODULE" && "$_PF_MODULE" != "0" ]]; then
            pactl unload-module "$_PF_MODULE" 2>/dev/null || true
        fi
        rm -f "$pf"
        log "Cleaned up stale instance '${target}'"
    fi
}

cmd_stop_all() {
    ensure_runtime_dir
    local names
    names=$(all_instance_names)
    if [[ -z "$names" ]]; then
        echo "No audio-share instances found."
        return 0
    fi
    while IFS= read -r name; do
        cmd_stop "$name"
    done <<< "$names"
}

# ─── sink management ────────────────────────────────────────────────────────

# Capture the default sink at startup (fallback of last resort).
get_default_sink() {
    STARTUP_DEFAULT_SINK=$(pactl get-default-sink 2>/dev/null) \
        || die "Could not determine default audio sink"
    log "Default sink: ${_B}${STARTUP_DEFAULT_SINK}${_N}"
}

# Return the *current* default sink, falling back to the startup value if the
# query fails (e.g. PipeWire restarted mid-run).
current_default_sink() {
    pactl get-default-sink 2>/dev/null || printf '%s' "$STARTUP_DEFAULT_SINK"
}

sink_exists() {
    pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qxF "$SINK_NAME"
}

# Find the Owner Module ID for a sink by its pactl name.
# Prints the numeric module ID, or nothing if not found.
get_sink_module_id() {
    local target="$1"
    pactl list sinks 2>/dev/null | awk -v name="$target" '
        /^\tName:/ { current = $2 }
        /^\tOwner Module:/ && current == name { print $3; exit }
    '
}

create_sink() {
    if sink_exists; then
        # The sink already exists but we hold the lock, so it's a leftover
        # from a crash that the PID-file recovery didn't catch (no PID file,
        # but the module survived).  Try to unload just this one module.
        local stale_mod
        stale_mod=$(get_sink_module_id "$SINK_NAME")
        if [[ -n "$stale_mod" ]]; then
            warn "Sink '${SINK_NAME}' already exists (module ${stale_mod}) — unloading stale module"
            pactl unload-module "$stale_mod" 2>/dev/null || true
            sleep 0.3
        fi
        if sink_exists; then
            die "Sink '${SINK_NAME}' already exists and could not be removed"
        fi
    fi

    log "Creating virtual sink: ${_B}${SINK_NAME}${_N} (${SINK_DESCRIPTION})"
    MODULE_ID=$(pactl load-module module-null-sink \
        sink_name="$SINK_NAME" \
        sink_properties="device.description=\"${SINK_DESCRIPTION}\"" \
        2>&1) || die "Failed to load module-null-sink"
    log "Loaded module-null-sink (id ${MODULE_ID})"

    # Update PID file with the module ID now that we know it
    write_pid_file

    # Wait for both stereo playback ports to be registered by PipeWire.
    # Checking only for "any port" is racy — after a stale-module recovery
    # the second channel can lag behind by a few hundred milliseconds.
    local tries=0
    while ! pw-link -i 2>/dev/null | grep -qF "${SINK_NAME}:playback_FL" \
       || ! pw-link -i 2>/dev/null | grep -qF "${SINK_NAME}:playback_FR"; do
        (( ++tries > 40 )) && die "Virtual sink ports never appeared"
        sleep 0.1
    done

    log "Sink ports ready:"
    pw-link -i 2>/dev/null | grep "^${SINK_NAME}:" | while IFS= read -r p; do
        log "  input  ${p}"
    done
    pw-link -o 2>/dev/null | grep "^${SINK_NAME}:" | while IFS= read -r p; do
        log "  monitor ${p}"
    done
}

remove_sink() {
    if [[ -n "$MODULE_ID" ]]; then
        log "Unloading virtual sink (module ${MODULE_ID})"
        pactl unload-module "$MODULE_ID" 2>/dev/null || true
        MODULE_ID=""
    fi
}

# ─── stream discovery ───────────────────────────────────────────────────────

# Emit one JSON object per audio output stream:
#   { "node_name": "…", "app_name": "…", "serial": 123 }
get_audio_streams() {
    pw-dump 2>/dev/null | jq -c '
        [ .[]
          | select(.info.props."media.class" == "Stream/Output/Audio")
          | {
              node_name:  .info.props."node.name",
              app_name:  (.info.props."application.name" // ""),
              serial:    (.info.props."object.serial" // 0)
            }
        ] | .[]
    ' 2>/dev/null
}

# ─── filter logic ────────────────────────────────────────────────────────────

# Returns 0 (true) when the stream should be captured.
stream_matches_filter() {
    local node_name="$1" app_name="$2"

    # Never capture our own sink
    [[ "$node_name" == "${SINK_NAME}"* ]] && return 1

    # Build a lower-cased haystack from both identifiers
    local haystack="${node_name,,} ${app_name,,}"

    # ── whitelist mode ──
    if (( ${#WHITELIST[@]} > 0 )); then
        local pat
        for pat in "${WHITELIST[@]}"; do
            pat="${pat,,}"
            pat="${pat#"${pat%%[![:space:]]*}"}"   # trim leading
            pat="${pat%"${pat##*[![:space:]]}"}"   # trim trailing
            [[ "$haystack" == *"$pat"* ]] && return 0
        done
        return 1
    fi

    # ── blacklist mode ──
    if (( ${#BLACKLIST[@]} > 0 )); then
        local pat
        for pat in "${BLACKLIST[@]}"; do
            pat="${pat,,}"
            pat="${pat#"${pat%%[![:space:]]*}"}"
            pat="${pat%"${pat##*[![:space:]]}"}"
            [[ "$haystack" == *"$pat"* ]] && return 1
        done
    fi

    return 0   # default: capture everything
}

# ─── linking helpers ─────────────────────────────────────────────────────────

# Check whether an explicit pw-link from $1 → $2 already exists.
link_exists() {
    local out="$1" in="$2"
    pw-link -l 2>/dev/null | awk -v out="$out" -v inp="$in" '
        $0 == out          { found = 1; next }
        found && /^\s/     { gsub(/^\s+\|-> /, ""); if ($0 == inp) exit 0; next }
        found && !/^\s/    { found = 0 }
        END                { exit 1 }
    '
}

# Resolve the virtual-sink playback port that should receive a given channel.
# Falls back to playback_FL for MONO or unrecognised suffixes.
resolve_sink_port() {
    local channel="$1"
    local candidate="${SINK_NAME}:playback_${channel}"
    if pw-link -i 2>/dev/null | grep -qxF "$candidate"; then
        printf '%s' "$candidate"
        return 0
    fi
    # fallback
    candidate="${SINK_NAME}:playback_FL"
    if pw-link -i 2>/dev/null | grep -qxF "$candidate"; then
        printf '%s' "$candidate"
        return 0
    fi
    return 1
}

# Create additional pw-links from a stream's output ports to our sink.
# This does NOT remove the WirePlumber-managed link to the default sink.
link_stream_to_sink() {
    local node_name="$1"
    local linked=false

    local out_ports
    out_ports=$(pw-link -o 2>/dev/null | grep "^${node_name}:output_" || true)
    [[ -z "$out_ports" ]] && { debug "No output ports for ${node_name}"; return 1; }

    while IFS= read -r out_port; do
        local channel="${out_port##*output_}"
        local in_port
        in_port=$(resolve_sink_port "$channel") || { warn "  No sink port for channel ${channel}"; continue; }

        if link_exists "$out_port" "$in_port"; then
            debug "  Link already present: ${out_port} → ${in_port}"
            linked=true
            continue
        fi

        if pw-link -- "$out_port" "$in_port" 2>/dev/null; then
            log "  Linked ${out_port} → ${in_port}"
            linked=true
        else
            # May already exist (race) — treat "File exists" as success
            if link_exists "$out_port" "$in_port"; then
                linked=true
            else
                warn "  Failed to link ${out_port} → ${in_port}"
            fi
        fi
    done <<< "$out_ports"

    $linked
}

# ─── mute-local helpers ─────────────────────────────────────────────────────

# Find the pactl sink-input index(es) for a given PipeWire node name.
get_sink_input_indices() {
    local target="$1"
    pactl list sink-inputs 2>/dev/null | awk -v target="$target" '
        /^Sink Input #/ {
            idx = $3; gsub(/#/, "", idx); sink = ""
        }
        /^\tSink:/ {
            sink = $2
        }
        /node\.name =/ {
            val = $0
            gsub(/.*= "/, "", val)
            gsub(/".*/, "", val)
            if (val == target) print idx ":" sink
        }
    '
}

# Get the pactl name of a sink given its numeric index.
get_sink_name_by_index() {
    local idx="$1"
    pactl list short sinks 2>/dev/null | awk -v i="$idx" '$1 == i { print $2 }'
}

# Check whether a stream is currently on a sink owned by another audio-share
# instance.  Returns 0 if the stream is owned by a peer, 1 otherwise.
stream_owned_by_peer() {
    local node_name="$1"
    local entries
    entries=$(get_sink_input_indices "$node_name") || true
    [[ -z "$entries" ]] && return 1

    # Collect live peer sink names once per call
    local peers
    peers=$(peer_sink_names)
    [[ -z "$peers" ]] && return 1

    local entry idx current_sink current_sink_name
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        idx="${entry%%:*}"
        current_sink="${entry##*:}"
        current_sink_name=$(get_sink_name_by_index "$current_sink")
        [[ -z "$current_sink_name" ]] && continue

        # Check against every peer
        while IFS= read -r peer; do
            [[ -z "$peer" ]] && continue
            if [[ "$current_sink_name" == "$peer" ]]; then
                debug "Stream ${node_name} (sink-input #${idx}) is on peer sink '${peer}'"
                return 0
            fi
        done <<< "$peers"
    done <<< "$entries"

    return 1
}

# Move a stream exclusively to our virtual sink (mute-local mode).
# Uses `pactl move-sink-input` so WirePlumber treats it as intentional and
# will NOT fight to reconnect it to the default sink.
move_stream_to_sink() {
    local node_name="$1"
    local entries
    entries=$(get_sink_input_indices "$node_name")
    [[ -z "$entries" ]] && { debug "No sink-input found for ${node_name}"; return 1; }

    local entry idx current_sink current_sink_name
    local moved=false
    while IFS= read -r entry; do
        idx="${entry%%:*}"
        current_sink="${entry##*:}"
        current_sink_name=$(get_sink_name_by_index "$current_sink")

        # Already on our sink?
        [[ "$current_sink_name" == "$SINK_NAME" ]] && { moved=true; continue; }

        # Remember where it was so we can restore later
        MOVED_INPUTS["$idx"]="${current_sink_name:-$(current_default_sink)}"

        if pactl move-sink-input "$idx" "$SINK_NAME" 2>/dev/null; then
            log "  Moved sink-input #${idx} → ${SINK_NAME} (was ${current_sink_name:-?})"
            moved=true
        else
            warn "  Failed to move sink-input #${idx}"
        fi
    done <<< "$entries"

    $moved
}

# Restore a stream back to its original sink.
restore_stream_from_sink() {
    local node_name="$1"
    local entries
    entries=$(get_sink_input_indices "$node_name") || true
    [[ -z "$entries" ]] && return 0

    local entry idx
    local live_default
    live_default=$(current_default_sink)
    while IFS= read -r entry; do
        idx="${entry%%:*}"
        local orig="${MOVED_INPUTS[$idx]:-$live_default}"

        if pactl move-sink-input "$idx" "$orig" 2>/dev/null; then
            log "  Restored sink-input #${idx} → ${orig}"
        else
            # Saved sink may have vanished; try the current default
            pactl move-sink-input "$idx" "$live_default" 2>/dev/null \
                && log "  Restored sink-input #${idx} → ${live_default} (fallback)" \
                || debug "  Could not restore sink-input #${idx}"
        fi
        unset "MOVED_INPUTS[$idx]"
    done <<< "$entries"
}

# ─── high-level capture / release ────────────────────────────────────────────

capture_stream() {
    local node_name="$1" app_name="$2"

    if [[ "$MUTE_LOCAL" == true ]]; then
        # Check peer ownership to avoid fighting another instance
        if stream_owned_by_peer "$node_name"; then
            warn "Skipping ${app_name:-$node_name}: already owned by another audio-share instance"
            return 1
        fi
        # Move exclusively to virtual sink (no local playback).
        if move_stream_to_sink "$node_name"; then
            CAPTURED["$node_name"]=1
            return 0
        fi
    else
        # Add supplementary link; local playback continues via WirePlumber.
        if link_stream_to_sink "$node_name"; then
            CAPTURED["$node_name"]=1
            return 0
        fi
    fi
    return 1
}

release_stream() {
    local node_name="$1"
    if [[ "$MUTE_LOCAL" == true ]]; then
        restore_stream_from_sink "$node_name"
    fi
    # In non-mute mode the pw-link is cleaned up automatically when the sink
    # is unloaded, so nothing extra to do.
    unset "CAPTURED[$node_name]"
}

# ─── bulk operations ─────────────────────────────────────────────────────────

capture_existing_streams() {
    log "Scanning for existing audio streams …"
    local count=0

    while IFS= read -r obj; do
        [[ -z "$obj" ]] && continue
        local node_name app_name
        node_name=$(jq -r '.node_name // empty' <<< "$obj")
        app_name=$(jq -r '.app_name // empty' <<< "$obj")
        [[ -z "$node_name" ]] && continue

        if stream_matches_filter "$node_name" "$app_name"; then
            log "Capturing: ${_B}${app_name:-$node_name}${_N}  (${node_name})"
            capture_stream "$node_name" "$app_name" && (( ++count ))
        else
            debug "Filtered out: ${app_name:-$node_name} (${node_name})"
        fi
    done < <(get_audio_streams)

    log "Captured ${_B}${count}${_N} stream(s)"
}

# Find streams that appeared since our last scan and capture them.
scan_new_streams() {
    while IFS= read -r obj; do
        [[ -z "$obj" ]] && continue
        local node_name app_name
        node_name=$(jq -r '.node_name // empty' <<< "$obj")
        app_name=$(jq -r '.app_name // empty' <<< "$obj")
        [[ -z "$node_name" ]] && continue

        # Already tracked (captured or previously skipped)?
        [[ -v "CAPTURED[$node_name]" ]] && continue
        [[ -v "SKIPPED[$node_name]" ]] && continue

        if stream_matches_filter "$node_name" "$app_name"; then
            log "New stream: ${_B}${app_name:-$node_name}${_N}  (${node_name})"
            if ! capture_stream "$node_name" "$app_name"; then
                # Remember we skipped it so we don't log every poll cycle
                SKIPPED["$node_name"]=1
            fi
        fi
    done < <(get_audio_streams)
}

# Make sure links / moves haven't been undone (WirePlumber quirks, etc.)
verify_existing_links() {
    local stale=()

    for node_name in "${!CAPTURED[@]}"; do
        # Has the stream vanished entirely?
        if ! pw-link -o 2>/dev/null | grep -q "^${node_name}:"; then
            debug "Stream gone: ${node_name}"
            stale+=("$node_name")
            continue
        fi

        if [[ "$MUTE_LOCAL" == true ]]; then
            # Make sure the stream is still on our sink.  If something moved
            # it back, re-move it.
            local entries
            entries=$(get_sink_input_indices "$node_name") || true
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                local idx="${entry%%:*}"
                local current_sink="${entry##*:}"
                local current_sink_name
                current_sink_name=$(get_sink_name_by_index "$current_sink")
                if [[ "$current_sink_name" != "$SINK_NAME" ]]; then
                    # Check if another instance now owns it
                    if stream_owned_by_peer "$node_name"; then
                        debug "Stream ${node_name} was taken by a peer; releasing"
                        stale+=("$node_name")
                        continue 2
                    fi
                    debug "Re-moving ${node_name} (sink-input #${idx}) back to ${SINK_NAME}"
                    MOVED_INPUTS["$idx"]="${current_sink_name:-$(current_default_sink)}"
                    pactl move-sink-input "$idx" "$SINK_NAME" 2>/dev/null || true
                fi
            done <<< "$entries"
        else
            # Non-mute: verify the supplementary link still exists.
            link_stream_to_sink "$node_name" 2>/dev/null || true
        fi
    done

    for node_name in "${stale[@]}"; do
        unset "CAPTURED[$node_name]"
        unset "MOVED_INPUTS[$node_name]" 2>/dev/null || true
    done

    # Re-evaluate previously skipped streams (the owning peer may have stopped)
    for node_name in "${!SKIPPED[@]}"; do
        # Stream gone? Drop it.
        if ! pw-link -o 2>/dev/null | grep -q "^${node_name}:"; then
            unset "SKIPPED[$node_name]"
            continue
        fi
        # Still owned by a peer? Keep skipping.
        if [[ "$MUTE_LOCAL" == true ]] && stream_owned_by_peer "$node_name"; then
            continue
        fi
        # Peer released it — allow scan_new_streams to pick it up next cycle.
        debug "Peer released ${node_name}; will retry capture"
        unset "SKIPPED[$node_name]"
    done
}

# ─── cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
    [[ "$CLEANUP_DONE" == true ]] && return
    CLEANUP_DONE=true

    log "Shutting down …"

    # Restore muted streams before removing the sink
    if [[ "$MUTE_LOCAL" == true ]]; then
        log "Restoring streams to default output …"
        local live_default
        live_default=$(current_default_sink)
        for node_name in "${!CAPTURED[@]}"; do
            restore_stream_from_sink "$node_name"
        done

        # Belt-and-suspenders: move any remaining sink-inputs that point at our
        # sink back to the default output.
        local leftover
        leftover=$(pactl list sink-inputs 2>/dev/null | awk -v s="$SINK_NAME" '
            /^Sink Input #/ { idx = $3; gsub(/#/,"",idx) }
            /node\.name =/ {
                val = $0; gsub(/.*= "/,"",val); gsub(/".*/,"",val)
                if (val == s) print idx
            }
        ' || true)
        while IFS= read -r idx; do
            [[ -z "$idx" ]] && continue
            pactl move-sink-input "$idx" "$live_default" 2>/dev/null \
                && log "  Fallback-restored sink-input #${idx}" || true
        done <<< "$leftover"
    fi

    remove_sink
    release_lock
    log "Done."
}

# ─── main loop ───────────────────────────────────────────────────────────────

monitor_loop() {
    if [[ "$AUTO_CAPTURE" == true ]]; then
        log "Monitoring for new streams (poll every ${POLL_INTERVAL}s) — ${_B}Ctrl+C${_N} to stop"
    else
        log "Auto-capture disabled; maintaining existing links — ${_B}Ctrl+C${_N} to stop"
    fi

    while true; do
        [[ "$AUTO_CAPTURE" == true ]] && scan_new_streams
        verify_existing_links
        sleep "$POLL_INTERVAL" || true
    done
}

# ─── entry point ─────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    # Handle management sub-commands early
    case "$ACTION" in
        status)   cmd_status;          exit $? ;;
        stop)     ensure_runtime_dir;  cmd_stop "$SINK_NAME"; exit $? ;;
        stop-all) cmd_stop_all;        exit $? ;;
    esac

    # ── normal "run" path ──
    check_deps
    ensure_runtime_dir

    # Banner
    log "═══════════════════════════════════════"
    log " ${_B}audio-share${_N}  —  PipeWire audio router"
    log "═══════════════════════════════════════"
    log "Sink name:     ${_B}${SINK_NAME}${_N}"
    log "Description:   ${SINK_DESCRIPTION}"
    log "Auto-capture:  ${AUTO_CAPTURE}"
    log "Mute local:    ${MUTE_LOCAL}"
    if (( ${#WHITELIST[@]} > 0 )); then
        log "Whitelist:     ${WHITELIST[*]}"
    elif (( ${#BLACKLIST[@]} > 0 )); then
        log "Blacklist:     ${BLACKLIST[*]}"
    else
        log "Filter:        (none — all streams)"
    fi
    log "Poll interval: ${POLL_INTERVAL}s"
    log "───────────────────────────────────────"

    trap cleanup EXIT
    trap 'exit 0' INT TERM HUP

    acquire_lock
    # Write an initial PID file (MODULE_ID updated after sink creation)
    write_pid_file

    get_default_sink
    create_sink
    capture_existing_streams

    log "───────────────────────────────────────"
    log "Virtual sink ${_B}${SINK_NAME}${_N} is ready."
    log "Configure your capture software to use:"
    log "  Sink / playback: ${_B}${SINK_NAME}${_N}"
    log "  Monitor / source: ${_B}${SINK_NAME}.monitor${_N}"
    log "───────────────────────────────────────"

    monitor_loop
}

main "$@"
