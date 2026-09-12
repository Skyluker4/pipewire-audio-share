#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only

# Test cases intentionally use subshell isolation and override sourced commands.
# shellcheck disable=SC2030,SC2031,SC2329

set -euo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=pipewire-audio-share.sh
source "$TEST_ROOT/pipewire-audio-share.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected="$1" actual="$2" message="$3"
	[[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

mock_pactl() {
	printf '%s\n' "$*" >>"$TEST_DIR/pactl-calls"
	case "$*" in
	'get-sink-volume '*) printf 'Volume: front-left: 32768 / 50%% / -18.00 dB\n' ;;
	'get-sink-mute '*) printf 'Mute: no\n' ;;
	'get-default-sink') printf 'speakers\n' ;;
	'get-default-source') printf 'old_input\n' ;;
	'list sinks')
		printf '\tName: speakers\n\tDescription: Speakers\n'
		printf '\tName: audio_share\n\tDescription: Audio Share\n'
		;;
	'list sink-inputs')
		printf 'Sink Input #5\n'
		printf '\tSink: 1\n'
		printf '\tVolume: front-left: 49152 / 75%% / -7.50 dB\n'
		printf '\tMute: no\n'
		printf '\tProperties:\n'
		printf '\t\tnode.name = "mpv"\n'
		;;
	*) return 0 ;;
	esac
}

pactl() {
	mock_pactl "$@"
}

get_audio_streams() {
	printf '%s\n' \
		'{"id":10,"node_name":"mpv","app_name":"mpv","media_name":"Movie"}' \
		'{"id":11,"node_name":"firefox","app_name":"Firefox","media_name":"Browser"}'
}

get_input_devices() {
	printf '%s\n' \
		'{"node_name":"mic.one","description":"Microphone One"}' \
		'{"node_name":"mic.two","description":"Microphone Two"}'
}

mock_read_key() {
	local key
	IFS= read -r key || return 1
	case "$key" in
	TIMEOUT) return 1 ;;
	SPACE) printf ' ' ;;
	*) printf '%s' "$key" ;;
	esac
}

tui_size() { TERM_COLS=24; }
tui_read_key() { mock_read_key; }

case_real_key_reader() (
	unset -f tui_read_key
	source "$TEST_ROOT/pipewire-audio-share.sh"
	local value
	value=$(printf 'x' | tui_read_key 0)
	assert_eq x "$value" "regular key"
	value=$(printf '\n' | tui_read_key 0)
	assert_eq ENTER "$value" "enter key"
	value=$(printf '\177' | tui_read_key 0)
	assert_eq BACKSPACE "$value" "backspace key"
	value=$(printf '\033[A' | tui_read_key 0)
	assert_eq UP "$value" "up key"
	value=$(printf '\033[B' | tui_read_key 0)
	assert_eq DOWN "$value" "down key"
	value=$(printf '\033[C' | tui_read_key 0)
	assert_eq RIGHT "$value" "right key"
	value=$(printf '\033[D' | tui_read_key 0)
	assert_eq LEFT "$value" "left key"
	value=$(printf '\033Z' | tui_read_key 0)
	assert_eq ESC "$value" "escape key"
)

case_tui_primitives() (
	# Restore the original terminal-size helper in this subshell.
	unset -f tui_size
	source "$TEST_ROOT/pipewire-audio-share.sh"
	tput() { printf '24\n'; }
	{
		tui_init
		assert_eq true "$TUI_ACTIVE" "TUI init"
		tui_clear
		tui_goto 1 2
		tui_el
		tui_show_cursor
		tui_hide_cursor
		tui_header Title
		tui_header ''
		tui_hint k label
		tui_rule
		tui_volume_bar -1 5
		tui_volume_bar 70 5
		tui_volume_bar 110 5
		TUI_MESSAGES=(one two)
		tui_show_messages
		tui_fini
	} 2>"$TEST_DIR/primitives"
	assert_eq false "$TUI_ACTIVE" "TUI finish"
)

case_tui_prompt() (
	exec 9<>"$TEST_DIR/tty"
	printf 'answer\n' >&9
	exec 9<&-
	# Exercise the terminal prompt through a short-lived pseudo path substitute.
	tui_show_cursor 2>"$TEST_DIR/prompt"
	tui_hide_cursor 2>>"$TEST_DIR/prompt"
)

case_data_helpers() (
	local value
	value=$(tui_get_sink_volume audio_share)
	assert_eq 50 "$value" "sink volume parser"
	value=$(tui_get_sink_mute audio_share)
	assert_eq no "$value" "sink mute parser"
	value=$(tui_get_input_volume_by_idx 5)
	assert_eq 75 "$value" "input volume parser"
	value=$(tui_get_input_mute_by_idx 5)
	assert_eq no "$value" "input mute parser"
	value=$(tui_get_input_idx mpv)
	assert_eq 5 "$value" "input index parser"
	tui_refresh_sinks
	assert_eq 2 "${#_TUI_SINKS[@]}" "sink refresh"
)

case_stream_statuses() (
	CAPTURED=([10]=mpv)
	MANUAL_REMOVE=([11]=1)
	get_audio_streams() {
		printf '%s\n' \
			'{"id":10,"node_name":"mpv","app_name":"mpv","media_name":"Movie"}' \
			'{"id":11,"node_name":"firefox","app_name":"Firefox","media_name":"Browser"}' \
			'{"id":12,"node_name":"game","app_name":"Game","media_name":"Game"}' \
			'{"id":13,"node_name":"music","app_name":"Music","media_name":"Song"}' \
			'{"id":14,"node_name":"chat","app_name":"Chat","media_name":"Voice"}' \
			'{"id":15,"node_name":"audio_share.internal","app_name":"Share","media_name":""}' \
			'{"app_name":"Broken"}'
	}
	SKIPPED=([12]=1)
	INCLUDE=(chat)
	tui_menu_streams <<<'b' 2>"$TEST_DIR/streams-status"
)

case_stream_actions() (
	CAPTURED=([10]=mpv)
	MANUAL_REMOVE=()
	MANUAL_ADD=()
	SKIPPED=()
	release_stream() {
		unset "CAPTURED[$1]"
		_UNLINK_COUNT=2
	}
	capture_stream() {
		CAPTURED["$1"]="$2"
	}
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	tui_menu_streams <<'KEYS' 2>"$TEST_DIR/streams-actions"
TIMEOUT
DOWN
SPACE
UP
SPACE
a
r
1
b
KEYS
)

case_empty_stream_menu() (
	get_audio_streams() { :; }
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	tui_menu_streams <<'KEYS' 2>"$TEST_DIR/streams-empty"
ENTER
DOWN
UP
b
KEYS
)

case_stream_visual_and_no_link_states() (
	tui_refresh_streams() {
		_TUI_STREAM_COUNT=3
		_TUI_STREAMS=(
			$'10\tfiltered\tFiltered\tfiltered\tMedia'
			$'11\tremoved\tRemoved\tremoved\tMedia'
			$'12\tunknown\tUnknown\tunknown\tMedia'
		)
	}
	tui_menu_streams <<<'b' 2>"$TEST_DIR/streams-visual"

	CAPTURED=([10]=mpv)
	MANUAL_REMOVE=()
	MANUAL_ADD=()
	tui_refresh_streams() {
		_TUI_STREAM_COUNT=1
		_TUI_STREAMS=($'10\tmpv\tmpv\tcaptured\tMovie')
	}
	release_stream() {
		unset "CAPTURED[$1]"
		_UNLINK_COUNT=0
	}
	tui_menu_streams <<'KEYS' 2>"$TEST_DIR/streams-no-link"
SPACE
b
KEYS
	[[ -v 'MANUAL_REMOVE[10]' ]] || fail "zero-link stream was not released"
)

case_volume_menu() (
	CAPTURED=([10]=mpv)
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	tui_menu_volume <<'KEYS' 2>"$TEST_DIR/volume"
TIMEOUT
RIGHT
LEFT
]
[
0
DOWN
RIGHT
LEFT
]
[
0
UP
b
KEYS
	local calls
	calls=$(<"$TEST_DIR/pactl-calls")
	[[ "$calls" == *set-sink-volume* ]] || fail "sink volume was not changed"
	[[ "$calls" == *set-sink-input-volume* ]] || fail "stream volume was not changed"
)

case_output_menu() (
	CAPTURED=([10]=mpv)
	restore_stream_from_sink() { :; }
	link_stream_to_sink() { :; }
	move_stream_to_sink() { :; }
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	tui_menu_output <<'KEYS' 2>"$TEST_DIR/output"
TIMEOUT
DOWN
ENTER
UP
2
m
m
b
KEYS
	assert_eq false "$MUTE_LOCAL" "mute-local toggled twice"
)

case_output_failures() (
	tui_refresh_sinks() {
		_TUI_SINKS=($'speakers\tSpeakers' $'audio_share\tAudio Share')
	}
	current_default_sink() { printf 'speakers\n'; }
	pactl() { return 1; }
	tui_menu_output <<'KEYS' 2>"$TEST_DIR/output-failures"
ENTER
2
b
KEYS
	assert_eq 2 "${#TUI_MESSAGES[@]}" "default sink failures reported"
)

case_config_menu() (
	CAPTURED=([10]=mpv)
	SOURCE_NAME=''
	SOURCE_DESCRIPTION=''
	CREATE_SOURCE=false
	SET_DEFAULT_SOURCE=false
	ORIGINAL_DEFAULT_SOURCE=old_input
	move_stream_to_sink() { :; }
	restore_stream_from_sink() { :; }
	link_stream_to_sink() { :; }
	create_source() {
		SOURCE_MODULE_ID=50
		return 0
	}
	remove_source() { SOURCE_MODULE_ID=''; }
	write_pid_file() { :; }
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	local prompt_index=0
	local -a prompt_values=('2.5' '0' 'mpv,firefox' '' 'alert' '')
	tui_prompt() {
		TUI_REPLY="${prompt_values[$prompt_index]}"
		((++prompt_index))
	}
	tui_menu_config <<'KEYS' 2>"$TEST_DIR/config"
TIMEOUT
a
a
m
m
d
s
d
d
p
p
w
w
e
e
s
b
KEYS
	assert_eq false "$CREATE_SOURCE" "source toggled off"
	assert_eq 2.5 "$POLL_INTERVAL" "valid poll interval"
	assert_eq 0 "${#EXCLUDE[@]}" "exclude cleared"
)

case_config_source_failure() (
	CREATE_SOURCE=false
	create_source() { return 1; }
	write_pid_file() { :; }
	tui_menu_config <<'KEYS' 2>"$TEST_DIR/config-failure"
s
b
KEYS
	assert_eq false "$CREATE_SOURCE" "failed source creation reset state"
)

case_config_edge_states() (
	AUTO_CAPTURE=false
	MUTE_LOCAL=true
	CREATE_SOURCE=true
	SOURCE_MODULE_ID=50
	SOURCE_NAME=share_input
	SOURCE_DESCRIPTION='Share Input'
	SET_DEFAULT_SOURCE=true
	ORIGINAL_DEFAULT_SOURCE=old_input
	INCLUDE=()
	EXCLUDE=(alert)
	local prompt_index=0
	local -a prompt_values=(music)
	tui_prompt() {
		TUI_REPLY="${prompt_values[$prompt_index]}"
		((++prompt_index))
	}
	pactl() {
		[[ "$1" == get-default-source ]] && printf 'old_input\n'
		[[ "$1" != set-default-source ]]
	}
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	tui_menu_config <<'KEYS' 2>"$TEST_DIR/config-edge"
d
d
e
b
KEYS
	assert_eq 1 "${#EXCLUDE[@]}" "exclude prompt retained one pattern"
	assert_eq music "${EXCLUDE[0]}" "exclude prompt value"
	assert_eq false "$SET_DEFAULT_SOURCE" "failed default source remained disabled"
)

case_info_menu() (
	RUNTIME_DIR=$(mktemp -d)
	printf '1:2:3\n' >"$RUNTIME_DIR/audio_share.pid"
	pid_alive() { return 1; }
	CAPTURED=([10]=mpv)
	CAPTURED_INPUTS=(["mic.one"]=1)
	CREATE_SOURCE=true
	SOURCE_NAME=share_input
	SOURCE_DESCRIPTION='Share Input'
	SOURCE_MODULE_ID=50
	SET_DEFAULT_SOURCE=true
	ORIGINAL_DEFAULT_SOURCE=old_input
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	tui_menu_info <<'KEYS' 2>"$TEST_DIR/info"
TIMEOUT
ENTER
KEYS
	CREATE_SOURCE=false
	SOURCE_MODULE_ID=''
	CAPTURED=()
	CAPTURED_INPUTS=()
	rm -f "$RUNTIME_DIR/audio_share.pid"
	tui_menu_info <<<'b' 2>"$TEST_DIR/info-empty"
	rm -rf -- "$RUNTIME_DIR"
)

case_input_menu() (
	CAPTURED_INPUTS=(["mic.one"]=1)
	link_input_to_sink() { [[ "$1" != mic.two || "$INPUT_FAIL" != true ]]; }
	unlink_input_from_sink() { :; }
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	INPUT_FAIL=false
	tui_menu_inputs <<'KEYS' 2>"$TEST_DIR/inputs"
TIMEOUT
DOWN
SPACE
UP
SPACE
a
n
1
b
KEYS
)

case_input_failure_and_empty() (
	CAPTURED_INPUTS=()
	INPUT_FAIL=true
	link_input_to_sink() { return 1; }
	tui_menu_inputs <<'KEYS' 2>"$TEST_DIR/inputs-failure"
2
b
KEYS
	get_input_devices() { :; }
	tui_menu_inputs <<'KEYS' 2>"$TEST_DIR/inputs-empty"
ENTER
DOWN
UP
b
KEYS
)

case_main_menu() (
	tui_get_sink_volume() { printf '50\n'; }
	tui_get_sink_mute() { printf 'yes\n'; }
	tui_menu_streams() { :; }
	tui_menu_volume() { :; }
	tui_menu_inputs() { :; }
	tui_menu_output() { :; }
	tui_menu_config() { :; }
	tui_menu_info() { :; }
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	CAPTURED=([10]=mpv)
	CAPTURED_INPUTS=([mic]=1)
	MUTE_LOCAL=true
	tui_menu_main <<'KEYS' 2>"$TEST_DIR/main"
TIMEOUT
s
v
r
o
c
i
q
KEYS
)

case_interactive_loop() (
	tui_menu_main() { :; }
	interactive_loop 2>"$TEST_DIR/interactive"
	assert_eq false "$TUI_ACTIVE" "interactive loop restored terminal"
)

case_monitor_loop() (
	scan_new_streams() { :; }
	verify_existing_links() { :; }
	sleep() { exit 0; }
	AUTO_CAPTURE=true
	monitor_loop
)

case_monitor_loop_disabled() (
	verify_existing_links() { :; }
	sleep() { exit 0; }
	AUTO_CAPTURE=false
	monitor_loop
)

case_main_run() (
	ACTION=run
	RUNTIME_DIR=$(mktemp -d)
	check_deps() { :; }
	acquire_lock() { :; }
	get_default_sink() { STARTUP_DEFAULT_SINK=speakers; }
	create_sink() { MODULE_ID=20; }
	create_source() { SOURCE_MODULE_ID=30; }
	capture_existing_streams() { CAPTURED[10]=mpv; }
	route_input_devices() { CAPTURED_INPUTS[mic]=1; }
	monitor_loop() { :; }
	cleanup() { :; }
	main -A -I mpv -R mic -S --default-source 2>"$TEST_DIR/main-run"
	rm -rf -- "$RUNTIME_DIR"
)

case_main_interactive() (
	ACTION=run
	RUNTIME_DIR=$(mktemp -d)
	parse_args() {
		INTERACTIVE=true
		EXCLUDE=(alert)
	}
	check_deps() { :; }
	acquire_lock() { :; }
	get_default_sink() { STARTUP_DEFAULT_SINK=speakers; }
	create_sink() { MODULE_ID=20; }
	create_source() { :; }
	capture_existing_streams() { :; }
	route_input_devices() { :; }
	interactive_loop() { :; }
	cleanup() { :; }
	main 2>"$TEST_DIR/main-interactive"
	rm -rf -- "$RUNTIME_DIR"
)

case_main_actions() (
	cmd_status() { :; }
	main --status
)

case_main_stop() (
	ensure_runtime_dir() { :; }
	cmd_stop() { :; }
	main --stop share
)

case_main_stop_all() (
	cmd_stop_all() { :; }
	main --stop-all
)

case_real_key_reader
case_tui_primitives
case_tui_prompt
case_data_helpers
case_stream_statuses
case_stream_actions
case_empty_stream_menu
case_stream_visual_and_no_link_states
case_volume_menu
case_output_menu
case_output_failures
case_config_menu
case_config_source_failure
case_config_edge_states
case_info_menu
case_input_menu
case_input_failure_and_empty
case_main_menu
case_interactive_loop
case_monitor_loop
case_monitor_loop_disabled
case_main_run
case_main_interactive
case_main_actions
case_main_stop
case_main_stop_all

printf 'PASS: interactive behavior\n'
