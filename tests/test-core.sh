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

assert_contains() {
	local haystack="$1" needle="$2" message="$3"
	[[ "$haystack" == *"$needle"* ]] || fail "$message: '$needle' not found"
}

assert_success() {
	"$@" || fail "expected success: $*"
}

assert_failure() {
	if "$@"; then
		fail "expected failure: $*"
	fi
}

make_graph() {
	cat <<-'JSON'
		[
		{"id":10,"info":{"props":{"node.name":"mpv","application.name":"mpv","media.name":"Movie","media.class":"Stream/Output/Audio","object.serial":100}}},
		{"id":11,"info":{"props":{"node.name":"firefox","application.name":"Firefox","media.name":"Browser","media.class":"Stream/Output/Audio","object.serial":101}}},
		{"id":20,"info":{"props":{"node.name":"audio_share","media.class":"Audio/Sink","factory.name":"support.null-audio-sink"}}},
		{"id":21,"info":{"props":{"node.name":"speakers","media.class":"Audio/Sink","factory.name":"api.alsa.pcm.sink"}}},
		{"id":30,"info":{"props":{"node.name":"mic.mono","node.description":"Mono Microphone","media.class":"Audio/Source"}}},
		{"id":31,"info":{"props":{"node.name":"mic.stereo","node.description":"Stereo Microphone","media.class":"Audio/Source"}}},
		{"id":101,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":10,"port.name":"output_FL"}}},
		{"id":102,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":10,"port.name":"output_FR"}}},
		{"id":111,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":11,"port.name":"output_MONO"}}},
		{"id":201,"type":"PipeWire:Interface:Port","info":{"direction":"input","props":{"node.id":20,"port.name":"playback_FL"}}},
		{"id":202,"type":"PipeWire:Interface:Port","info":{"direction":"input","props":{"node.id":20,"port.name":"playback_FR"}}},
		{"id":301,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":30,"port.name":"capture_MONO"}}},
		{"id":311,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":31,"port.name":"capture_FL"}}},
		{"id":312,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":31,"port.name":"capture_FR"}}},
		{"type":"PipeWire:Interface:Link","info":{"output-port-id":101,"input-port-id":201}},
		{"type":"PipeWire:Interface:Link","info":{"output-port-id":102,"input-port-id":202}},
		{"type":"PipeWire:Interface:Link","info":{"output-port-id":101,"input-port-id":999}}
		]
	JSON
}

case_logging_and_usage() (
	local output
	output=$(log hello 2>&1)
	assert_contains "$output" hello "normal log"
	output=$(warn warning 2>&1)
	assert_contains "$output" WARN "normal warning"
	output=$(err problem 2>&1)
	assert_contains "$output" ERROR "normal error"
	VERBOSE=true
	output=$(debug details 2>&1)
	assert_contains "$output" details "debug log"
	TUI_ACTIVE=true
	log hidden
	warn one
	err two
	debug hidden
	_tui_push_msg three
	_tui_push_msg four
	_tui_push_msg five
	_tui_push_msg six
	assert_eq 5 "${#TUI_MESSAGES[@]}" "TUI message ring size"
	output=$(usage)
	assert_contains "$output" 'MULTIPLE INSTANCES' "usage sections"
	assert_contains "$output" --route-input "usage options"
	assert_failure bash -c "source '$TEST_ROOT/pipewire-audio-share.sh'; TUI_ACTIVE=true; die expected"
)

case_argument_parsing() (
	parse_args --status
	assert_eq status "$ACTION" "status action"
)

case_argument_parsing_all() (
	parse_args --sink-name share --description Test --no-auto-capture --auto-capture \
		--include mpv -I Firefox --mute-local --route-input mic -R line \
		--source --source-name input --source-description Input --default-source \
		--poll-interval 3 --verbose
	assert_eq share "$SINK_NAME" "sink name"
	assert_eq Test "$SINK_DESCRIPTION" "description"
	assert_eq true "$AUTO_CAPTURE" "auto capture"
	assert_eq 2 "${#INCLUDE[@]}" "repeated include"
	assert_eq true "$MUTE_LOCAL" "mute local"
	assert_eq 2 "${#ROUTE_INPUTS[@]}" "repeated input route"
	assert_eq true "$CREATE_SOURCE" "source creation"
	assert_eq input "$SOURCE_NAME" "source name"
	assert_eq Input "$SOURCE_DESCRIPTION" "source description"
	assert_eq true "$SET_DEFAULT_SOURCE" "default source"
	assert_eq 3 "$POLL_INTERVAL" "poll interval"
	assert_eq true "$VERBOSE" "verbose"
)

case_argument_actions() (
	parse_args --stop chosen
	assert_eq stop "$ACTION" "stop action"
	assert_eq chosen "$SINK_NAME" "stop target"
)

case_argument_stop_all() (
	parse_args --stop-all
	assert_eq stop-all "$ACTION" "stop-all action"
)

case_argument_exclude() (
	parse_args -n short -d Short -A -X alert -m -R mic -S -p 1 -v
	assert_eq 1 "${#EXCLUDE[@]}" "exclude option"
)

case_argument_errors() (
	if (parse_args --unknown); then
		fail "unknown argument was accepted"
	fi
)

case_argument_filter_error() (
	if (parse_args -I one -X two); then
		fail "include and exclude were accepted together"
	fi
)

case_argument_interactive_error() (
	if (parse_args -i); then
		fail "interactive mode was accepted without a TTY"
	fi
)

case_argument_help() (
	parse_args --help >/dev/null
	fail "help did not exit"
)

case_dependencies() (
	command() { return 0; }
	assert_success check_deps
)

case_missing_dependencies() (
	command() { return 1; }
	if (check_deps); then
		fail "missing dependencies were accepted"
	fi
)

case_pid_files() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	SINK_NAME=share
	MODULE_ID=12
	SOURCE_MODULE_ID=34
	ensure_runtime_dir
	write_pid_file
	assert_success read_pid_file "$(pid_file)"
	assert_eq 12 "$_PF_MODULE" "sink module from PID file"
	assert_eq 34 "$_PF_SRC_MOD" "source node from PID file"
	printf '123:45\n' >"$(pid_file)"
	read_pid_file "$(pid_file)"
	assert_eq '' "$_PF_SRC_MOD" "legacy PID file"
	assert_failure read_pid_file "$RUNTIME_DIR/missing.pid"
	remove_pid_file
	assert_failure test -e "$(pid_file)"
)

case_instance_management() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	SINK_NAME=current
	printf '100:10:20\n' >"$RUNTIME_DIR/current.pid"
	printf '200:11:21\n' >"$RUNTIME_DIR/peer.pid"
	printf '300:12:22\n' >"$RUNTIME_DIR/stale.pid"
	printf '\n' >"$RUNTIME_DIR/corrupt.pid"
	pid_alive() { [[ "$1" == 100 || "$1" == 200 ]]; }
	local names peers status
	names=$(all_instance_names)
	assert_contains "$names" peer "all instance names"
	peers=$(peer_sink_names)
	assert_eq peer "$peers" "live peer names"
	status=$(cmd_status)
	assert_contains "$status" running "running status"
	assert_contains "$status" STALE "stale status"
	assert_contains "$status" corrupt "corrupt status"
)

case_acquire_stale_lock() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	SINK_NAME=share
	printf '999999:10:20\n' >"$RUNTIME_DIR/share.pid"
	pid_alive() { return 1; }
	pw-cli() { printf '%s\n' "$*" >>"$RUNTIME_DIR/calls"; }
	pactl() { printf '%s\n' "$*" >>"$RUNTIME_DIR/calls"; }
	acquire_lock
	assert_failure test -e "$RUNTIME_DIR/share.pid"
	assert_contains "$(<"$RUNTIME_DIR/calls")" 'destroy 20' "stale source cleanup"
	assert_contains "$(<"$RUNTIME_DIR/calls")" 'unload-module 10' "stale sink cleanup"
	printf '\n' >"$RUNTIME_DIR/share.pid"
	acquire_lock
	assert_failure test -e "$RUNTIME_DIR/share.pid"
)

case_acquire_live_lock() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	SINK_NAME=share
	printf '1:10:20\n' >"$RUNTIME_DIR/share.pid"
	pid_alive() { return 0; }
	if (acquire_lock); then
		fail "live instance lock was acquired"
	fi
)

case_stop_commands() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	assert_failure cmd_stop absent
	printf '\n' >"$RUNTIME_DIR/bad.pid"
	assert_failure cmd_stop bad
	printf '999999:10:20\n' >"$RUNTIME_DIR/stale.pid"
	pid_alive() { return 1; }
	pw-cli() { :; }
	pactl() { :; }
	cmd_stop stale
	assert_failure test -e "$RUNTIME_DIR/stale.pid"
	cmd_stop_all >/dev/null
	printf '999999:10:20\n' >"$RUNTIME_DIR/one.pid"
	printf '999998:11:21\n' >"$RUNTIME_DIR/two.pid"
	cmd_stop_all >/dev/null
	assert_failure test -e "$RUNTIME_DIR/one.pid"
)

case_stop_live_command() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	printf '123:10:20\n' >"$RUNTIME_DIR/live.pid"
	local checks=0
	pid_alive() {
		((++checks))
		((checks < 2))
	}
	kill() { :; }
	sleep() { :; }
	cmd_stop live
)

case_stop_stubborn_command() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	printf '123:10:20\n' >"$RUNTIME_DIR/live.pid"
	pid_alive() { return 0; }
	kill() { printf 'kill %s\n' "$*" >>"$RUNTIME_DIR/calls"; }
	pw-cli() { printf 'pw-cli %s\n' "$*" >>"$RUNTIME_DIR/calls"; }
	pactl() { printf 'pactl %s\n' "$*" >>"$RUNTIME_DIR/calls"; }
	sleep() { :; }
	cmd_stop live
	assert_failure test -e "$RUNTIME_DIR/live.pid"
	local calls
	calls=$(<"$RUNTIME_DIR/calls")
	assert_contains "$calls" 'kill -TERM 123' "graceful stop signal"
	assert_contains "$calls" 'kill -KILL 123' "forced stop signal"
	assert_contains "$calls" 'pw-cli destroy 20' "forced source cleanup"
	assert_contains "$calls" 'pactl unload-module 10' "forced sink cleanup"
)

case_empty_status_and_entrypoint() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	local output
	output=$(cmd_status)
	assert_contains "$output" 'No pipewire-audio-share instances found.' "empty status"
	output=$(XDG_RUNTIME_DIR="$RUNTIME_DIR" bash "$TEST_ROOT/pipewire-audio-share.sh" --status)
	assert_contains "$output" 'No pipewire-audio-share instances found.' "script entry point"
)

case_discovery_and_filters() (
	pw-dump() { make_graph; }
	local streams inputs
	streams=$(get_audio_streams)
	assert_contains "$streams" firefox "stream discovery"
	inputs=$(get_input_devices)
	assert_contains "$inputs" mic.mono "input discovery"
	INCLUDE=()
	EXCLUDE=()
	assert_success stream_matches_filter mpv MPV Movie
	assert_failure stream_matches_filter audio_share.internal Audio ''
	INCLUDE=(' FIRE ')
	assert_success stream_matches_filter firefox Firefox Browser
	assert_failure stream_matches_filter mpv mpv Movie
	INCLUDE=()
	EXCLUDE=(' movie ')
	assert_failure stream_matches_filter mpv mpv Movie
	assert_success stream_matches_filter firefox Firefox Browser
	ROUTE_INPUTS=()
	assert_failure input_matches_route mic.mono 'Mono Microphone'
	ROUTE_INPUTS=(' mono ')
	assert_success input_matches_route mic.mono 'Mono Microphone'
	assert_failure input_matches_route other Other
)

case_graph_linking() (
	pw-dump() { make_graph; }
	local mode=success
	pw-link() {
		case "$mode" in
		exists)
			printf 'File exists' >&2
			return 1
			;;
		failure)
			printf 'denied' >&2
			return 1
			;;
		*) return 0 ;;
		esac
	}
	OUR_LINKS=()
	STREAM_LINKS=()
	assert_success link_stream_to_sink 10
	assert_eq 2 "${#OUR_LINKS[@]}" "stream links tracked"
	assert_eq 2 "${#STREAM_LINKS[@]}" "stream links tracked by node"
	[[ -v 'STREAM_LINKS[10|101|201]' && -v 'STREAM_LINKS[10|102|202]' ]] || fail "stream node link keys"
	assert_success link_stream_to_sink 10
	mode=exists
	OUR_LINKS=()
	assert_success link_stream_to_sink 10
	mode=failure
	OUR_LINKS=()
	assert_failure link_stream_to_sink 10
	assert_failure link_stream_to_sink 999
	OUR_LINKS=(["101|201"]=1 ["102|202"]=1 ["111|201"]=1)
	STREAM_LINKS=(["10|101|201"]=1 ["10|102|202"]=1)
	mode=success
	unlink_stream_from_sink 10
	assert_eq 1 "${#OUR_LINKS[@]}" "only selected stream bookkeeping removed"
	assert_eq 0 "${#STREAM_LINKS[@]}" "selected stream links removed"
	assert_eq 2 "$_UNLINK_COUNT" "stream unlink count"
)

case_graph_lookup_failure() (
	pw-dump() { return 1; }
	assert_failure link_stream_to_sink 10
	assert_failure unlink_stream_from_sink 10
	assert_failure link_input_to_sink mic
)

case_unlink_query_failures() (
	pw-dump() { make_graph; }
	local fail_on
	jq() {
		case "$fail_on:$*" in
		node:*'--argjson nid'*) return 1 ;;
		sink:*'--arg name'*) return 1 ;;
		links:*-r*)
			[[ "$*" == *'--arg'* ]] || return 1
			;;
		esac
		command jq "$@"
	}

	for fail_on in node sink links; do
		assert_failure unlink_stream_from_sink 10
	done
)

case_partial_unlink_failure() (
	pw-dump() { make_graph; }
	OUR_LINKS=(["101|201"]=1 ["102|202"]=1)
	STREAM_LINKS=(["10|101|201"]=1 ["10|102|202"]=1)
	pw-link() {
		if [[ "$1" != -d ]]; then
			fail "link repair recreated a partially removed stream link"
		fi
		if [[ "$2" == 102 ]]; then
			printf 'denied' >&2
			return 1
		fi
	}

	assert_failure unlink_stream_from_sink 10
	assert_eq 2 "${#OUR_LINKS[@]}" "partial unlink retained all links"
	assert_eq 2 "${#STREAM_LINKS[@]}" "partial unlink retained node links"
	assert_success link_stream_to_sink 10

	pw-link() { :; }
	assert_success unlink_stream_from_sink 10
	assert_eq 0 "${#OUR_LINKS[@]}" "unlink retry cleared all links"
	assert_eq 0 "${#STREAM_LINKS[@]}" "unlink retry cleared node links"
)

case_graph_edge_failures() (
	pw-dump() {
		cat <<-'JSON'
			[
			{"id":10,"info":{"props":{"node.name":"mpv"}}},
			{"id":30,"info":{"props":{"node.name":"mic.empty"}}},
			{"id":101,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":10,"port.name":"output_FL"}}}
			]
		JSON
	}
	assert_failure link_input_to_sink mic.empty
	assert_failure link_stream_to_sink 10

	pw-dump() { make_graph; }
	pw-link() {
		if [[ "$1" == -d ]]; then
			printf 'denied' >&2
			return 1
		fi
		printf 'denied' >&2
		return 1
	}
	assert_failure link_input_to_sink mic.mono
	OUR_LINKS=(["101|201"]=1 ["102|202"]=1)
	STREAM_LINKS=(["10|101|201"]=1 ["10|102|202"]=1)
	assert_failure unlink_stream_from_sink 10
	assert_eq 2 "${#OUR_LINKS[@]}" "failed stream unlinks remain tracked"
	assert_eq 2 "${#STREAM_LINKS[@]}" "failed stream links remain retryable"

	pw-link() {
		printf 'No such file' >&2
		return 1
	}
	assert_success unlink_stream_from_sink 10
	assert_eq 0 "${#OUR_LINKS[@]}" "missing stream links clear bookkeeping"
	assert_eq 0 "${#STREAM_LINKS[@]}" "missing stream links clear node map"

	pw-link() {
		printf 'File exists' >&2
		return 1
	}
	assert_success link_input_to_sink mic.mono
)

case_input_linking() (
	pw-dump() { make_graph; }
	local mode=success
	pw-link() {
		case "$mode" in
		exists)
			printf 'File exists' >&2
			return 1
			;;
		failure)
			printf 'denied' >&2
			return 1
			;;
		*) return 0 ;;
		esac
	}
	OUR_LINKS=()
	assert_success link_input_to_sink mic.mono
	assert_eq 2 "${#OUR_LINKS[@]}" "mono input duplicated to stereo"
	OUR_LINKS=()
	assert_success link_input_to_sink mic.stereo
	assert_eq 2 "${#OUR_LINKS[@]}" "stereo input links"
	mode=exists
	assert_success link_input_to_sink mic.stereo
	mode=failure
	assert_failure link_input_to_sink mic.stereo
	assert_failure link_input_to_sink missing
	mode=success
	OUR_LINKS=(["301|201"]=1 ["301|202"]=1 ["101|201"]=1)
	unlink_input_from_sink mic.mono
	assert_eq 1 "${#OUR_LINKS[@]}" "input unlink bookkeeping"
)

case_route_inputs() (
	get_input_devices() {
		printf '%s\n' \
			'{"node_name":"mic.mono","description":"Mono Microphone"}' \
			'{"node_name":"other","description":"Other"}'
	}
	link_input_to_sink() { [[ "$1" == mic.mono ]]; }
	ROUTE_INPUTS=(mono)
	route_input_devices
	[[ -v 'CAPTURED_INPUTS[mic.mono]' ]] || fail "matching input was not routed"
	ROUTE_INPUTS=()
	route_input_devices
)

case_sink_lifecycle() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	local sink_present=true
	: >"$RUNTIME_DIR/default-calls"
	pactl() {
		printf '%s\n' "$*" >>"$RUNTIME_DIR/pactl-calls"
		case "$*" in
		get-default-sink)
			if [[ -s "$RUNTIME_DIR/default-calls" ]]; then
				printf 'audio_share\n'
			else
				printf 'speakers\n'
				printf 'called\n' >>"$RUNTIME_DIR/default-calls"
			fi
			;;
		'list short sinks') printf '1\tspeakers\n2\taudio_share\n' ;;
		'list sinks') printf '\tName: audio_share\n\tOwner Module: 77\n' ;;
		'unload-module 77') sink_present=false ;;
		'load-module module-null-sink'*) printf '88\n' ;;
		'set-default-sink speakers' | 'unload-module 88') : ;;
		esac
	}
	sink_exists() { "$sink_present"; }
	pw-link() {
		case "$1" in
		-i) printf 'audio_share:playback_FL\naudio_share:playback_FR\n' ;;
		-o) printf 'audio_share:monitor_FL\naudio_share:monitor_FR\n' ;;
		esac
	}
	sleep() { :; }
	create_sink
	assert_eq 88 "$MODULE_ID" "created sink module"
	assert_contains "$(<"$RUNTIME_DIR/pactl-calls")" 'set-default-sink speakers' "default sink restored"
	remove_sink
	assert_eq '' "$MODULE_ID" "removed sink module"
)

case_sink_failures() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	write_pid_file() { :; }
	sleep() { :; }

	sink_exists() { return 0; }
	get_sink_module_id() { printf '77\n'; }
	pactl() {
		[[ "$1" == get-default-sink ]] && printf 'speakers\n'
		return 0
	}
	if (create_sink); then
		fail "unrecoverable existing sink was accepted"
	fi

	sink_exists() { return 1; }
	pactl() {
		case "$*" in
		get-default-sink) printf 'speakers\n' ;;
		'load-module module-null-sink'*) printf '88\n' ;;
		esac
	}
	pw-link() { return 1; }
	if (create_sink); then
		fail "missing sink ports were accepted"
	fi

	: >"$RUNTIME_DIR/default-first"
	pactl() {
		case "$*" in
		get-default-sink)
			if [[ -s "$RUNTIME_DIR/default-first" ]]; then
				printf 'audio_share\n'
			else
				printf 'seen\n' >>"$RUNTIME_DIR/default-first"
				printf 'speakers\n'
			fi
			;;
		'load-module module-null-sink'*) printf '88\n' ;;
		'set-default-sink speakers') return 1 ;;
		esac
	}
	pw-link() {
		case "$1" in
		-i) printf 'audio_share:playback_FL\naudio_share:playback_FR\n' ;;
		-o) printf 'audio_share:monitor_FL\naudio_share:monitor_FR\n' ;;
		esac
	}
	create_sink
)

case_source_lifecycle() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	CREATE_SOURCE=false
	create_source
	CREATE_SOURCE=true
	SET_DEFAULT_SOURCE=true
	SOURCE_NAME=share_input
	SOURCE_DESCRIPTION='Share Input'
	printf '0\n' >"$RUNTIME_DIR/dump-count"
	pw-dump() {
		local dump_count
		read -r dump_count <"$RUNTIME_DIR/dump-count"
		((++dump_count)) || true
		printf '%s\n' "$dump_count" >"$RUNTIME_DIR/dump-count"
		if ((dump_count == 1)); then
			printf '[{"id":90,"info":{"props":{"node.name":"share_input"}}}]\n'
		else
			printf '[{"id":91,"info":{"props":{"node.name":"share_input"}}}]\n'
		fi
	}
	pw-cli() { :; }
	pw-link() {
		[[ "$1" == -i ]] && printf 'share_input:input_FL\n'
		return 0
	}
	pactl() {
		[[ "$1" == get-default-source ]] && printf 'old_input\n'
		return 0
	}
	sleep() { :; }
	create_source
	assert_eq 91 "$SOURCE_MODULE_ID" "new source node ID"
	assert_eq old_input "$ORIGINAL_DEFAULT_SOURCE" "original source saved"
	remove_source
	assert_eq '' "$SOURCE_MODULE_ID" "source removed"
)

case_source_failure() (
	CREATE_SOURCE=true
	SOURCE_NAME=input
	SOURCE_DESCRIPTION=Input
	pw-dump() { printf '[]\n'; }
	pw-cli() { return 1; }
	assert_failure create_source
)

case_source_timeout_and_default_failure() (
	CREATE_SOURCE=true
	SET_DEFAULT_SOURCE=true
	SOURCE_NAME=input
	SOURCE_DESCRIPTION=Input
	pw-dump() { printf '[]\n'; }
	pw-cli() { return 0; }
	pw-link() { return 1; }
	sleep() { :; }
	assert_failure create_source
	assert_eq '' "$SOURCE_MODULE_ID" "timed-out source reset"

	pw-dump() {
		printf '[{"id":91,"info":{"props":{"node.name":"input"}}}]\n'
	}
	pw-link() {
		[[ "$1" == -i ]] && printf 'input:input_FL\n'
		return 0
	}
	pactl() {
		[[ "$1" == get-default-source ]] && printf 'old_input\n'
		[[ "$1" != set-default-source ]]
	}
	write_pid_file() { :; }
	create_source
	assert_eq old_input "$ORIGINAL_DEFAULT_SOURCE" "failed default source remembered"
)

case_capture_management() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	local source_index=9
	pactl() {
		case "$*" in
		'list short sources') printf '9\taudio_share.monitor\n' ;;
		'list source-outputs')
			printf 'Source Output #5\n\tSource: %s\n\tProperties:\n\t\tnode.name = "sunshine"\n' "$source_index"
			;;
		'move-source-output 5 audio_share.monitor')
			printf '%s\n' "$*" >>"$RUNTIME_DIR/calls"
			;;
		esac
	}
	PINNED_CAPTURES=()
	manage_capture_streams
	[[ -v 'PINNED_CAPTURES[sunshine]' ]] || fail "capture stream was not pinned"
	source_index=8
	manage_capture_streams
	assert_contains "$(<"$RUNTIME_DIR/calls")" 'move-source-output 5 audio_share.monitor' "capture stream re-pinned"
	pactl() {
		[[ "$*" == 'list short sources' ]] && printf '9\taudio_share.monitor\n'
		return 0
	}
	manage_capture_streams
	assert_failure test -v 'PINNED_CAPTURES[sunshine]'
)

case_sweep_stray_streams() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	pactl() {
		case "$*" in
		'list short sinks') printf '1\taudio_share\n2\tspeakers\n' ;;
		'list sink-inputs')
			printf 'Sink Input #5\n\tSink: 1\n\tProperties:\n\t\tnode.name = "keep"\n'
			printf 'Sink Input #6\n\tSink: 1\n\tProperties:\n\t\tnode.name = "stray"\n'
			;;
		'move-sink-input 6 speakers') printf '%s\n' "$*" >>"$RUNTIME_DIR/calls" ;;
		'move-sink-input 5 speakers') fail "mute-local stream was rescued" ;;
		esac
	}
	LAST_KNOWN_DEFAULT=speakers
	MUTE_LOCAL=true
	CAPTURED=([10]=keep)
	_sweep_strays_from_sink
	assert_contains "$(<"$RUNTIME_DIR/calls")" 'move-sink-input 6 speakers' "stray stream rescued"
)

case_get_default_sink() (
	pactl() { printf 'speakers\n'; }
	get_default_sink
	assert_eq speakers "$STARTUP_DEFAULT_SINK" "startup default sink"
	assert_eq speakers "$LAST_KNOWN_DEFAULT" "last real default sink"
)

case_default_guard() (
	local default_sink=speakers
	pactl() {
		case "$*" in
		'get-default-sink') printf '%s\n' "$default_sink" ;;
		'list short sinks') printf '1\tspeakers\n2\taudio_share\n3\tvirtual\n' ;;
		'set-default-sink speakers') default_sink=speakers ;;
		'list short sources') printf '9\taudio_share.monitor\n' ;;
		'list source-outputs') printf 'Source Output #5\n\tSource: 9\n\tProperties:\n\t\tnode.name = "sunshine"\n' ;;
		'list sink-inputs') : ;;
		esac
		return 0
	}
	pw-dump() {
		case "$default_sink" in
		virtual | audio_share) printf '[{"info":{"props":{"node.name":"%s","media.class":"Audio/Sink","factory.name":"support.null-audio-sink"}}}]\n' "$default_sink" ;;
		*) make_graph ;;
		esac
	}
	guard_default_sink
	assert_eq speakers "$LAST_KNOWN_DEFAULT" "real default remembered"
	default_sink=virtual
	_GUARD_LAST_CUR=''
	guard_default_sink
	default_sink=audio_share
	DEFAULT_SHARE_BY_USER=true
	_GUARD_LAST_CUR=''
	guard_default_sink
)

case_capture_stream_modes() (
	link_stream_to_sink() { return 0; }
	MUTE_LOCAL=false
	capture_stream 10 mpv mpv
	[[ -v 'CAPTURED[10]' ]] || fail "non-mute capture"
	link_stream_to_sink() { return 1; }
	assert_failure capture_stream 11 bad bad
	MUTE_LOCAL=true
	stream_owned_by_peer() { return 1; }
	move_stream_to_sink() { return 0; }
	capture_stream 12 game Game
	stream_owned_by_peer() { return 0; }
	assert_failure capture_stream 13 peer Peer
	restore_stream_from_sink() { :; }
	release_stream 12
	assert_failure test -v 'CAPTURED[12]'

	MUTE_LOCAL=false
	CAPTURED[14]=music
	unlink_stream_from_sink() { return 1; }
	assert_failure release_stream 14
	assert_success test -v 'CAPTURED[14]'
	unlink_stream_from_sink() { return 0; }
	_unpin_stream_from_sink() { :; }
	assert_success release_stream 14
	assert_failure test -v 'CAPTURED[14]'
)

case_move_restore_streams() (
	get_sink_input_indices() { printf '1:10\n2:20\n'; }
	get_sink_name_by_index() {
		case "$1" in
		10) printf 'speakers\n' ;;
		20) printf 'audio_share\n' ;;
		esac
	}
	current_default_sink() { printf 'speakers\n'; }
	local mode=success
	pactl() {
		if [[ "$1" == move-sink-input ]]; then
			case "$mode:$2:$3" in
			move-failure:1:audio_share | restore-fallback:1:headphones | restore-failure:1:* | unpin-failure:2:speakers) return 1 ;;
			esac
		fi
		return 0
	}
	assert_success move_stream_to_sink mpv
	[[ -v 'MOVED_INPUTS[1]' ]] || fail "original stream sink not saved"
	MOVED_INPUTS[1]=headphones
	mode=restore-fallback
	restore_stream_from_sink mpv
	assert_eq 0 "${#MOVED_INPUTS[@]}" "moved inputs restored"
	MOVED_INPUTS[1]=headphones
	mode=restore-failure
	restore_stream_from_sink mpv
	mode=unpin-failure
	_unpin_stream_from_sink mpv
	mode=move-failure
	get_sink_input_indices() { printf '1:10\n'; }
	assert_failure move_stream_to_sink mpv
	get_sink_input_indices() { :; }
	assert_failure move_stream_to_sink absent
	restore_stream_from_sink absent
	_unpin_stream_from_sink absent
)

case_pactl_lookup_helpers() (
	pactl() {
		case "$*" in
		'list sink-inputs')
			printf 'Sink Input #7\n\tSink: 2\n\tProperties:\n\t\tnode.name = "mpv"\n'
			;;
		'list short sinks') printf '2\tspeakers\n' ;;
		esac
	}
	assert_eq '7:2' "$(get_sink_input_indices mpv)" "sink-input parser"
	assert_eq speakers "$(get_sink_name_by_index 2)" "sink-name parser"
)

case_peer_ownership() (
	get_sink_input_indices() { printf '1:10\n'; }
	get_sink_name_by_index() { printf 'peer\n'; }
	peer_sink_names() { printf 'peer\n'; }
	assert_success stream_owned_by_peer mpv
	peer_sink_names() { :; }
	assert_failure stream_owned_by_peer mpv
	get_sink_input_indices() { :; }
	assert_failure stream_owned_by_peer mpv
)

case_bulk_capture_and_scan() (
	get_audio_streams() {
		printf '%s\n' \
			'{"id":10,"node_name":"mpv","app_name":"mpv","media_name":"Movie"}' \
			'{"id":11,"node_name":"alert","app_name":"Alert","media_name":"Notification"}' \
			'{"node_name":"broken"}'
	}
	capture_stream() {
		[[ "$1" != 11 ]] && CAPTURED["$1"]="$2"
	}
	EXCLUDE=(alert)
	capture_existing_streams
	[[ -v 'CAPTURED[10]' ]] || fail "existing stream capture"
	CAPTURED=()
	EXCLUDE=()
	MANUAL_REMOVE=([10]=1)
	MANUAL_ADD=([11]=1)
	scan_new_streams
	[[ -v 'SKIPPED[11]' ]] || fail "failed manual capture recorded as skipped"
	MANUAL_REMOVE=()
	MANUAL_ADD=()
	SKIPPED=()
	scan_new_streams
	[[ -v 'SKIPPED[11]' ]] || fail "failed automatic capture recorded as skipped"
)

case_verify_links() (
	guard_default_sink() { :; }
	pw-dump() { make_graph; }
	pw-link() { [[ "$1" == -o ]] && printf 'mic.mono:capture_MONO\n'; }
	link_stream_to_sink() { :; }
	link_input_to_sink() { :; }
	CAPTURED=([10]=mpv [99]=gone)
	OUR_LINKS=(["991|201"]=1)
	STREAM_LINKS=(["99|991|201"]=1)
	SKIPPED=([98]=1 [11]=1)
	CAPTURED_INPUTS=(["mic.mono"]=1 [missing]=1)
	SKIP_RETRY_CTR=$((SKIP_RETRY_EVERY - 1))
	verify_existing_links
	[[ -v 'CAPTURED[10]' && ! -v 'CAPTURED[99]' ]] || fail "stale stream verification"
	assert_eq 0 "${#OUR_LINKS[@]}" "stale stream link bookkeeping"
	assert_eq 0 "${#STREAM_LINKS[@]}" "stale stream node bookkeeping"
	assert_eq 0 "${#SKIPPED[@]}" "skipped stream retry"
	[[ -v 'CAPTURED_INPUTS[mic.mono]' && ! -v 'CAPTURED_INPUTS[missing]' ]] || fail "input verification"
)

case_verify_mute_links() (
	guard_default_sink() { :; }
	pw-dump() { make_graph; }
	pw-link() { :; }
	get_sink_input_indices() { printf '5:7\n'; }
	get_sink_name_by_index() { printf 'speakers\n'; }
	stream_owned_by_peer() { return 1; }
	current_default_sink() { printf 'speakers\n'; }
	pactl() { :; }
	MUTE_LOCAL=true
	CAPTURED=([10]=mpv)
	verify_existing_links
	[[ -v 'MOVED_INPUTS[5]' ]] || fail "mute-local link was repaired"
	stream_owned_by_peer() { return 0; }
	verify_existing_links
	assert_failure test -v 'CAPTURED[10]'
)

case_cleanup() (
	RUNTIME_DIR=$(mktemp -d)
	trap 'rm -rf -- "$RUNTIME_DIR"' EXIT
	SINK_NAME=audio_share
	printf '1:2:3\n' >"$RUNTIME_DIR/audio_share.pid"
	TUI_ACTIVE=true
	MUTE_LOCAL=true
	CAPTURED=([10]=mpv)
	CAPTURED_INPUTS=([mic]=1)
	SET_DEFAULT_SOURCE=true
	ORIGINAL_DEFAULT_SOURCE=old_input
	SOURCE_MODULE_ID=30
	MODULE_ID=20
	LAST_KNOWN_DEFAULT=speakers
	restore_stream_from_sink() { :; }
	_sweep_strays_from_sink() { :; }
	unlink_input_from_sink() { :; }
	pactl() {
		[[ "$1" == get-default-sink ]] && printf 'audio_share\n'
		return 0
	}
	pw-cli() { :; }
	cleanup
	assert_eq true "$CLEANUP_DONE" "cleanup state"
	assert_eq false "$TUI_ACTIVE" "TUI restored during cleanup"
	assert_eq '' "$MODULE_ID" "sink cleanup"
	assert_eq '' "$SOURCE_MODULE_ID" "source cleanup"
	assert_failure test -e "$RUNTIME_DIR/audio_share.pid"
	cleanup
)

case_current_default_fallback() (
	STARTUP_DEFAULT_SINK=fallback
	pactl() { return 1; }
	assert_eq fallback "$(current_default_sink)" "default sink fallback"
	if (get_default_sink); then
		fail "missing default sink was accepted"
	fi
)

case_logging_and_usage
case_argument_parsing
case_argument_parsing_all
case_argument_actions
case_argument_stop_all
case_argument_exclude
case_argument_errors
case_argument_filter_error
case_argument_interactive_error
case_argument_help
case_dependencies
case_missing_dependencies
case_pid_files
case_instance_management
case_acquire_stale_lock
case_acquire_live_lock
case_stop_commands
case_stop_live_command
case_stop_stubborn_command
case_empty_status_and_entrypoint
case_discovery_and_filters
case_graph_linking
case_graph_lookup_failure
case_unlink_query_failures
case_partial_unlink_failure
case_graph_edge_failures
case_input_linking
case_route_inputs
case_sink_lifecycle
case_sink_failures
case_source_lifecycle
case_source_failure
case_source_timeout_and_default_failure
case_capture_management
case_sweep_stray_streams
case_get_default_sink
case_default_guard
case_capture_stream_modes
case_move_restore_streams
case_pactl_lookup_helpers
case_peer_ownership
case_bulk_capture_and_scan
case_verify_links
case_verify_mute_links
case_cleanup
case_current_default_fallback

printf 'PASS: core behavior\n'
