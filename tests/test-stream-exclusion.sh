#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only

set -euo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=pipewire-audio-share.sh
source "$TEST_ROOT/pipewire-audio-share.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
	printf "FAIL: %s\n" "$*" >&2
	exit 1
}

# Mock the graph and external commands: no live audio devices are touched.
pw-dump() {
	case "$GRAPH_STATE" in
	failed) return 1 ;;
	vanished)
		printf "[]\n"
		return 0
		;;
	esac
	cat <<-JSON
		[
			{"id":20,"info":{"props":{"node.name":"audio_share"}}},
			{"id":101,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":10}}},
			{"id":102,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":10}}},
			{"id":111,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":11}}},
			{"id":112,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":11}}},
			{"id":201,"type":"PipeWire:Interface:Port","info":{"direction":"input","props":{"node.id":20}}},
			{"id":202,"type":"PipeWire:Interface:Port","info":{"direction":"input","props":{"node.id":20}}},
			{"type":"PipeWire:Interface:Link","info":{"output-port-id":101,"input-port-id":201}},
			{"type":"PipeWire:Interface:Link","info":{"output-port-id":102,"input-port-id":202}},
			{"type":"PipeWire:Interface:Link","info":{"output-port-id":111,"input-port-id":201}},
			{"type":"PipeWire:Interface:Link","info":{"output-port-id":112,"input-port-id":202}},
			{"type":"PipeWire:Interface:Link","info":{"output-port-id":101,"input-port-id":301}},
			{"type":"PipeWire:Interface:Link","info":{"output-port-id":102,"input-port-id":302}}
		]
	JSON
}

pw-link() {
	printf "%s %s %s\n" "$1" "$2" "$3" >>"$TEST_DIR/unlinked"
}

get_audio_streams() {
	printf "%s\n" \
		"{\"id\":10,\"node_name\":\"mpv\",\"app_name\":\"mpv\",\"media_name\":\"First\"}" \
		"{\"id\":11,\"node_name\":\"mpv\",\"app_name\":\"mpv\",\"media_name\":\"Second\"}"
}

get_sink_input_indices() {
	printf "1:30\n"
}

get_sink_name_by_index() {
	printf "speakers\n"
}

tui_size() { TERM_COLS=80; }

# Feed symbolic keys through stdin, including Space and ENTER, without a TTY.
tui_read_key() {
	local key
	IFS= read -r key || fail "Menu did not return on the back key"
	printf "%s" "$key"
}

run_case() (
	local keys="$1" target="$2" other="$3"
	GRAPH_STATE="${4:-active}"
	TUI_ACTIVE=true
	CAPTURED=([10]=mpv [11]=mpv)
	OUR_LINKS=(["101|201"]=1 ["102|202"]=1 ["111|201"]=1 ["112|202"]=1)
	STREAM_LINKS=(
		["10|101|201"]=1
		["10|102|202"]=1
		["11|111|201"]=1
		["11|112|202"]=1
	)
	: >"$TEST_DIR/unlinked"

	# Invoke normally, not in an if/|| context that would disable errexit.
	tui_menu_streams <<<"$keys" 2>"$TEST_DIR/menu"
	[[ ! -v "CAPTURED[$target]" && -v "MANUAL_REMOVE[$target]" ]] || fail "Selected stream was not excluded"
	local stream_key
	for stream_key in "${!STREAM_LINKS[@]}"; do
		[[ "${stream_key%%|*}" != "$target" ]] || fail "Selected stream left node link bookkeeping"
	done
	if [[ "$other" == all ]]; then
		[[ ${#CAPTURED[@]} == 0 && ${#MANUAL_REMOVE[@]} == 2 ]] || fail "Release all missed a stream"
		[[ ${#STREAM_LINKS[@]} == 0 ]] || fail "Release all left node link bookkeeping"
	else
		[[ -v "CAPTURED[$other]" && ! -v "MANUAL_REMOVE[$other]" ]] || fail "Duplicate-named stream was also excluded"
		local port
		for port in "${other}1" "${other}2"; do
			[[ -v "OUR_LINKS[$port|201]" || -v "OUR_LINKS[$port|202]" ]] || fail "Other stream lost link bookkeeping"
		done
	fi

	local actual expected=""
	actual=$(<"$TEST_DIR/unlinked")
	if [[ "$GRAPH_STATE" == active ]]; then
		if [[ "$other" == all ]]; then
			[[ ${#OUR_LINKS[@]} == 0 ]] || fail "Release all left tracked links"
			expected=$(printf "%s\n" "-d 101 201" "-d 102 202" "-d 111 201" "-d 112 202")
		else
			[[ ${#OUR_LINKS[@]} == 2 ]] || fail "Selected stream left tracked links"
			expected=$(printf -- "-d %s1 201\n-d %s2 202\n" "$target" "$target")
		fi
	fi
	[[ "$(sort <<<"$actual")" == "$(sort <<<"$expected")" ]] || fail "Wrong ports unlinked (including local playback)"
	printf "PASS: exclude %s (%s, keys %q)\n" "$target" "$GRAPH_STATE" "$keys"
)

run_case $' \nb' 10 11
run_case $'ENTER\nb' 10 11
run_case $'1\nb' 10 11
run_case $'2\nb' 11 10
run_case $'r\nb' 10 all
run_case $'1\nb' 10 11 vanished

# Do not mask actual graph-query errors with the successful cleanup return.
GRAPH_STATE=failed
if unlink_stream_from_sink 10; then
	fail "Failed graph query was reported as successful"
fi
printf "PASS: graph-query failure is preserved\n"
