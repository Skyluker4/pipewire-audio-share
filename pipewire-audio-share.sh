#!/usr/bin/env bash
#
# pipewire-audio-share.sh — PipeWire virtual sink for sharing application audio
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
# SPDX-License-Identifier: AGPL-3.0-only

set -euo pipefail

# ─── defaults ────────────────────────────────────────────────────────────────

SINK_NAME="audio_share"
SINK_DESCRIPTION="Audio Share"
AUTO_CAPTURE=true
MUTE_LOCAL=false
POLL_INTERVAL=2
VERBOSE=false
INTERACTIVE=false
CREATE_SOURCE=false
SET_DEFAULT_SOURCE=false
SOURCE_NAME=""
SOURCE_DESCRIPTION=""
declare -a INCLUDE=()
declare -a EXCLUDE=()
declare -a ROUTE_INPUTS=()

# ─── runtime state ───────────────────────────────────────────────────────────

MODULE_ID=""
SOURCE_MODULE_ID=""
ORIGINAL_DEFAULT_SOURCE="" # saved when --default-source is used; restored on exit
STARTUP_DEFAULT_SINK=""    # captured once; used only as a last resort
CLEANUP_DONE=false
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/pipewire-audio-share"
declare -A CAPTURED=()        # node_id → node_name  (streams we are managing)
declare -A SKIPPED=()         # node_id → "1"  (streams we skipped, e.g. peer-owned)
declare -A MOVED_INPUTS=()    # pactl_index → original_sink  (for mute-local restore)
declare -A OUR_LINKS=()       # "out_port_id|in_port_id" → 1  (links WE created)
declare -A CAPTURED_INPUTS=() # node_name → "1"  (input devices routed to our sink)
declare -A MANUAL_ADD=()      # node_id → "1"  (user explicitly added via TUI)
declare -A MANUAL_REMOVE=()   # node_id → "1"  (user explicitly removed via TUI)
declare -A PINNED_CAPTURES=() # node_name → "1"  (capture streams pinned to our monitor)
LAST_KNOWN_DEFAULT=""         # most recent default sink that was a real output device
DEFAULT_SHARE_BY_USER=false   # true when the user set the default to our sink via the TUI
_GUARD_LAST_CUR=""            # default sink seen on the previous guard cycle
_GUARD_CUR_VIRTUAL=false      # whether _GUARD_LAST_CUR is a virtual (null) sink
declare -i SKIP_RETRY_CTR=0   # cycle counter for periodic SKIPPED re-evaluation
SKIP_RETRY_EVERY=15           # retry skipped streams every N poll cycles (~30s at 2s poll)
TUI_ACTIVE=false              # true while the interactive TUI owns the screen
declare -a TUI_MESSAGES=()    # ring buffer of recent warnings/errors for TUI

# ─── colours / logging ──────────────────────────────────────────────────────

if [[ -t 2 ]]; then
	_R=$'\033[0;31m' _G=$'\033[0;32m' _Y=$'\033[1;33m' _C=$'\033[0;36m'
	_B=$'\033[1m' _D=$'\033[2m' _N=$'\033[0m'
else
	_R='' _G='' _Y='' _C='' _B='' _D='' _N=''
fi

_ts() { date +%H:%M:%S; }
_tag() { printf '%b%s%b' "$_D" "$SINK_NAME" "$_N"; }

_tui_push_msg() {
	TUI_MESSAGES+=("$*")
	while ((${#TUI_MESSAGES[@]} > 5)); do
		TUI_MESSAGES=("${TUI_MESSAGES[@]:1}")
	done
}

log() {
	[[ "$TUI_ACTIVE" == true ]] && return
	printf '%b[%s]%b %b(%s)%b %s\n' "$_G" "$(_ts)" "$_N" "$_D" "$SINK_NAME" "$_N" "$*" >&2
}
warn() {
	if [[ "$TUI_ACTIVE" == true ]]; then
		_tui_push_msg "WARN: $*"
		return
	fi
	printf '%b[%s] WARN:%b %b(%s)%b %s\n' "$_Y" "$(_ts)" "$_N" "$_D" "$SINK_NAME" "$_N" "$*" >&2
}
err() {
	if [[ "$TUI_ACTIVE" == true ]]; then
		_tui_push_msg "ERROR: $*"
		return
	fi
	printf '%b[%s] ERROR:%b %b(%s)%b %s\n' "$_R" "$(_ts)" "$_N" "$_D" "$SINK_NAME" "$_N" "$*" >&2
}
debug() {
	[[ "$TUI_ACTIVE" == true ]] && return
	[[ "$VERBOSE" == true ]] && printf '%b[%s] dbg:%b %b(%s)%b %s\n' "$_C" "$(_ts)" "$_N" "$_D" "$SINK_NAME" "$_N" "$*" >&2 || true
}

die() {
	err "$@"
	exit 1
}

# ─── usage ───────────────────────────────────────────────────────────────────

_usage_section() {
	local heading="$1"
	shift
	printf '\n%s\n' "$heading"
	local line
	for line in "$@"; do
		printf '    %s\n' "$line"
	done
}

usage() {
	cat <<-'EOF'
		pipewire-audio-share — route application audio into a virtual PipeWire sink
	EOF

	_usage_section "USAGE" \
		"pipewire-audio-share.sh [OPTIONS]" \
		"pipewire-audio-share.sh -i [OPTIONS]" \
		"pipewire-audio-share.sh --status" \
		"pipewire-audio-share.sh --stop NAME" \
		"pipewire-audio-share.sh --stop-all"

	_usage_section "OPTIONS" \
		"-n, --sink-name NAME" \
		"    PipeWire sink name (default: audio_share)" \
		"-d, --description DESC" \
		"    Human-readable description (default: Audio Share)" \
		"-a, --auto-capture" \
		"    Capture new streams as they appear (default)" \
		"-A, --no-auto-capture" \
		"    Only capture streams present at start-up" \
		"-I, --include APP" \
		"    Application pattern to capture (repeatable)" \
		"-X, --exclude APP" \
		"    Application pattern to exclude (repeatable)" \
		"    (include and exclude are mutually exclusive)" \
		"-m, --mute-local" \
		"    Do NOT play captured audio on the default output" \
		"    (moves streams exclusively to the virtual sink)" \
		"-R, --route-input DEVICE" \
		"    Route an input device (mic, line-in) to the sink" \
		"    (repeatable; pattern-matched like -I/-X)" \
		"-S, --source" \
		"    Also create a virtual input device (source) from the" \
		"    sink's monitor so apps can use it as a microphone" \
		"--source-name NAME" \
		"    Name for the virtual source (default: <sink-name>_input)" \
		"--source-description DESC" \
		"    Description for the virtual source" \
		"--default-source" \
		"    Set the virtual source as the system default input" \
		"    device so apps like Audacity see it (restored on exit)" \
		"-p, --poll-interval SECS" \
		"    How often to scan for changes (default: 2)" \
		"-i, --interactive" \
		"    Launch interactive TUI (requires a terminal)" \
		"-v, --verbose" \
		"    Print extra debug output" \
		"-h, --help" \
		"    Show this help"

	_usage_section "MANAGEMENT" \
		"--status      List all running pipewire-audio-share instances" \
		"--stop NAME   Stop the instance with the given sink name" \
		"--stop-all    Stop every running pipewire-audio-share instance"

	_usage_section "MATCHING" \
		"Patterns are matched case-insensitively as substrings against" \
		"both the PipeWire node.name (e.g. \"alsa_playback.firefox\") and" \
		"the application.name (e.g. \"Firefox\").  Partial matches work:" \
		"-I fire matches Firefox."

	_usage_section "HOW IT WORKS" \
		"1. A module-null-sink is loaded, creating a virtual sink with" \
		"   playback (input) ports and monitor (output) ports." \
		"" \
		"2. For every matching audio stream, pw-link adds additional" \
		"   links from the stream's output ports to the virtual sink." \
		"   The existing WirePlumber-managed link to the default sink" \
		"   is left in place, so you still hear the audio locally." \
		"" \
		"3. If --mute-local is given, each stream is instead moved to" \
		"   the virtual sink via pactl move-sink-input, which tells" \
		"   WirePlumber to route exclusively there.  On exit the" \
		"   streams are moved back." \
		"" \
		"4. Capture software (Sunshine, OBS, ...) selects the virtual" \
		"   sink or its monitor source as its audio input." \
		"" \
		"5. If --source is given, a native PipeWire Audio/Source/Virtual" \
		"   node is created and linked to the sink's monitor, exposing" \
		"   it as a regular input device visible to all applications."

	_usage_section "MULTIPLE INSTANCES" \
		"You can run several instances simultaneously with different" \
		"--sink-name values and independent filter/mute options.  Each" \
		"instance is tracked by a PID file in" \
		"\$XDG_RUNTIME_DIR/pipewire-audio-share/.  Stale sinks left behind by a" \
		"crashed instance are automatically cleaned up on the next start." \
		"" \
		"When --mute-local is active, an instance will skip streams that" \
		"are already owned by another pipewire-audio-share instance to prevent" \
		"the two from fighting over the same sink-input."

	_usage_section "EXAMPLES" \
		"# share everything, keep local playback" \
		"pipewire-audio-share.sh" \
		"" \
		"# share only firefox and mpv" \
		"pipewire-audio-share.sh -I firefox -I mpv" \
		"" \
		"# share everything except notification sounds" \
		"pipewire-audio-share.sh -X notification -X alert" \
		"" \
		"# share everything, silence local speakers" \
		"pipewire-audio-share.sh --mute-local" \
		"" \
		"# multiple instances" \
		"pipewire-audio-share.sh -n sunshine -d \"Sunshine\" -I firefox -I mpv &" \
		"pipewire-audio-share.sh -n discord -d \"Discord\" -I music -m &" \
		"pipewire-audio-share.sh --status" \
		"pipewire-audio-share.sh --stop sunshine" \
		"pipewire-audio-share.sh --stop-all" \
		"" \
		"# interactive mode" \
		"pipewire-audio-share.sh -i" \
		"pipewire-audio-share.sh -i -n sunshine -I firefox -I mpv" \
		"" \
		"# create a virtual microphone from the shared audio" \
		"pipewire-audio-share.sh --source" \
		"pipewire-audio-share.sh -S --source-name my_mic -I firefox" \
		"" \
		"# virtual mic as default input (for apps that only see 'default')" \
		"pipewire-audio-share.sh -S --default-source" \
		"" \
		"# route a microphone into the shared audio" \
		"pipewire-audio-share.sh -R headset" \
		"pipewire-audio-share.sh -R webcam -R line-in"
}

# ─── argument parsing ────────────────────────────────────────────────────────

# Management sub-commands handled before full parse.
ACTION="run" # run | status | stop | stop-all

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status)
			ACTION="status"
			shift
			;;
		--stop)
			ACTION="stop"
			SINK_NAME="$2"
			shift 2
			;;
		--stop-all)
			ACTION="stop-all"
			shift
			;;
		-n | --sink-name)
			SINK_NAME="$2"
			shift 2
			;;
		-d | --description)
			SINK_DESCRIPTION="$2"
			shift 2
			;;
		-a | --auto-capture)
			AUTO_CAPTURE=true
			shift
			;;
		-A | --no-auto-capture)
			AUTO_CAPTURE=false
			shift
			;;
		-I | --include)
			INCLUDE+=("$2")
			shift 2
			;;
		-X | --exclude)
			EXCLUDE+=("$2")
			shift 2
			;;
		-m | --mute-local)
			MUTE_LOCAL=true
			shift
			;;
		-R | --route-input)
			ROUTE_INPUTS+=("$2")
			shift 2
			;;
		-S | --source)
			CREATE_SOURCE=true
			shift
			;;
		--source-name)
			SOURCE_NAME="$2"
			shift 2
			;;
		--source-description)
			SOURCE_DESCRIPTION="$2"
			shift 2
			;;
		--default-source)
			SET_DEFAULT_SOURCE=true
			CREATE_SOURCE=true
			shift
			;;
		-p | --poll-interval)
			POLL_INTERVAL="$2"
			shift 2
			;;
		-i | --interactive)
			INTERACTIVE=true
			shift
			;;
		-v | --verbose)
			VERBOSE=true
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "Unknown option: $1 (try --help)" ;;
		esac
	done

	if [[ "$ACTION" == "run" ]]; then
		if ((${#INCLUDE[@]} > 0 && ${#EXCLUDE[@]} > 0)); then
			die "Cannot use --include and --exclude together"
		fi
		if [[ "$INTERACTIVE" == true ]] && ! [[ -t 0 && -t 2 ]]; then
			die "Interactive mode requires a terminal (stdin and stderr must be TTY)"
		fi
	fi
}

# ─── dependency check ────────────────────────────────────────────────────────

check_deps() {
	local missing=()
	for cmd in pw-link pw-dump pactl jq; do
		command -v "$cmd" &>/dev/null || missing+=("$cmd")
	done
	((${#missing[@]} == 0)) || die "Missing required commands: ${missing[*]}"
}

# ─── PID-file / instance management ─────────────────────────────────────────

ensure_runtime_dir() {
	mkdir -p "$RUNTIME_DIR"
}

pid_file() {
	printf '%s/%s.pid' "$RUNTIME_DIR" "$SINK_NAME"
}

# Write PID:SINK_MODULE:SOURCE_MODULE to the lock file.
write_pid_file() {
	printf '%d:%s:%s\n' "$$" "$MODULE_ID" "$SOURCE_MODULE_ID" >"$(pid_file)"
}

remove_pid_file() {
	rm -f "$(pid_file)"
}

# Read a PID file → sets _PF_PID, _PF_MODULE, and _PF_SRC_MOD.
# Handles both old (PID:MODULE) and new (PID:MODULE:SOURCE) formats.
read_pid_file() {
	local file="$1"
	_PF_PID="" _PF_MODULE="" _PF_SRC_MOD=""
	[[ -f "$file" ]] || return 1
	local content remainder
	content=$(<"$file")
	_PF_PID="${content%%:*}"
	remainder="${content#*:}"
	_PF_MODULE="${remainder%%:*}"
	if [[ "$remainder" == *:* ]]; then
		_PF_SRC_MOD="${remainder#*:}"
	else
		_PF_SRC_MOD=""
	fi
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
				# Clean up the orphaned modules if possible
				if [[ -n "$_PF_SRC_MOD" && "$_PF_SRC_MOD" != "0" && "$_PF_SRC_MOD" != "" ]]; then
					log "Destroying orphaned source node ${_PF_SRC_MOD} from previous crash"
					pw-cli destroy "$_PF_SRC_MOD" 2>/dev/null || true
				fi
				if [[ -n "$_PF_MODULE" && "$_PF_MODULE" != "0" && "$_PF_MODULE" != "" ]]; then
					log "Unloading orphaned sink module ${_PF_MODULE} from previous crash"
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

# Return a list of all known pipewire-audio-share sink names (from PID files).
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
		echo "No pipewire-audio-share instances found."
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
			# Force-cleanup the modules since the process couldn't do it
			if [[ -n "$_PF_SRC_MOD" && "$_PF_SRC_MOD" != "0" ]]; then
				pw-cli destroy "$_PF_SRC_MOD" 2>/dev/null || true
			fi
			if [[ -n "$_PF_MODULE" && "$_PF_MODULE" != "0" ]]; then
				pactl unload-module "$_PF_MODULE" 2>/dev/null || true
			fi
			rm -f "$pf"
		fi
		log "Stopped '${target}'"
	else
		warn "PID ${_PF_PID} is already dead (stale); cleaning up"
		if [[ -n "$_PF_SRC_MOD" && "$_PF_SRC_MOD" != "0" ]]; then
			pw-cli destroy "$_PF_SRC_MOD" 2>/dev/null || true
		fi
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
		echo "No pipewire-audio-share instances found."
		return 0
	fi
	while IFS= read -r name; do
		cmd_stop "$name"
	done <<<"$names"
}

# ─── sink management ────────────────────────────────────────────────────────

# Capture the default sink at startup (fallback of last resort).
get_default_sink() {
	STARTUP_DEFAULT_SINK=$(pactl get-default-sink 2>/dev/null) ||
		die "Could not determine default audio sink"
	LAST_KNOWN_DEFAULT="$STARTUP_DEFAULT_SINK"
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

# Is the given sink a virtual (null) sink with no hardware backing?
# Virtual sinks (ours, Sunshine's "sink-sunshine-*", etc.) produce no local
# audio, so a default pointing at one is almost always a hijack, not a
# deliberate choice.
_is_null_sink() {
	local name="$1"
	local factory
	factory=$(pw-dump 2>/dev/null | jq -r --arg n "$name" '
		[.[] | select(.info.props."node.name" == $n
			and .info.props."media.class" == "Audio/Sink")
		| .info.props."factory.name"] | .[0] // empty
	')
	[[ "$factory" == "support.null-audio-sink" ]]
}

# Keep capture clients (Sunshine, OBS, ...) that attached to our monitor
# pinned to it.  When the default sink changes, WirePlumber/pipewire-pulse
# moves capture streams that record a monitor over to the new default
# sink's monitor — which would leak the entire local mix (including
# excluded apps) into the stream instead of just the shared audio.
manage_capture_streams() {
	local mon_idx
	mon_idx=$(pactl list short sources 2>/dev/null |
		awk -v n="${SINK_NAME}.monitor" '$2 == n {print $1; exit}')
	[[ -z "$mon_idx" ]] && return 0

	local line idx rest src nn
	local -A _seen=()
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		idx="${line%%:*}"
		rest="${line#*:}"
		src="${rest%%:*}"
		nn="${rest#*:}"
		_seen["$nn"]=1
		if [[ "$src" == "$mon_idx" ]]; then
			if [[ ! -v "PINNED_CAPTURES[$nn]" ]]; then
				PINNED_CAPTURES["$nn"]=1
				log "Pinning capture stream to ${SINK_NAME}.monitor: ${_B}${nn}${_N}"
			fi
		elif [[ -v "PINNED_CAPTURES[$nn]" ]]; then
			if pactl move-source-output "$idx" "${SINK_NAME}.monitor" 2>/dev/null; then
				log "  Re-pinned capture stream ${nn} (#${idx}) → ${SINK_NAME}.monitor"
			fi
		fi
	done < <(pactl list source-outputs 2>/dev/null | awk '
		/^Source Output #/ { idx = $3; gsub(/#/,"",idx); src = "" }
		/^\tSource:/ { src = $2 }
		/node\.name =/ {
			nn = $0; gsub(/.*= "/,"",nn); gsub(/".*/,"",nn)
			if (nn != "") print idx ":" src ":" nn
		}
	')

	# Drop pinned names whose capture stream is gone
	for nn in "${!PINNED_CAPTURES[@]}"; do
		[[ -v "_seen[$nn]" ]] || unset "PINNED_CAPTURES[$nn]"
	done
}

# Move sink-inputs that were pushed onto our virtual sink by a default-sink
# hijack (WirePlumber routes streams to whatever the default is) back to the
# real default output.  Streams the script placed there itself (mute-local
# captures) are left alone.  In non-mute mode, NO sink-input belongs on our
# sink: sharing works via supplementary pw-links only.
_sweep_strays_from_sink() {
	local our_idx
	our_idx=$(pactl list short sinks 2>/dev/null |
		awk -v n="$SINK_NAME" '$2 == n {print $1; exit}')
	[[ -z "$our_idx" ]] && return 0

	local target="${LAST_KNOWN_DEFAULT:-$STARTUP_DEFAULT_SINK}"
	[[ -z "$target" || "$target" == "$SINK_NAME" ]] && return 0

	local -A _keep=()
	if [[ "$MUTE_LOCAL" == true ]]; then
		local _nid
		for _nid in "${!CAPTURED[@]}"; do
			_keep["${CAPTURED[$_nid]}"]=1
		done
	fi

	local line idx nn
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		idx="${line%%:*}"
		nn="${line#*:}"
		[[ -v "_keep[$nn]" ]] && continue
		if pactl move-sink-input "$idx" "$target" 2>/dev/null; then
			log "  Rescued sink-input #${idx} (${nn}) → ${target} (was hijacked onto ${SINK_NAME})"
		fi
	done < <(pactl list sink-inputs 2>/dev/null | awk -v oi="$our_idx" '
		/^Sink Input #/ { idx = $3; gsub(/#/,"",idx); sink = "" }
		/^\tSink:/ { sink = $2 }
		/node\.name =/ {
			nn = $0; gsub(/.*= "/,"",nn); gsub(/".*/,"",nn)
			if (sink == oi && nn != "") print idx ":" nn
		}
	')
}

# Keep the default output on a real device.  External programs switch the
# default to a virtual sink at any time (e.g. Sunshine sets the default to
# "sink-sunshine-stereo" or to its capture sink every time a client
# connects), which would route local audio into the void and pin unrelated
# streams there.  Called once per poll cycle.
guard_default_sink() {
	manage_capture_streams

	local cur
	cur=$(pactl get-default-sink 2>/dev/null || true)
	[[ -z "$cur" ]] && return 0

	# Only re-evaluate what kind of sink the default is when it changed
	if [[ "$cur" != "$_GUARD_LAST_CUR" ]]; then
		_GUARD_LAST_CUR="$cur"
		if [[ "$cur" == "$SINK_NAME" ]] || _is_null_sink "$cur"; then
			_GUARD_CUR_VIRTUAL=true
		else
			_GUARD_CUR_VIRTUAL=false
		fi
	fi

	if [[ "$_GUARD_CUR_VIRTUAL" == false ]]; then
		# The default is a real output device — remember it, and clean up
		# any streams left pinned to our sink by past hijacks.
		LAST_KNOWN_DEFAULT="$cur"
		DEFAULT_SHARE_BY_USER=false
		_sweep_strays_from_sink
		return 0
	fi

	# The default is a virtual sink.  Respect it when the user deliberately
	# chose OUR sink in the TUI.
	[[ "$cur" == "$SINK_NAME" && "$DEFAULT_SHARE_BY_USER" == true ]] && return 0

	# Switch back to the last real output, if it still exists.
	local target="${LAST_KNOWN_DEFAULT:-$STARTUP_DEFAULT_SINK}"
	[[ -z "$target" || "$target" == "$SINK_NAME" || "$target" == "$cur" ]] && return 0
	_is_null_sink "$target" && return 0
	pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qxF "$target" || return 0
	if pactl set-default-sink "$target" 2>/dev/null; then
		warn "Default output was switched to ${cur} — restored → ${target}"
		_sweep_strays_from_sink
	fi
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
	# Remember the current default sink.  Creating a new sink makes the
	# session manager (WirePlumber / pipewire-pulse) switch the default
	# output to the newly appeared device; we restore it below so the
	# user's output device is left untouched.
	local saved_default
	saved_default=$(pactl get-default-sink 2>/dev/null || true)

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
	while ! pw-link -i 2>/dev/null | grep -qF "${SINK_NAME}:playback_FL" ||
		! pw-link -i 2>/dev/null | grep -qF "${SINK_NAME}:playback_FR"; do
		((++tries > 40)) && die "Virtual sink ports never appeared"
		sleep 0.1
	done

	log "Sink ports ready:"
	pw-link -i 2>/dev/null | grep "^${SINK_NAME}:" | while IFS= read -r p; do
		log "  input  ${p}"
	done
	pw-link -o 2>/dev/null | grep "^${SINK_NAME}:" | while IFS= read -r p; do
		log "  monitor ${p}"
	done

	# Restore the default sink if creating our sink stole it.  Streams that
	# follow the default are moved back by the session manager automatically.
	local now_default
	now_default=$(pactl get-default-sink 2>/dev/null || true)
	if [[ -n "$saved_default" && "$now_default" != "$saved_default" ]]; then
		if pactl set-default-sink "$saved_default" 2>/dev/null; then
			log "Default sink restored → ${_B}${saved_default}${_N}"
		else
			warn "Default output was switched to '${now_default}' and could not be restored to '${saved_default}'"
		fi
	fi
}

remove_sink() {
	if [[ -n "$MODULE_ID" ]]; then
		log "Unloading virtual sink (module ${MODULE_ID})"
		pactl unload-module "$MODULE_ID" 2>/dev/null || true
		MODULE_ID=""
	fi
}

# ─── virtual source management ──────────────────────────────────────────────

# Create a virtual input device (Audio/Source/Virtual) backed by the sink's
# monitor.  Uses a native PipeWire node instead of module-remap-source so the
# device appears with the correct description and with the HARDWARE flag,
# making it visible to all applications (Audacity, Discord, OBS, etc.).
create_source() {
	[[ "$CREATE_SOURCE" == true ]] || return 0

	# Clean up a stale node with the same name (crash without PID file)
	local stale_id
	stale_id=$(pw-dump 2>/dev/null | jq -r \
		".[] | select(.info.props.\"node.name\" == \"${SOURCE_NAME}\") | .id" | head -1)
	if [[ -n "$stale_id" ]]; then
		warn "Source '${SOURCE_NAME}' already exists (node ${stale_id}) — destroying stale node"
		pw-cli destroy "$stale_id" 2>/dev/null || true
		sleep 0.3
	fi

	log "Creating virtual source: ${_B}${SOURCE_NAME}${_N} (${SOURCE_DESCRIPTION})"
	pw-cli create-node adapter \
		"{ factory.name=support.null-audio-sink node.name=${SOURCE_NAME} node.description=\"${SOURCE_DESCRIPTION}\" media.class=Audio/Source/Virtual audio.position=[FL,FR] object.linger=true }" \
		>/dev/null 2>&1 || {
		warn "Failed to create virtual source node"
		SOURCE_MODULE_ID=""
		return 1
	}

	# Wait for the source's input ports to appear
	local tries=0
	while ! pw-link -i 2>/dev/null | grep -qF "${SOURCE_NAME}:input_FL"; do
		((++tries > 40)) && {
			warn "Virtual source ports never appeared"
			SOURCE_MODULE_ID=""
			return 1
		}
		sleep 0.1
	done

	# Retrieve the PipeWire node ID for later cleanup
	SOURCE_MODULE_ID=$(pw-dump 2>/dev/null | jq -r \
		".[] | select(.info.props.\"node.name\" == \"${SOURCE_NAME}\") | .id" | head -1)

	# Link the sink's monitor output to the source's input
	pw-link "${SINK_NAME}:monitor_FL" "${SOURCE_NAME}:input_FL" 2>/dev/null || true
	pw-link "${SINK_NAME}:monitor_FR" "${SOURCE_NAME}:input_FR" 2>/dev/null || true

	log "Created virtual source (node ${SOURCE_MODULE_ID})"
	log "  Input device: ${_B}${SOURCE_NAME}${_N}"

	# Update PID file with the source node ID
	write_pid_file

	# Optionally make this source the system default input device
	if [[ "$SET_DEFAULT_SOURCE" == true ]]; then
		ORIGINAL_DEFAULT_SOURCE=$(pactl get-default-source 2>/dev/null || true)
		if pactl set-default-source "$SOURCE_NAME" 2>/dev/null; then
			log "  Set as default input device (was: ${ORIGINAL_DEFAULT_SOURCE:-?})"
		else
			warn "  Failed to set default source"
		fi
	fi
}

remove_source() {
	if [[ -n "$SOURCE_MODULE_ID" ]]; then
		log "Destroying virtual source (node ${SOURCE_MODULE_ID})"
		pw-cli destroy "$SOURCE_MODULE_ID" 2>/dev/null || true
		SOURCE_MODULE_ID=""
	fi
}

# ─── input device routing ───────────────────────────────────────────────────

# List available Audio/Source devices (hardware mics, line-ins, etc.).
# Emits one JSON object per device: { "node_name": "…", "description": "…" }
get_input_devices() {
	pw-dump 2>/dev/null | jq -c '
		[ .[]
			| select(.info.props."media.class" == "Audio/Source")
			| {
				node_name: .info.props."node.name",
				description: (.info.props."node.description" // "")
			}
		] | .[]
	' 2>/dev/null
}

# Check whether an input device matches any --route-input pattern.
input_matches_route() {
	local node_name="$1" description="$2"
	((${#ROUTE_INPUTS[@]} == 0)) && return 1
	local haystack="${node_name,,} ${description,,}"
	local pat
	for pat in "${ROUTE_INPUTS[@]}"; do
		pat="${pat,,}"
		pat="${pat#"${pat%%[![:space:]]*}"}"
		pat="${pat%"${pat##*[![:space:]]}"}"
		[[ "$haystack" == *"$pat"* ]] && return 0
	done
	return 1
}

# Link an input device's capture ports to our virtual sink.
# Uses port IDs for linking, same as stream linking.
link_input_to_sink() {
	local node_name="$1"
	local linked=false

	local dump
	dump=$(pw-dump 2>/dev/null) || return 1

	# Find the input device's node ID
	local dev_nid
	dev_nid=$(jq -r --arg n "$node_name" '
		[.[] | select(.info.props."node.name" == $n) | .id] | .[0] // empty
	' <<<"$dump")
	[[ -z "$dev_nid" ]] && {
		debug "Node not found: ${node_name}"
		return 1
	}

	# Get its output (capture) port IDs
	local cap_ports
	cap_ports=$(jq -r --argjson nid "$dev_nid" '
		.[] | select(.type == "PipeWire:Interface:Port"
			and .info.direction == "output"
			and .info.props."node.id" == $nid)
		| "\(.id)\t\(.info.props."port.name")"
	' <<<"$dump")
	[[ -z "$cap_ports" ]] && {
		debug "No capture ports for ${node_name}"
		return 1
	}

	# Sink input ports: channel → port_id
	local -A sink_ch=()
	_build_sink_ch_map dump sink_ch || return 1

	local cap_id cap_name
	while IFS=$'\t' read -r cap_id cap_name; do
		[[ -z "$cap_id" ]] && continue
		local channel="${cap_name##*capture_}"

		if [[ "$channel" == "MONO" ]]; then
			local target
			for target in "playback_FL" "playback_FR"; do
				local in_id="${sink_ch[$target]:-}"
				[[ -z "$in_id" ]] && continue
				local link_err
				if link_err=$(pw-link "$cap_id" "$in_id" 2>&1); then
					log "  Linked port ${cap_id} → ${in_id}"
					OUR_LINKS["${cap_id}|${in_id}"]=1
					linked=true
				elif [[ "$link_err" == *"File exists"* ]]; then
					linked=true
				else
					warn "  Failed to link port ${cap_id} → ${in_id}: ${link_err}"
				fi
			done
		else
			local in_id="${sink_ch["playback_${channel}"]:-}"
			[[ -z "$in_id" ]] && in_id="${sink_ch["playback_FL"]:-}"
			[[ -z "$in_id" ]] && continue
			local link_err
			if link_err=$(pw-link "$cap_id" "$in_id" 2>&1); then
				log "  Linked port ${cap_id} → ${in_id}"
				OUR_LINKS["${cap_id}|${in_id}"]=1
				linked=true
			elif [[ "$link_err" == *"File exists"* ]]; then
				linked=true
			else
				warn "  Failed to link port ${cap_id} → ${in_id}: ${link_err}"
			fi
		fi
	done <<<"$cap_ports"

	$linked
}

# Remove links WE created from an input device to our sink.
unlink_input_from_sink() {
	local node_name="$1"
	local count=0

	# Find the device's port IDs for lookup
	local dev_nid
	dev_nid=$(pw-dump 2>/dev/null | jq -r --arg n "$node_name" '
		[.[] | select(.info.props."node.name" == $n) | .id] | .[0] // empty')
	local -A _dev_ports=()
	if [[ -n "$dev_nid" ]]; then
		local _pid
		while IFS= read -r _pid; do
			[[ -n "$_pid" ]] && _dev_ports["$_pid"]=1
		done < <(pw-dump 2>/dev/null | jq -r --argjson nid "$dev_nid" '
			.[] | select(.type == "PipeWire:Interface:Port"
				and .info.direction == "output"
				and .info.props."node.id" == $nid) | .id')
	fi

	local key out_id in_id link_err
	for key in "${!OUR_LINKS[@]}"; do
		out_id="${key%%|*}"
		in_id="${key#*|}"
		[[ -v "_dev_ports[$out_id]" ]] || continue
		if link_err=$(pw-link -d "$out_id" "$in_id" 2>&1); then
			log "  Unlinked port ${out_id} → ${in_id}"
			((++count)) || true
		fi
		unset "OUR_LINKS[$key]"
	done
	debug "Removed ${count} input link(s) for ${node_name}"
}

# Route matching input devices to the sink (called at startup).
route_input_devices() {
	((${#ROUTE_INPUTS[@]} > 0)) || return 0
	log "Routing input devices …"
	local count=0
	while IFS= read -r obj; do
		[[ -z "$obj" ]] && continue
		local nn desc
		nn=$(jq -r '.node_name // empty' <<<"$obj")
		desc=$(jq -r '.description // empty' <<<"$obj")
		[[ -z "$nn" ]] && continue
		if input_matches_route "$nn" "$desc"; then
			log "Routing input: ${_B}${desc:-$nn}${_N}  (${nn})"
			if link_input_to_sink "$nn"; then
				CAPTURED_INPUTS["$nn"]=1
				((++count))
			fi
		fi
	done < <(get_input_devices)
	log "Routed ${_B}${count}${_N} input device(s)"
}

# ─── stream discovery ───────────────────────────────────────────────────────

# Emit one JSON object per audio output stream:
#   { "id": 190, "node_name": "…", "app_name": "…", "media_name": "…", "serial": 123 }
get_audio_streams() {
	pw-dump 2>/dev/null | jq -c '
		[ .[]
			| select(.info.props."media.class" == "Stream/Output/Audio")
			| {
				id:          .id,
				node_name:   .info.props."node.name",
				app_name:   (.info.props."application.name" // ""),
				media_name: (.info.props."media.name" // ""),
				serial:     (.info.props."object.serial" // 0)
			}
		] | .[]
	' 2>/dev/null
}

# ─── filter logic ────────────────────────────────────────────────────────────

# Returns 0 (true) when the stream should be captured.
stream_matches_filter() {
	local node_name="$1" app_name="$2" media_name="${3:-}"

	# Never capture our own sink
	[[ "$node_name" == "${SINK_NAME}"* ]] && return 1

	# Build a lower-cased haystack from all identifiers
	local haystack="${node_name,,} ${app_name,,} ${media_name,,}"

	# ── include mode ──
	if ((${#INCLUDE[@]} > 0)); then
		local pat
		for pat in "${INCLUDE[@]}"; do
			pat="${pat,,}"
			pat="${pat#"${pat%%[![:space:]]*}"}" # trim leading
			pat="${pat%"${pat##*[![:space:]]}"}" # trim trailing
			[[ "$haystack" == *"$pat"* ]] && return 0
		done
		return 1
	fi

	# ── exclude mode ──
	if ((${#EXCLUDE[@]} > 0)); then
		local pat
		for pat in "${EXCLUDE[@]}"; do
			pat="${pat,,}"
			pat="${pat#"${pat%%[![:space:]]*}"}"
			pat="${pat%"${pat##*[![:space:]]}"}"
			[[ "$haystack" == *"$pat"* ]] && return 1
		done
	fi

	return 0 # default: capture everything
}

# ─── linking helpers ─────────────────────────────────────────────────────────

# ─── PipeWire port-ID helpers ───────────────────────────────────────────────
# All pw-link operations use numeric port IDs to avoid ambiguity when
# multiple nodes share the same node.name (e.g. two mpv instances).

# Build a sink-port channel lookup from a cached pw-dump.
# Sets entries in the caller's associative array variable (passed by nameref).
# Usage: _build_sink_ch_map dump_var map_var
_build_sink_ch_map() {
	local -n _dump_ref=$1 _map_ref=$2
	local sink_nid
	sink_nid=$(jq -r --arg name "$SINK_NAME" '
		[.[] | select(.info.props."node.name" == $name) | .id] | .[0] // empty
	' <<<"$_dump_ref")
	[[ -z "$sink_nid" ]] && return 1
	local _pid _pname
	while IFS=$'\t' read -r _pid _pname; do
		[[ -n "$_pid" ]] && _map_ref["$_pname"]="$_pid"
	done < <(jq -r --argjson nid "$sink_nid" '
		.[] | select(.type == "PipeWire:Interface:Port"
			and .info.direction == "input"
			and .info.props."node.id" == $nid)
		| "\(.id)\t\(.info.props."port.name")"
	' <<<"$_dump_ref")
}

# Remove ALL pw-links from a stream's output ports to our virtual sink,
# regardless of who created them.  WirePlumber links a stream straight to
# our sink when the stream appears while the share sink is the default
# output (or when the user routed it there manually); those links are not
# tracked in OUR_LINKS but must also be removed, otherwise a "removed"
# stream keeps playing into the share.  Links to *other* sinks (e.g. the
# local headset) are never touched, so local playback is not disrupted.
# Takes a PipeWire node object.id (numeric).
# Sets _UNLINK_COUNT to the number of links actually removed.
_UNLINK_COUNT=0
unlink_stream_from_sink() {
	local node_id="$1"
	_UNLINK_COUNT=0

	local dump
	dump=$(pw-dump 2>/dev/null) || return 1

	# Build a set of this node's output port IDs for fast lookup
	local -A _node_ports=()
	local _pid
	while IFS= read -r _pid; do
		[[ -n "$_pid" ]] && _node_ports["$_pid"]=1
	done < <(jq -r --argjson nid "$node_id" '
		.[] | select(.type == "PipeWire:Interface:Port"
			and .info.direction == "output"
			and .info.props."node.id" == $nid) | .id
	' <<<"$dump")

	# Build a set of our sink's input port IDs for fast lookup
	local -A _sink_ports=()
	while IFS= read -r _pid; do
		[[ -n "$_pid" ]] && _sink_ports["$_pid"]=1
	done < <(jq -r --arg name "$SINK_NAME" '
		([.[] | select(.info.props."node.name" == $name) | .id] | .[0]) as $nid
		| .[] | select(.type == "PipeWire:Interface:Port"
			and .info.direction == "input"
			and .info.props."node.id" == $nid) | .id
	' <<<"$dump")

	# Remove every link (whoever created it) between the two port sets
	local out_id in_id link_err
	while IFS=$'\t' read -r out_id in_id; do
		[[ -n "$out_id" && -n "$in_id" ]] || continue
		[[ -v "_node_ports[$out_id]" && -v "_sink_ports[$in_id]" ]] || continue

		if link_err=$(pw-link -d "$out_id" "$in_id" 2>&1); then
			log "  Unlinked port ${out_id} → ${in_id}"
			((_UNLINK_COUNT++)) || true
		elif [[ "$link_err" != *"No such file"* && "$link_err" != *"not found"* ]]; then
			warn "  Failed to unlink port ${out_id} → ${in_id}: ${link_err}"
		fi
	done < <(jq -r '
		.[] | select(.type == "PipeWire:Interface:Link")
		| "\(.info."output-port-id")\t\(.info."input-port-id")"
	' <<<"$dump")

	# Drop our bookkeeping for this node regardless of who removed the link
	local key
	for key in "${!OUR_LINKS[@]}"; do
		[[ -v "_node_ports[${key%%|*}]" ]] && unset "OUR_LINKS[$key]"
	done
	# A final nonmatching entry is not a failure, including for vanished streams.
	return 0
}

# Create additional pw-links from a stream's output ports to our sink.
# Takes a PipeWire node object.id (numeric).  Uses port IDs for linking
# so that multiple nodes with the same node.name are handled correctly.
# This does NOT remove the WirePlumber-managed link to the default sink.
link_stream_to_sink() {
	local node_id="$1"
	local linked=false

	local dump
	dump=$(pw-dump 2>/dev/null) || return 1

	# Output ports for this specific node
	local out_ports
	out_ports=$(jq -r --argjson nid "$node_id" '
		.[] | select(.type == "PipeWire:Interface:Port"
			and .info.direction == "output"
			and .info.props."node.id" == $nid)
		| "\(.id)\t\(.info.props."port.name")"
	' <<<"$dump")
	[[ -z "$out_ports" ]] && {
		debug "No output ports for node ${node_id}"
		return 1
	}

	# Sink input ports: channel → port_id
	local -A sink_ch=()
	_build_sink_ch_map dump sink_ch || {
		warn "  Sink port lookup failed"
		return 1
	}

	local out_id out_name
	while IFS=$'\t' read -r out_id out_name; do
		[[ -z "$out_id" ]] && continue
		local channel="${out_name##*output_}"

		# Match to sink port by channel; MONO falls back to FL
		local in_id="${sink_ch["playback_${channel}"]:-}"
		[[ -z "$in_id" ]] && in_id="${sink_ch["playback_FL"]:-}"
		[[ -z "$in_id" ]] && continue

		# Already tracked by us?
		if [[ -v "OUR_LINKS[${out_id}|${in_id}]" ]]; then
			linked=true
			continue
		fi

		local link_err
		if link_err=$(pw-link "$out_id" "$in_id" 2>&1); then
			log "  Linked port ${out_id} → ${in_id}"
			OUR_LINKS["${out_id}|${in_id}"]=1
			linked=true
		elif [[ "$link_err" == *"File exists"* ]]; then
			debug "  Link already present: port ${out_id} → ${in_id}"
			linked=true
		else
			warn "  Failed to link port ${out_id} → ${in_id}: ${link_err}"
		fi
	done <<<"$out_ports"

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

# Check whether a stream is currently on a sink owned by another pipewire-audio-share
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
		done <<<"$peers"
	done <<<"$entries"

	return 1
}

# Move a stream exclusively to our virtual sink (mute-local mode).
# Uses `pactl move-sink-input` so WirePlumber treats it as intentional and
# will NOT fight to reconnect it to the default sink.
move_stream_to_sink() {
	local node_name="$1"
	local entries
	entries=$(get_sink_input_indices "$node_name")
	[[ -z "$entries" ]] && {
		debug "No sink-input found for ${node_name}"
		return 1
	}

	local entry idx current_sink current_sink_name
	local moved=false
	while IFS= read -r entry; do
		idx="${entry%%:*}"
		current_sink="${entry##*:}"
		current_sink_name=$(get_sink_name_by_index "$current_sink")

		# Already on our sink?
		[[ "$current_sink_name" == "$SINK_NAME" ]] && {
			moved=true
			continue
		}

		# Remember where it was so we can restore later
		MOVED_INPUTS["$idx"]="${current_sink_name:-$(current_default_sink)}"

		if pactl move-sink-input "$idx" "$SINK_NAME" 2>/dev/null; then
			log "  Moved sink-input #${idx} → ${SINK_NAME} (was ${current_sink_name:-?})"
			moved=true
		else
			warn "  Failed to move sink-input #${idx}"
		fi
	done <<<"$entries"

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
			if pactl move-sink-input "$idx" "$live_default" 2>/dev/null; then
				log "  Restored sink-input #${idx} → ${live_default} (fallback)"
			else
				debug "  Could not restore sink-input #${idx}"
			fi
		fi
		unset "MOVED_INPUTS[$idx]"
	done <<<"$entries"
}

# If a stream's sink-input is pinned to our virtual sink (e.g. it appeared
# while the share sink was the default output), move it back to the current
# default sink.  Without this, WirePlumber would re-link the stream to our
# sink right after we removed the links.  Unlike mute-local restore, nothing
# is remembered — the stream simply goes back to the default output.
_unpin_stream_from_sink() {
	local node_name="$1"
	local entries
	entries=$(get_sink_input_indices "$node_name") || true
	[[ -z "$entries" ]] && return 0

	local entry idx current_sink current_sink_name live_default=""
	while IFS= read -r entry; do
		[[ -z "$entry" ]] && continue
		idx="${entry%%:*}"
		current_sink="${entry##*:}"
		current_sink_name=$(get_sink_name_by_index "$current_sink")
		[[ "$current_sink_name" == "$SINK_NAME" ]] || continue
		[[ -z "$live_default" ]] && live_default=$(current_default_sink)
		# If the share sink IS the default, the pin is intentional — leave it
		[[ -z "$live_default" || "$live_default" == "$SINK_NAME" ]] && continue
		if pactl move-sink-input "$idx" "$live_default" 2>/dev/null; then
			log "  Moved sink-input #${idx} → ${live_default} (was pinned to ${SINK_NAME})"
		else
			debug "  Could not unpin sink-input #${idx} from ${SINK_NAME}"
		fi
	done <<<"$entries"
}

# ─── high-level capture / release ────────────────────────────────────────────

capture_stream() {
	local node_id="$1" node_name="$2" app_name="$3"

	if [[ "$MUTE_LOCAL" == true ]]; then
		# Check peer ownership to avoid fighting another instance
		if stream_owned_by_peer "$node_name"; then
			warn "Skipping ${app_name:-$node_name}: already owned by another pipewire-audio-share instance"
			return 1
		fi
		# Move exclusively to virtual sink (no local playback).
		if move_stream_to_sink "$node_name"; then
			CAPTURED["$node_id"]="$node_name"
			return 0
		fi
	else
		# Add supplementary link; local playback continues via WirePlumber.
		if link_stream_to_sink "$node_id"; then
			CAPTURED["$node_id"]="$node_name"
			return 0
		fi
	fi
	return 1
}

release_stream() {
	local node_id="$1"
	local node_name="${CAPTURED[$node_id]:-}"
	if [[ "$MUTE_LOCAL" == true ]]; then
		[[ -n "$node_name" ]] && restore_stream_from_sink "$node_name"
	else
		# Remove all pw-links to our virtual sink, then unpin the stream if
		# WirePlumber had routed it to our sink outright.
		unlink_stream_from_sink "$node_id"
		[[ -n "$node_name" ]] && _unpin_stream_from_sink "$node_name"
	fi
	unset "CAPTURED[$node_id]"
}

# ─── bulk operations ─────────────────────────────────────────────────────────

capture_existing_streams() {
	log "Scanning for existing audio streams …"
	local count=0

	while IFS= read -r obj; do
		[[ -z "$obj" ]] && continue
		local nid node_name app_name media_name
		nid=$(jq -r '.id // empty' <<<"$obj")
		node_name=$(jq -r '.node_name // empty' <<<"$obj")
		app_name=$(jq -r '.app_name // empty' <<<"$obj")
		media_name=$(jq -r '.media_name // empty' <<<"$obj")
		[[ -z "$nid" || -z "$node_name" ]] && continue

		if stream_matches_filter "$node_name" "$app_name" "$media_name"; then
			log "Capturing: ${_B}${app_name:-$node_name}${_N}  (${node_name})"
			capture_stream "$nid" "$node_name" "$app_name" && ((++count))
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
		local nid node_name app_name media_name
		nid=$(jq -r '.id // empty' <<<"$obj")
		node_name=$(jq -r '.node_name // empty' <<<"$obj")
		app_name=$(jq -r '.app_name // empty' <<<"$obj")
		media_name=$(jq -r '.media_name // empty' <<<"$obj")
		[[ -z "$nid" || -z "$node_name" ]] && continue

		# Already tracked (captured or previously skipped)?
		[[ -v "CAPTURED[$nid]" ]] && continue
		[[ -v "SKIPPED[$nid]" ]] && continue
		# User explicitly removed this stream via interactive menu?
		[[ -v "MANUAL_REMOVE[$nid]" ]] && continue

		# Manual add overrides filter
		if [[ -v "MANUAL_ADD[$nid]" ]]; then
			log "Auto-capturing manually added stream: ${_B}${app_name:-$node_name}${_N}"
			if ! capture_stream "$nid" "$node_name" "$app_name"; then
				SKIPPED["$nid"]=1
			fi
			continue
		fi

		if stream_matches_filter "$node_name" "$app_name" "$media_name"; then
			log "New stream: ${_B}${app_name:-$node_name}${_N}  (${node_name})"
			if ! capture_stream "$nid" "$node_name" "$app_name"; then
				# Remember we skipped it so we don't log every poll cycle
				SKIPPED["$nid"]=1
			fi
		fi
	done < <(get_audio_streams)
}

# Make sure links / moves haven't been undone (WirePlumber quirks, etc.)
verify_existing_links() {
	guard_default_sink

	local stale=()

	# Cache pw-dump once for all checks this cycle
	local _vdump
	_vdump=$(pw-dump 2>/dev/null)

	for node_id in "${!CAPTURED[@]}"; do
		local node_name="${CAPTURED[$node_id]}"

		# Has the stream vanished entirely?  Check if node still has ports.
		local _pcnt
		_pcnt=$(jq --argjson nid "$node_id" '
			[.[] | select(.type == "PipeWire:Interface:Port"
				and .info.direction == "output"
				and .info.props."node.id" == $nid)] | length
		' <<<"$_vdump")
		if [[ "${_pcnt:-0}" == "0" ]]; then
			debug "Stream gone: ${node_name} (node ${node_id})"
			stale+=("$node_id")
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
						stale+=("$node_id")
						continue 2
					fi
					debug "Re-moving ${node_name} (sink-input #${idx}) back to ${SINK_NAME}"
					MOVED_INPUTS["$idx"]="${current_sink_name:-$(current_default_sink)}"
					pactl move-sink-input "$idx" "$SINK_NAME" 2>/dev/null || true
				fi
			done <<<"$entries"
		else
			# Non-mute: verify the supplementary link still exists.
			link_stream_to_sink "$node_id" 2>/dev/null || true
		fi
	done

	for node_id in "${stale[@]}"; do
		unset "CAPTURED[$node_id]"
	done

	# Re-evaluate previously skipped streams.
	((++SKIP_RETRY_CTR))
	for node_id in "${!SKIPPED[@]}"; do
		# Stream gone? Drop the skip so it's retried if it reappears.
		local _pcnt
		_pcnt=$(jq --argjson nid "$node_id" '
			[.[] | select(.type == "PipeWire:Interface:Port"
				and .info.direction == "output"
				and .info.props."node.id" == $nid)] | length
		' <<<"$_vdump")
		if [[ "${_pcnt:-0}" == "0" ]]; then
			unset "SKIPPED[$node_id]"
			continue
		fi
		# In mute-local mode, retry if the owning peer released it.
		# (peer check still uses node_name from get_audio_streams context)
		if ((SKIP_RETRY_CTR >= SKIP_RETRY_EVERY)); then
			debug "Periodic retry for skipped stream: node ${node_id}"
			unset "SKIPPED[$node_id]"
		fi
	done
	if ((SKIP_RETRY_CTR >= SKIP_RETRY_EVERY)); then
		SKIP_RETRY_CTR=0
	fi

	# Verify routed input device links
	local stale_inputs=()
	for node_name in "${!CAPTURED_INPUTS[@]}"; do
		if ! pw-link -o 2>/dev/null | grep -q "^${node_name}:capture_"; then
			debug "Input device gone: ${node_name}"
			stale_inputs+=("$node_name")
			continue
		fi
		# Re-create links if broken
		link_input_to_sink "$node_name" 2>/dev/null || true
	done
	for node_name in "${stale_inputs[@]}"; do
		unset "CAPTURED_INPUTS[$node_name]"
	done
}

# ─── cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
	[[ "$CLEANUP_DONE" == true ]] && return
	CLEANUP_DONE=true

	# Leave TUI alternate screen before printing cleanup messages
	if [[ "$TUI_ACTIVE" == true ]]; then
		printf '\033[?25h' >&2
		printf '\033[?1049l' >&2
		TUI_ACTIVE=false
	fi

	log "Shutting down …"

	# Restore muted streams before removing the sink
	if [[ "$MUTE_LOCAL" == true ]]; then
		log "Restoring streams to default output …"
		for nid in "${!CAPTURED[@]}"; do
			local node_name="${CAPTURED[$nid]}"
			restore_stream_from_sink "$node_name"
		done
	fi

	# Belt-and-suspenders: move any sink-inputs that were hijacked onto our
	# sink back to the default output.
	_sweep_strays_from_sink

	# Restore the original default source before removing the virtual source
	if [[ "$SET_DEFAULT_SOURCE" == true && -n "$ORIGINAL_DEFAULT_SOURCE" ]]; then
		log "Restoring default input device → ${ORIGINAL_DEFAULT_SOURCE}"
		pactl set-default-source "$ORIGINAL_DEFAULT_SOURCE" 2>/dev/null || true
	fi

	# If our sink is still the default output, hand the default back to the
	# real output device before unloading, so the session manager does not
	# pick a random fallback.
	if [[ "$(pactl get-default-sink 2>/dev/null || true)" == "$SINK_NAME" ]]; then
		local restore_target="${LAST_KNOWN_DEFAULT:-$STARTUP_DEFAULT_SINK}"
		if [[ -n "$restore_target" && "$restore_target" != "$SINK_NAME" ]]; then
			log "Restoring default sink → ${restore_target}"
			pactl set-default-sink "$restore_target" 2>/dev/null || true
		fi
	fi

	# Release routed input devices
	if ((${#CAPTURED_INPUTS[@]} > 0)); then
		log "Unrouting input devices …"
		for node_name in "${!CAPTURED_INPUTS[@]}"; do
			unlink_input_from_sink "$node_name"
		done
		CAPTURED_INPUTS=()
	fi

	remove_source
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

# ─── interactive TUI ────────────────────────────────────────────────────────
# Only used when -i/--interactive is passed and stdin/stderr are a TTY.

# ── TUI terminal helpers ──

tui_init() {
	printf '\033[?1049h' >&2 # enter alternate screen buffer
	printf '\033[?25l' >&2   # hide cursor
	TUI_ACTIVE=true
}

tui_fini() {
	printf '\033[?25h' >&2   # show cursor
	printf '\033[?1049l' >&2 # leave alternate screen buffer
	TUI_ACTIVE=false
}

tui_clear() { printf '\033[2J\033[H' >&2; }
tui_goto() { printf '\033[%d;%dH' "$1" "$2" >&2; } # row col (1-based)
tui_el() { printf '\033[K' >&2; }                  # erase to end of line
tui_show_cursor() { printf '\033[?25h' >&2; }
tui_hide_cursor() { printf '\033[?25l' >&2; }

# Prompt on the controlling terminal. The result is returned in TUI_REPLY.
TUI_REPLY=""
tui_prompt() {
	local prompt="$1"
	tui_show_cursor
	printf '\n  %s' "$prompt" >&2
	TUI_REPLY=""
	IFS= read -r TUI_REPLY </dev/tty 2>/dev/null || true
	tui_hide_cursor
}

tui_size() {
	TERM_COLS=$(tput cols 2>/dev/null || echo 80)
}

# Read a single key press.  Returns the key as a string via stdout.
# Special keys: UP DOWN LEFT RIGHT ESC ENTER BACKSPACE
# Returns 1 on timeout.
tui_read_key() {
	local timeout="${1:-0}"
	local key=""
	if ((timeout > 0)); then
		IFS= read -rsn1 -t "$timeout" key 2>/dev/null || return 1
	else
		IFS= read -rsn1 key 2>/dev/null || return 1
	fi
	if [[ "$key" == $'\033' ]]; then
		local seq="" code=""
		IFS= read -rsn1 -t 0.05 seq 2>/dev/null || true
		if [[ "$seq" == "[" ]]; then
			IFS= read -rsn1 -t 0.05 code 2>/dev/null || true
			case "$code" in
			A)
				printf 'UP'
				return 0
				;;
			B)
				printf 'DOWN'
				return 0
				;;
			C)
				printf 'RIGHT'
				return 0
				;;
			D)
				printf 'LEFT'
				return 0
				;;
			esac
		fi
		printf 'ESC'
		return 0
	elif [[ "$key" == "" ]]; then
		printf 'ENTER'
		return 0
	elif [[ "$key" == $'\177' || "$key" == $'\b' ]]; then
		printf 'BACKSPACE'
		return 0
	fi
	printf '%s' "$key"
}

# ── TUI drawing primitives ──

# Print a coloured header line.
tui_header() {
	local title="$1"
	tui_size
	printf '%b  pipewire-audio-share' "$_B" >&2
	[[ -n "$title" ]] && printf ' ▸ %s' "$title" >&2
	printf '%b\n' "$_N" >&2
	local i
	printf '  ' >&2
	for ((i = 0; i < TERM_COLS - 4; i++)); do printf '━' >&2; done
	printf '\n' >&2
}

# Print a hotkey hint: tui_hint "key" "label"
tui_hint() {
	printf '  %b[%s]%b %s' "$_Y" "$1" "$_N" "$2" >&2
}

# Print a horizontal rule.
tui_rule() {
	tui_size
	printf '  ' >&2
	local i
	for ((i = 0; i < TERM_COLS - 4; i++)); do printf '─' >&2; done
	printf '\n' >&2
}

# Render a volume bar.  Usage: tui_volume_bar <percent> [width]
tui_volume_bar() {
	local pct="${1:-0}" width="${2:-20}"
	((pct < 0)) && pct=0
	local filled=$((pct * width / 100))
	((filled > width)) && filled=$width
	local empty=$((width - filled))

	local color="$_G"
	((pct > 60)) && color="$_Y"
	((pct > 85)) && color="$_R"

	printf '%b' "$color" >&2
	local i
	for ((i = 0; i < filled; i++)); do printf '█' >&2; done
	printf '%b' "$_D" >&2
	for ((i = 0; i < empty; i++)); do printf '░' >&2; done
	printf '%b %3d%%%b' "$color" "$pct" "$_N" >&2
}

# Show recent TUI messages (warnings/errors) at the bottom.
tui_show_messages() {
	if ((${#TUI_MESSAGES[@]} > 0)); then
		printf '\n' >&2
		local msg
		for msg in "${TUI_MESSAGES[@]}"; do
			printf '  %b%s%b\n' "$_Y" "$msg" "$_N" >&2
		done
	fi
}

# ── TUI data helpers ──

# Get volume percentage for a pactl sink (first channel).
tui_get_sink_volume() {
	local sink="$1"
	pactl get-sink-volume "$sink" 2>/dev/null |
		awk '{for(i=1;i<=NF;i++) if($i ~ /%/) {gsub(/%/,"",$i); print $i+0; exit}}'
}

# Get mute state for a pactl sink → "yes" or "no".
tui_get_sink_mute() {
	pactl get-sink-mute "$1" 2>/dev/null | awk '{print $2}'
}

# Get volume percentage for a sink-input by pactl index.
tui_get_input_volume_by_idx() {
	local target_idx="$1"
	pactl list sink-inputs 2>/dev/null | awk -v idx="$target_idx" '
		/^Sink Input #/ { cur=$3; gsub(/#/,"",cur); vol="" }
		/^\tVolume:/ {
			for(i=1;i<=NF;i++) if($i ~ /%/) {gsub(/%/,"",$i); vol=$i+0; break}
		}
		/^\tMute:/ && cur==idx { mute=$2 }
		/node\.name =/ && cur==idx { if(vol!="") print vol; exit }
	'
}

# Get mute state for a sink-input by pactl index → "yes" or "no".
tui_get_input_mute_by_idx() {
	local target_idx="$1"
	pactl list sink-inputs 2>/dev/null | awk -v idx="$target_idx" '
		/^Sink Input #/ { cur=$3; gsub(/#/,"",cur); mute="" }
		/^\tMute:/ && cur==idx { print $2; exit }
	'
}

# Get the first pactl sink-input index for a given node_name.
tui_get_input_idx() {
	local target="$1"
	pactl list sink-inputs 2>/dev/null | awk -v t="$target" '
		/^Sink Input #/ { idx=$3; gsub(/#/,"",idx) }
		/node\.name =/ {
			val=$0; gsub(/.*= "/,"",val); gsub(/".*/,"",val)
			if(val==t) { print idx; exit }
		}
	'
}

# Collect all audio streams as an indexed bash array of tab-separated records:
#   node_id \t node_name \t app_name \t status \t media_name
# Status: captured | available | filtered | removed | skipped
# Sets: _TUI_STREAMS=( ... ) and _TUI_STREAM_COUNT
declare -a _TUI_STREAMS=()
_TUI_STREAM_COUNT=0

tui_refresh_streams() {
	_TUI_STREAMS=()
	_TUI_STREAM_COUNT=0
	while IFS= read -r obj; do
		[[ -z "$obj" ]] && continue
		local nid nn an mn
		nid=$(jq -r '.id // empty' <<<"$obj")
		nn=$(jq -r '.node_name // empty' <<<"$obj")
		an=$(jq -r '.app_name  // empty' <<<"$obj")
		mn=$(jq -r '.media_name // empty' <<<"$obj")
		[[ -z "$nid" || -z "$nn" ]] && continue
		[[ "$nn" == "${SINK_NAME}"* ]] && continue

		local st="available"
		if [[ -v "CAPTURED[$nid]" ]]; then
			st="captured"
		elif [[ -v "MANUAL_REMOVE[$nid]" ]]; then
			st="removed"
		elif [[ -v "SKIPPED[$nid]" ]]; then
			st="skipped"
		elif ! stream_matches_filter "$nn" "$an" "$mn"; then
			st="filtered"
		fi

		_TUI_STREAMS+=("${nid}	${nn}	${an}	${st}	${mn}")
		((++_TUI_STREAM_COUNT))
	done < <(get_audio_streams)
}

# Collect all hardware sinks.  Sets: _TUI_SINKS=( "name \t description" ... )
declare -a _TUI_SINKS=()

tui_refresh_sinks() {
	_TUI_SINKS=()
	local line
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		_TUI_SINKS+=("$line")
	done < <(pactl list sinks 2>/dev/null | awk '
		/^\tName:/ { name=$2 }
		/^\tDescription:/ {
			desc=$0; gsub(/^\tDescription: /,"",desc)
			print name "\t" desc
		}
	')
}

# ── TUI menu: Streams ──

tui_menu_streams() {
	local sel=0
	while true; do
		tui_refresh_streams
		tui_clear
		tui_header "Streams"
		printf '\n' >&2

		if ((_TUI_STREAM_COUNT == 0)); then
			printf '  %b(no audio streams playing)%b\n' "$_D" "$_N" >&2
		else
			local i
			for ((i = 0; i < _TUI_STREAM_COUNT; i++)); do
				local rec="${_TUI_STREAMS[$i]}"
				local nid nn an st mn
				IFS=$'\t' read -r nid nn an st mn <<<"$rec"
				local label="${an:-$nn}"
				if [[ -n "$mn" && "$mn" != "$an" && "$mn" != "$nn" ]]; then
					label="${label} — ${mn}"
				fi

				local marker color suffix
				case "$st" in
				captured)
					marker="●"
					color="$_G"
					suffix=""
					;;
				available)
					marker="○"
					color="$_N"
					suffix=""
					;;
				filtered)
					marker="○"
					color="$_D"
					suffix=" (filtered)"
					;;
				removed)
					marker="⊘"
					color="$_D"
					suffix=" (manual remove)"
					;;
				skipped)
					marker="⊘"
					color="$_Y"
					suffix=" (peer-owned)"
					;;
				*)
					marker="?"
					color="$_D"
					suffix=""
					;;
				esac

				local ptr="  "
				((i == sel)) && ptr="▸ "

				printf '  %s%b%s %d. %-40s%s%b\n' \
					"$ptr" "$color" "$marker" $((i + 1)) "$label" "$suffix" "$_N" >&2
			done
		fi

		printf '\n' >&2
		tui_rule
		tui_hint "↑↓" "navigate"
		tui_hint "Space" "toggle"
		tui_hint "a" "add all"
		tui_hint "r" "release all"
		printf '\n' >&2
		tui_hint "b/Esc" "back"
		printf '\n' >&2
		tui_show_messages

		local key
		key=$(tui_read_key "$POLL_INTERVAL") || {
			[[ "$AUTO_CAPTURE" == true ]] && scan_new_streams
			verify_existing_links
			continue
		}

		case "$key" in
		UP)
			((sel > 0)) && ((sel--))
			;;
		DOWN)
			((sel < _TUI_STREAM_COUNT - 1)) && ((sel++)) || true
			;;
		' ' | ENTER)
			((_TUI_STREAM_COUNT > 0)) || continue
			local rec="${_TUI_STREAMS[$sel]}"
			local nid nn an st mn
			IFS=$'\t' read -r nid nn an st mn <<<"$rec"
			if [[ "$st" == "captured" ]]; then
				release_stream "$nid"
				MANUAL_REMOVE["$nid"]=1
				unset "MANUAL_ADD[$nid]"
				if ((_UNLINK_COUNT > 0)); then
					_tui_push_msg "Released: ${an:-$nn} (${_UNLINK_COUNT} links removed)"
				else
					_tui_push_msg "Released: ${an:-$nn} (no links found to remove!)"
				fi
			else
				unset "MANUAL_REMOVE[$nid]"
				unset "SKIPPED[$nid]"
				MANUAL_ADD["$nid"]=1
				capture_stream "$nid" "$nn" "${an:-}" || _tui_push_msg "Could not capture: ${an:-$nn}"
			fi
			;;
		[1-9])
			local idx=$((key - 1))
			if ((idx < _TUI_STREAM_COUNT)); then
				sel=$idx
				local rec="${_TUI_STREAMS[$sel]}"
				local nid nn an st mn
				IFS=$'\t' read -r nid nn an st mn <<<"$rec"
				if [[ "$st" == "captured" ]]; then
					release_stream "$nid"
					MANUAL_REMOVE["$nid"]=1
					unset "MANUAL_ADD[$nid]"
					if ((_UNLINK_COUNT > 0)); then
						_tui_push_msg "Released: ${an:-$nn} (${_UNLINK_COUNT} links removed)"
					else
						_tui_push_msg "Released: ${an:-$nn} (no links found!)"
					fi
				else
					unset "MANUAL_REMOVE[$nid]"
					unset "SKIPPED[$nid]"
					MANUAL_ADD["$nid"]=1
					capture_stream "$nid" "$nn" "${an:-}" || _tui_push_msg "Could not capture: ${an:-$nn}"
				fi
			fi
			;;
		a | A)
			tui_refresh_streams
			local i
			for ((i = 0; i < _TUI_STREAM_COUNT; i++)); do
				local rec="${_TUI_STREAMS[$i]}"
				local nid nn an st mn
				IFS=$'\t' read -r nid nn an st mn <<<"$rec"
				if [[ "$st" != "captured" ]]; then
					unset "MANUAL_REMOVE[$nid]"
					unset "SKIPPED[$nid]"
					MANUAL_ADD["$nid"]=1
					capture_stream "$nid" "$nn" "${an:-}" || true
				fi
			done
			_tui_push_msg "Added all streams"
			;;
		r | R)
			local total_unlinked=0
			for nid in "${!CAPTURED[@]}"; do
				release_stream "$nid"
				MANUAL_REMOVE["$nid"]=1
				unset "MANUAL_ADD[$nid]"
				((total_unlinked += _UNLINK_COUNT)) || true
			done
			_tui_push_msg "Released all streams (${total_unlinked} links removed)"
			;;
		b | B | ESC | q | Q)
			return
			;;
		esac
	done
}

# ── TUI menu: Volume ──

tui_menu_volume() {
	local sel=0 # 0 = sink, 1+ = captured streams
	while true; do
		tui_clear
		tui_header "Volume"
		printf '\n' >&2

		# Build list: first entry is the virtual sink, then captured streams
		local -a vol_names=() vol_labels=() vol_types=() # type: sink | input
		local -a vol_idxs=()                             # pactl index for inputs, sink name for sinks

		vol_names+=("$SINK_NAME")
		vol_labels+=("Sink: ${SINK_DESCRIPTION}")
		vol_types+=("sink")
		vol_idxs+=("$SINK_NAME")

		for nid in "${!CAPTURED[@]}"; do
			local nn="${CAPTURED[$nid]}"
			local an="" mn="" idx=""
			# Get a display name from the current stream data
			while IFS= read -r obj; do
				[[ -z "$obj" ]] && continue
				local n a m
				n=$(jq -r '.node_name // empty' <<<"$obj")
				a=$(jq -r '.app_name  // empty' <<<"$obj")
				m=$(jq -r '.media_name // empty' <<<"$obj")
				if [[ "$n" == "$nn" ]]; then
					an="$a"
					mn="$m"
					break
				fi
			done < <(get_audio_streams)
			idx=$(tui_get_input_idx "$nn")
			[[ -z "$idx" ]] && continue
			vol_names+=("$nn")
			local vlabel="${an:-$nn}"
			if [[ -n "$mn" && "$mn" != "$an" && "$mn" != "$nn" ]]; then
				vlabel="${vlabel} — ${mn}"
			fi
			vol_labels+=("$vlabel")
			vol_types+=("input")
			vol_idxs+=("$idx")
		done

		local total=${#vol_names[@]}
		((sel >= total)) && sel=$((total - 1))
		((sel < 0)) && sel=0

		local i
		for ((i = 0; i < total; i++)); do
			local ptr="  "
			((i == sel)) && ptr="▸ "

			local pct=0 muted="no"
			if [[ "${vol_types[$i]}" == "sink" ]]; then
				pct=$(tui_get_sink_volume "${vol_idxs[$i]}")
				muted=$(tui_get_sink_mute "${vol_idxs[$i]}")
			else
				pct=$(tui_get_input_volume_by_idx "${vol_idxs[$i]}")
				muted=$(tui_get_input_mute_by_idx "${vol_idxs[$i]}")
			fi
			pct="${pct:-0}"
			muted="${muted:-no}"

			local label="${vol_labels[$i]}"
			local mute_tag=""
			[[ "$muted" == "yes" ]] && mute_tag=" ${_R}[MUTED]${_N}"

			printf '  %s%b%s%b%s\n' "$ptr" "$_B" "$label" "$_N" "$mute_tag" >&2
			printf '    ' >&2
			tui_volume_bar "$pct" 24
			printf '\n' >&2
		done

		printf '\n' >&2
		tui_rule
		tui_hint "↑↓" "select"
		tui_hint "←→" "±5%%"
		tui_hint "[/]" "±1%%"
		printf '\n' >&2
		tui_hint "0" "mute/unmute"
		tui_hint "b/Esc" "back"
		printf '\n' >&2
		tui_show_messages

		local key
		key=$(tui_read_key "$POLL_INTERVAL") || {
			[[ "$AUTO_CAPTURE" == true ]] && scan_new_streams
			verify_existing_links
			continue
		}

		case "$key" in
		UP) ((sel > 0)) && ((sel--)) ;;
		DOWN) ((sel < total - 1)) && ((sel++)) || true ;;
		RIGHT)
			if [[ "${vol_types[$sel]}" == "sink" ]]; then
				pactl set-sink-volume "${vol_idxs[$sel]}" +5% 2>/dev/null
			else
				pactl set-sink-input-volume "${vol_idxs[$sel]}" +5% 2>/dev/null
			fi
			;;
		LEFT)
			if [[ "${vol_types[$sel]}" == "sink" ]]; then
				pactl set-sink-volume "${vol_idxs[$sel]}" -5% 2>/dev/null
			else
				pactl set-sink-input-volume "${vol_idxs[$sel]}" -5% 2>/dev/null
			fi
			;;
		']')
			if [[ "${vol_types[$sel]}" == "sink" ]]; then
				pactl set-sink-volume "${vol_idxs[$sel]}" +1% 2>/dev/null
			else
				pactl set-sink-input-volume "${vol_idxs[$sel]}" +1% 2>/dev/null
			fi
			;;
		'[')
			if [[ "${vol_types[$sel]}" == "sink" ]]; then
				pactl set-sink-volume "${vol_idxs[$sel]}" -1% 2>/dev/null
			else
				pactl set-sink-input-volume "${vol_idxs[$sel]}" -1% 2>/dev/null
			fi
			;;
		0)
			if [[ "${vol_types[$sel]}" == "sink" ]]; then
				pactl set-sink-mute "${vol_idxs[$sel]}" toggle 2>/dev/null
			else
				pactl set-sink-input-mute "${vol_idxs[$sel]}" toggle 2>/dev/null
			fi
			;;
		b | B | ESC | q | Q)
			return
			;;
		esac
	done
}

# ── TUI menu: Output ──

tui_menu_output() {
	local sel=0
	while true; do
		tui_refresh_sinks
		local cur_default
		cur_default=$(current_default_sink)

		tui_clear
		tui_header "Output"
		printf '\n' >&2

		printf '  Mute local: ' >&2
		if [[ "$MUTE_LOCAL" == true ]]; then
			printf '%b ON%b  (captured streams silent locally)\n' "$_R" "$_N" >&2
		else
			printf '%b OFF%b (captured streams also play locally)\n' "$_G" "$_N" >&2
		fi
		printf '\n' >&2

		printf '  %bDefault output sink:%b\n' "$_B" "$_N" >&2
		local total=${#_TUI_SINKS[@]}
		((sel >= total)) && sel=$((total - 1))
		((sel < 0)) && sel=0

		local i
		for ((i = 0; i < total; i++)); do
			local rec="${_TUI_SINKS[$i]}"
			local sname sdesc
			IFS=$'\t' read -r sname sdesc <<<"$rec"

			local ptr="  "
			((i == sel)) && ptr="▸ "
			local marker="  "
			[[ "$sname" == "$cur_default" ]] && marker="* "
			local extra=""
			[[ "$sname" == "$SINK_NAME" ]] && extra=" ${_C}(virtual sink)${_N}"

			printf '  %s%s%d. %s%s\n' "$ptr" "$marker" $((i + 1)) "$sdesc" "$extra" >&2
		done

		printf '\n' >&2
		tui_rule
		tui_hint "↑↓" "navigate"
		tui_hint "Enter" "set as default"
		tui_hint "m" "toggle mute-local"
		printf '\n' >&2
		tui_hint "b/Esc" "back"
		printf '\n' >&2
		tui_show_messages

		local key
		key=$(tui_read_key "$POLL_INTERVAL") || {
			[[ "$AUTO_CAPTURE" == true ]] && scan_new_streams
			verify_existing_links
			continue
		}

		case "$key" in
		UP) ((sel > 0)) && ((sel--)) ;;
		DOWN) ((sel < total - 1)) && ((sel++)) || true ;;
		ENTER | ' ')
			if ((total > 0)); then
				local rec="${_TUI_SINKS[$sel]}"
				local sname sdesc
				IFS=$'\t' read -r sname sdesc <<<"$rec"
				if pactl set-default-sink "$sname" 2>/dev/null; then
					[[ "$sname" == "$SINK_NAME" ]] && DEFAULT_SHARE_BY_USER=true
					_tui_push_msg "Default sink → ${sdesc}"
				else
					_tui_push_msg "Failed to set default sink"
				fi
			fi
			;;
		[1-9])
			local idx=$((key - 1))
			if ((idx < total)); then
				sel=$idx
				local rec="${_TUI_SINKS[$sel]}"
				local sname sdesc
				IFS=$'\t' read -r sname sdesc <<<"$rec"
				if pactl set-default-sink "$sname" 2>/dev/null; then
					[[ "$sname" == "$SINK_NAME" ]] && DEFAULT_SHARE_BY_USER=true
					_tui_push_msg "Default sink → ${sdesc}"
				else
					_tui_push_msg "Failed to set default sink"
				fi
			fi
			;;
		m | M)
			if [[ "$MUTE_LOCAL" == true ]]; then
				for nid in "${!CAPTURED[@]}"; do
					local nn="${CAPTURED[$nid]}"
					restore_stream_from_sink "$nn"
					link_stream_to_sink "$nid" 2>/dev/null || true
				done
				MOVED_INPUTS=()
				MUTE_LOCAL=false
				_tui_push_msg "Mute local → OFF"
			else
				MUTE_LOCAL=true
				for nid in "${!CAPTURED[@]}"; do
					local nn="${CAPTURED[$nid]}"
					move_stream_to_sink "$nn" || true
				done
				_tui_push_msg "Mute local → ON"
			fi
			;;
		b | B | ESC | q | Q)
			return
			;;
		esac
	done
}

# ── TUI menu: Config ──

tui_menu_config() {
	while true; do
		tui_clear
		tui_header "Config"
		printf '\n' >&2

		printf '  %b[a]%b Auto-capture:   ' "$_Y" "$_N" >&2
		if [[ "$AUTO_CAPTURE" == true ]]; then
			printf '%bON%b\n' "$_G" "$_N" >&2
		else
			printf '%bOFF%b\n' "$_R" "$_N" >&2
		fi

		printf '  %b[m]%b Mute local:     ' "$_Y" "$_N" >&2
		if [[ "$MUTE_LOCAL" == true ]]; then
			printf '%bON%b\n' "$_R" "$_N" >&2
		else
			printf '%bOFF%b\n' "$_G" "$_N" >&2
		fi

		printf '  %b[p]%b Poll interval:  %ss\n' "$_Y" "$_N" "$POLL_INTERVAL" >&2

		printf '  %b[s]%b Source device:  ' "$_Y" "$_N" >&2
		if [[ "$CREATE_SOURCE" == true ]]; then
			printf '%bON%b (%s)\n' "$_G" "$_N" "$SOURCE_NAME" >&2
		else
			printf '%bOFF%b\n' "$_R" "$_N" >&2
		fi

		printf '  %b[d]%b Default source: ' "$_Y" "$_N" >&2
		if [[ "$SET_DEFAULT_SOURCE" == true ]]; then
			printf '%bON%b\n' "$_G" "$_N" >&2
		else
			printf '%bOFF%b\n' "$_R" "$_N" >&2
		fi

		printf '\n' >&2
		if ((${#INCLUDE[@]} > 0)); then
			printf '  Include: %s\n' "${INCLUDE[*]}" >&2
		else
			printf '  Include: %b(none)%b\n' "$_D" "$_N" >&2
		fi
		printf '  %b[w]%b Edit include\n' "$_Y" "$_N" >&2

		printf '\n' >&2
		if ((${#EXCLUDE[@]} > 0)); then
			printf '  Exclude: %s\n' "${EXCLUDE[*]}" >&2
		else
			printf '  Exclude: %b(none)%b\n' "$_D" "$_N" >&2
		fi
		printf '  %b[e]%b Edit exclude\n' "$_Y" "$_N" >&2

		printf '\n' >&2
		printf '  Sink name: %b%s%b\n' "$_B" "$SINK_NAME" "$_N" >&2
		printf '  Description: %s\n' "$SINK_DESCRIPTION" >&2

		printf '\n' >&2
		tui_rule
		tui_hint "b/Esc" "back"
		printf '\n' >&2
		tui_show_messages

		local key
		key=$(tui_read_key "$POLL_INTERVAL") || {
			[[ "$AUTO_CAPTURE" == true ]] && scan_new_streams
			verify_existing_links
			continue
		}

		case "$key" in
		a | A)
			if [[ "$AUTO_CAPTURE" == true ]]; then
				AUTO_CAPTURE=false
				_tui_push_msg "Auto-capture → OFF"
			else
				AUTO_CAPTURE=true
				_tui_push_msg "Auto-capture → ON"
			fi
			;;
		m | M)
			if [[ "$MUTE_LOCAL" == true ]]; then
				for nid in "${!CAPTURED[@]}"; do
					local nn="${CAPTURED[$nid]}"
					restore_stream_from_sink "$nn"
					link_stream_to_sink "$nid" 2>/dev/null || true
				done
				MOVED_INPUTS=()
				MUTE_LOCAL=false
				_tui_push_msg "Mute local → OFF"
			else
				MUTE_LOCAL=true
				for nid in "${!CAPTURED[@]}"; do
					local nn="${CAPTURED[$nid]}"
					move_stream_to_sink "$nn" || true
				done
				_tui_push_msg "Mute local → ON"
			fi
			;;
		s | S)
			if [[ "$CREATE_SOURCE" == true ]]; then
				if [[ "$SET_DEFAULT_SOURCE" == true && -n "$ORIGINAL_DEFAULT_SOURCE" ]]; then
					pactl set-default-source "$ORIGINAL_DEFAULT_SOURCE" 2>/dev/null || true
					SET_DEFAULT_SOURCE=false
				fi
				remove_source
				CREATE_SOURCE=false
				write_pid_file
				_tui_push_msg "Source device → OFF"
			else
				CREATE_SOURCE=true
				[[ -z "$SOURCE_NAME" || "$SOURCE_NAME" == "" ]] && SOURCE_NAME="${SINK_NAME}_input"
				[[ -z "$SOURCE_DESCRIPTION" || "$SOURCE_DESCRIPTION" == "" ]] && SOURCE_DESCRIPTION="${SINK_DESCRIPTION} Input"
				if create_source; then
					_tui_push_msg "Source device → ON (${SOURCE_NAME})"
				else
					CREATE_SOURCE=false
					_tui_push_msg "Failed to create source device"
				fi
			fi
			;;
		d | D)
			if [[ "$CREATE_SOURCE" != true || -z "$SOURCE_MODULE_ID" ]]; then
				_tui_push_msg "Enable source device first (s)"
			elif [[ "$SET_DEFAULT_SOURCE" == true ]]; then
				if [[ -n "$ORIGINAL_DEFAULT_SOURCE" ]]; then
					pactl set-default-source "$ORIGINAL_DEFAULT_SOURCE" 2>/dev/null || true
				fi
				SET_DEFAULT_SOURCE=false
				_tui_push_msg "Default source → OFF (restored previous)"
			else
				ORIGINAL_DEFAULT_SOURCE=$(pactl get-default-source 2>/dev/null || true)
				if pactl set-default-source "$SOURCE_NAME" 2>/dev/null; then
					SET_DEFAULT_SOURCE=true
					_tui_push_msg "Default source → ON"
				else
					_tui_push_msg "Failed to set default source"
				fi
			fi
			;;
		p | P)
			tui_prompt "New poll interval (seconds): "
			local new_val="$TUI_REPLY"
			if [[ "$new_val" =~ ^[0-9]+\.?[0-9]*$ ]] && [[ "$new_val" != "0" ]]; then
				POLL_INTERVAL="$new_val"
				_tui_push_msg "Poll interval → ${new_val}s"
			else
				[[ -n "$new_val" ]] && _tui_push_msg "Invalid interval: ${new_val}"
			fi
			;;
		w | W)
			tui_prompt "Include (comma-separated, empty to clear): "
			local new_val="$TUI_REPLY"
			if [[ -z "$new_val" ]]; then
				INCLUDE=()
				_tui_push_msg "Include cleared"
			else
				IFS=',' read -ra INCLUDE <<<"$new_val"
				EXCLUDE=()
				_tui_push_msg "Include → ${INCLUDE[*]}"
			fi
			;;
		e | E)
			tui_prompt "Exclude (comma-separated, empty to clear): "
			local new_val="$TUI_REPLY"
			if [[ -z "$new_val" ]]; then
				EXCLUDE=()
				_tui_push_msg "Exclude cleared"
			else
				IFS=',' read -ra EXCLUDE <<<"$new_val"
				INCLUDE=()
				_tui_push_msg "Exclude → ${EXCLUDE[*]}"
			fi
			;;
		b | B | ESC | q | Q)
			return
			;;
		esac
	done
}

# ── TUI menu: Info ──

tui_menu_info() {
	while true; do
		tui_clear
		tui_header "Info"
		printf '\n' >&2

		printf '  %bSink%b\n' "$_B" "$_N" >&2
		printf '    Name:         %s\n' "$SINK_NAME" >&2
		printf '    Description:  %s\n' "$SINK_DESCRIPTION" >&2
		printf '    Module ID:    %s\n' "${MODULE_ID:-(reused)}" >&2
		printf '    PID:          %s\n' "$$" >&2
		printf '\n' >&2

		printf '  %bSource%b\n' "$_B" "$_N" >&2
		if [[ "$CREATE_SOURCE" == true && -n "$SOURCE_MODULE_ID" ]]; then
			printf '    Name:         %s\n' "$SOURCE_NAME" >&2
			printf '    Description:  %s\n' "$SOURCE_DESCRIPTION" >&2
			printf '    Node ID:      %s\n' "$SOURCE_MODULE_ID" >&2
			printf '    Default:      %s\n' "$SET_DEFAULT_SOURCE" >&2
			if [[ "$SET_DEFAULT_SOURCE" == true ]]; then
				printf '    Previous:     %s\n' "${ORIGINAL_DEFAULT_SOURCE:-(none)}" >&2
			fi
		else
			printf '    %b(disabled — use -S or toggle in Config)%b\n' "$_D" "$_N" >&2
		fi
		printf '\n' >&2

		printf '  %bRouting%b\n' "$_B" "$_N" >&2
		printf '    Default sink: %s\n' "$(current_default_sink)" >&2
		printf '    Auto-capture: %s\n' "$AUTO_CAPTURE" >&2
		printf '    Mute local:   %s\n' "$MUTE_LOCAL" >&2
		printf '\n' >&2

		printf '  %bCaptured streams (%d)%b\n' "$_B" "${#CAPTURED[@]}" "$_N" >&2
		if ((${#CAPTURED[@]} > 0)); then
			local nid
			for nid in "${!CAPTURED[@]}"; do
				printf '    ● %s\n' "${CAPTURED[$nid]}" >&2
			done
		else
			printf '    %b(none)%b\n' "$_D" "$_N" >&2
		fi
		printf '\n' >&2

		printf '  %bRouted inputs (%d)%b\n' "$_B" "${#CAPTURED_INPUTS[@]}" "$_N" >&2
		if ((${#CAPTURED_INPUTS[@]} > 0)); then
			local nn
			for nn in "${!CAPTURED_INPUTS[@]}"; do
				printf '    ● %s\n' "$nn" >&2
			done
		else
			printf '    %b(none)%b\n' "$_D" "$_N" >&2
		fi
		printf '\n' >&2

		# Show other instances
		printf '  %bInstances%b\n' "$_B" "$_N" >&2
		local f found_any=false
		for f in "$RUNTIME_DIR"/*.pid; do
			[[ -f "$f" ]] || continue
			found_any=true
			local iname
			iname=$(basename "$f" .pid)
			if read_pid_file "$f"; then
				local status="running"
				pid_alive "$_PF_PID" || status="STALE"
				local marker="  "
				[[ "$iname" == "$SINK_NAME" ]] && marker="→ "
				printf '    %s%-20s  PID %-8s  %s\n' "$marker" "$iname" "$_PF_PID" "$status" >&2
			fi
		done
		if [[ "$found_any" == false ]]; then
			printf '    %b(none)%b\n' "$_D" "$_N" >&2
		fi

		printf '\n' >&2
		tui_rule
		tui_hint "b/Esc" "back"
		printf '\n' >&2
		tui_show_messages

		local key
		key=$(tui_read_key "$POLL_INTERVAL") || {
			[[ "$AUTO_CAPTURE" == true ]] && scan_new_streams
			verify_existing_links
			continue
		}
		case "$key" in
		b | B | ESC | q | Q | ENTER) return ;;
		esac
	done
}

# ── TUI menu: Inputs ──

declare -a _TUI_INPUTS=()
_TUI_INPUT_COUNT=0

tui_refresh_inputs() {
	_TUI_INPUTS=()
	_TUI_INPUT_COUNT=0
	while IFS= read -r obj; do
		[[ -z "$obj" ]] && continue
		local nn desc
		nn=$(jq -r '.node_name // empty' <<<"$obj")
		desc=$(jq -r '.description // empty' <<<"$obj")
		[[ -z "$nn" ]] && continue
		# Skip our own virtual source
		[[ -n "$SOURCE_NAME" && "$nn" == "$SOURCE_NAME" ]] && continue

		local st="available"
		[[ -v "CAPTURED_INPUTS[$nn]" ]] && st="routed"

		_TUI_INPUTS+=("${nn}	${desc}	${st}")
		((++_TUI_INPUT_COUNT))
	done < <(get_input_devices)
}

tui_menu_inputs() {
	local sel=0
	while true; do
		tui_refresh_inputs
		tui_clear
		tui_header "Inputs"
		printf '\n' >&2

		if ((_TUI_INPUT_COUNT == 0)); then
			printf '  %b(no input devices found)%b\n' "$_D" "$_N" >&2
		else
			local i
			for ((i = 0; i < _TUI_INPUT_COUNT; i++)); do
				local rec="${_TUI_INPUTS[$i]}"
				local nn desc st
				IFS=$'\t' read -r nn desc st <<<"$rec"
				local label="${desc:-$nn}"

				local marker color
				case "$st" in
				routed)
					marker="●"
					color="$_G"
					;;
				*)
					marker="○"
					color="$_N"
					;;
				esac

				local ptr="  "
				((i == sel)) && ptr="▸ "

				printf '  %s%b%s %d. %s%b\n' \
					"$ptr" "$color" "$marker" $((i + 1)) "$label" "$_N" >&2
			done
		fi

		printf '\n' >&2
		tui_rule
		tui_hint "↑↓" "navigate"
		tui_hint "Space" "toggle"
		tui_hint "a" "route all"
		tui_hint "n" "unroute all"
		printf '\n' >&2
		tui_hint "b/Esc" "back"
		printf '\n' >&2
		tui_show_messages

		local key
		key=$(tui_read_key "$POLL_INTERVAL") || {
			[[ "$AUTO_CAPTURE" == true ]] && scan_new_streams
			verify_existing_links
			continue
		}

		case "$key" in
		UP)
			((sel > 0)) && ((sel--))
			;;
		DOWN)
			((sel < _TUI_INPUT_COUNT - 1)) && ((sel++)) || true
			;;
		' ' | ENTER)
			((_TUI_INPUT_COUNT > 0)) || continue
			local rec="${_TUI_INPUTS[$sel]}"
			local nn desc st
			IFS=$'\t' read -r nn desc st <<<"$rec"
			if [[ "$st" == "routed" ]]; then
				unlink_input_from_sink "$nn"
				unset "CAPTURED_INPUTS[$nn]"
				_tui_push_msg "Unrouted: ${desc:-$nn}"
			else
				if link_input_to_sink "$nn"; then
					CAPTURED_INPUTS["$nn"]=1
					_tui_push_msg "Routed: ${desc:-$nn}"
				else
					_tui_push_msg "Failed to route: ${desc:-$nn}"
				fi
			fi
			;;
		[1-9])
			local idx=$((key - 1))
			if ((idx < _TUI_INPUT_COUNT)); then
				sel=$idx
				local rec="${_TUI_INPUTS[$sel]}"
				local nn desc st
				IFS=$'\t' read -r nn desc st <<<"$rec"
				if [[ "$st" == "routed" ]]; then
					unlink_input_from_sink "$nn"
					unset "CAPTURED_INPUTS[$nn]"
					_tui_push_msg "Unrouted: ${desc:-$nn}"
				else
					if link_input_to_sink "$nn"; then
						CAPTURED_INPUTS["$nn"]=1
						_tui_push_msg "Routed: ${desc:-$nn}"
					else
						_tui_push_msg "Failed to route: ${desc:-$nn}"
					fi
				fi
			fi
			;;
		a | A)
			tui_refresh_inputs
			local i
			for ((i = 0; i < _TUI_INPUT_COUNT; i++)); do
				local rec="${_TUI_INPUTS[$i]}"
				local nn desc st
				IFS=$'\t' read -r nn desc st <<<"$rec"
				if [[ "$st" != "routed" ]]; then
					link_input_to_sink "$nn" && CAPTURED_INPUTS["$nn"]=1 || true
				fi
			done
			_tui_push_msg "Routed all input devices"
			;;
		n | N)
			for nn in "${!CAPTURED_INPUTS[@]}"; do
				unlink_input_from_sink "$nn"
			done
			CAPTURED_INPUTS=()
			_tui_push_msg "Unrouted all input devices"
			;;
		b | B | ESC | q | Q)
			return
			;;
		esac
	done
}

# ── TUI main menu ──

tui_menu_main() {
	while true; do
		tui_clear
		tui_header ""
		printf '\n' >&2

		# Summary line
		local svol
		svol=$(tui_get_sink_volume "$SINK_NAME")
		svol="${svol:-0}"
		local smute
		smute=$(tui_get_sink_mute "$SINK_NAME")

		printf '  Sink: %b%s%b' "$_B" "$SINK_NAME" "$_N" >&2
		[[ "$smute" == "yes" ]] && printf '  %b[MUTED]%b' "$_R" "$_N" >&2
		printf '\n' >&2

		printf '  Streams: %b%d%b captured' "$_B" "${#CAPTURED[@]}" "$_N" >&2
		if ((${#CAPTURED_INPUTS[@]} > 0)); then
			printf ', %b%d%b input(s) routed' "$_B" "${#CAPTURED_INPUTS[@]}" "$_N" >&2
		fi
		local ml_tag=""
		[[ "$MUTE_LOCAL" == true ]] && ml_tag="  ${_R}(mute-local)${_N}"
		printf '%b\n' "$ml_tag" >&2

		printf '  Volume:  ' >&2
		tui_volume_bar "$svol" 20
		printf '\n\n' >&2

		tui_rule
		printf '\n' >&2
		tui_hint "s" "Streams"
		tui_hint "v" "Volume"
		printf '\n' >&2
		tui_hint "r" "Route inputs"
		tui_hint "o" "Output"
		printf '\n' >&2
		tui_hint "c" "Config"
		tui_hint "i" "Info"
		printf '\n' >&2
		tui_hint "q" "Quit"
		printf '\n' >&2
		tui_show_messages

		local key
		key=$(tui_read_key "$POLL_INTERVAL") || {
			[[ "$AUTO_CAPTURE" == true ]] && scan_new_streams
			verify_existing_links
			continue
		}

		case "$key" in
		s | S) tui_menu_streams ;;
		v | V) tui_menu_volume ;;
		r | R) tui_menu_inputs ;;
		o | O) tui_menu_output ;;
		c | C) tui_menu_config ;;
		i | I) tui_menu_info ;;
		q | Q | ESC) return ;;
		esac
	done
}

# ── Interactive entry point ──

interactive_loop() {
	tui_init

	tui_menu_main

	tui_fini
}

# ─── entry point ─────────────────────────────────────────────────────────────

main() {
	parse_args "$@"

	# Handle management sub-commands early
	case "$ACTION" in
	status)
		cmd_status
		exit $?
		;;
	stop)
		ensure_runtime_dir
		cmd_stop "$SINK_NAME"
		exit $?
		;;
	stop-all)
		cmd_stop_all
		exit $?
		;;
	esac

	# ── normal "run" path ──
	check_deps
	ensure_runtime_dir

	# Banner
	log "═══════════════════════════════════════"
	log " ${_B}pipewire-audio-share${_N}  —  PipeWire audio router"
	log "═══════════════════════════════════════"
	log "Sink name:     ${_B}${SINK_NAME}${_N}"
	log "Description:   ${SINK_DESCRIPTION}"
	log "Auto-capture:  ${AUTO_CAPTURE}"
	log "Mute local:    ${MUTE_LOCAL}"
	log "Source device:  ${CREATE_SOURCE}"
	if [[ "$SET_DEFAULT_SOURCE" == true ]]; then
		log "Default source: yes"
	fi
	if ((${#ROUTE_INPUTS[@]} > 0)); then
		log "Route inputs:  ${ROUTE_INPUTS[*]}"
	fi
	if ((${#INCLUDE[@]} > 0)); then
		log "Include:     ${INCLUDE[*]}"
	elif ((${#EXCLUDE[@]} > 0)); then
		log "Exclude:     ${EXCLUDE[*]}"
	else
		log "Filter:        (none — all streams)"
	fi
	log "Poll interval: ${POLL_INTERVAL}s"
	log "───────────────────────────────────────"

	trap cleanup EXIT
	trap 'exit 0' INT TERM HUP

	# Compute source name defaults if not explicitly set
	if [[ "$CREATE_SOURCE" == true ]]; then
		[[ -z "$SOURCE_NAME" ]] && SOURCE_NAME="${SINK_NAME}_input"
		[[ -z "$SOURCE_DESCRIPTION" ]] && SOURCE_DESCRIPTION="${SINK_DESCRIPTION} Input"
	fi

	acquire_lock
	# Write an initial PID file (MODULE_ID updated after sink creation)
	write_pid_file

	get_default_sink
	create_sink
	create_source
	capture_existing_streams
	route_input_devices

	log "───────────────────────────────────────"
	log "Virtual sink ${_B}${SINK_NAME}${_N} is ready."
	log "Configure your capture software to use:"
	log "  Sink / playback: ${_B}${SINK_NAME}${_N}"
	log "  Monitor / source: ${_B}${SINK_NAME}.monitor${_N}"
	if [[ "$CREATE_SOURCE" == true && -n "$SOURCE_MODULE_ID" ]]; then
		log "  Input device:    ${_B}${SOURCE_NAME}${_N}"
	fi
	log "───────────────────────────────────────"

	if [[ "$INTERACTIVE" == true ]]; then
		interactive_loop
	else
		if [[ -t 0 && -t 2 ]]; then
			log "Hint: run with ${_B}-i${_N} for an interactive TUI"
		fi
		monitor_loop
	fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
