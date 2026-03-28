# audio-share

A PipeWire virtual sink manager that routes application audio into a
capture-ready sink for streaming software like [Sunshine], [OBS], or any
program that can record from a PulseAudio/PipeWire monitor source.

Your default speakers keep working — audio is _duplicated_ into the virtual
sink rather than redirected, unless you explicitly ask for silent local
playback with `--mute-local`.

[Sunshine]: https://github.com/LizardByte/Sunshine
[OBS]: https://obsproject.com/

---

## Features

| Feature                 | Description                                                                                   |
| ----------------------- | --------------------------------------------------------------------------------------------- |
| **Virtual null sink**   | Creates a dedicated PipeWire sink with monitor ports that capture software can read           |
| **Auto-capture**        | Automatically routes every new audio stream into the sink (on by default)                     |
| **Include / Exclude**   | Case-insensitive substring matching against application and node names                        |
| **Mute local**          | Optionally silence captured streams on your speakers — restored on exit                       |
| **Multiple instances**  | Run several sinks simultaneously with independent filters and options                         |
| **Instance management** | `--status`, `--stop`, `--stop-all` for controlling background instances                       |
| **Stale recovery**      | Crashed instances leave no orphaned sinks — automatically cleaned up                          |
| **Interactive TUI**     | Full terminal UI for live stream toggling, volume control, output routing, and config editing |
| **Default-sink aware**  | Tracks the _current_ default sink dynamically, not just the one at startup                    |
| **Peer-aware muting**   | Multiple `--mute-local` instances won't fight over the same stream                            |

---

## Requirements

- **PipeWire** with **PipeWire-Pulse** (the PulseAudio compatibility layer)
- **WirePlumber** (or another PipeWire session manager)
- Standard PipeWire command-line tools:
  - `pw-link`
  - `pw-dump`
  - `pactl`
- [`jq`](https://jqlang.github.io/jq/)
- **Bash** ≥ 4.4 (for associative arrays and `${var@Q}`)

On most distributions these are already installed as part of a working
PipeWire desktop audio stack. On Gentoo:

```sh
emerge --ask media-video/pipewire media-video/wireplumber app-misc/jq
```

On Arch:

```sh
pacman -S pipewire pipewire-pulse wireplumber jq
```

---

## Installation

```sh
git clone <url> audio-share
cd audio-share
chmod +x audio-share.sh

# Optional: symlink into your PATH
ln -s "$PWD/audio-share.sh" ~/.local/bin/audio-share
```

There is nothing to compile. The entire tool is a single self-contained
Bash script.

---

## Quick start

```sh
# Share all application audio — you still hear everything locally
./audio-share.sh

# Share only Firefox and mpv
./audio-share.sh -I firefox -I mpv

# Share everything except notification sounds
./audio-share.sh -X notification -X alert

# Share everything, silence local speakers (restored on exit)
./audio-share.sh --mute-local

# Launch the interactive TUI
./audio-share.sh -i
```

Press **Ctrl+C** to stop. The virtual sink is removed and all streams are
restored to their original routing.

---

## Usage

```text
audio-share.sh [OPTIONS]
audio-share.sh -i [OPTIONS]
audio-share.sh --status
audio-share.sh --stop NAME
audio-share.sh --stop-all
```

### Options

| Flag                         | Description                                          | Default       |
| ---------------------------- | ---------------------------------------------------- | ------------- |
| `-n`, `--sink-name NAME`     | PipeWire sink name                                   | `audio_share` |
| `-d`, `--description DESC`   | Human-readable description shown in pavucontrol etc. | `Audio Share` |
| `-a`, `--auto-capture`       | Capture new streams as they appear                   | **on**        |
| `-A`, `--no-auto-capture`    | Only capture streams present at startup              |               |
| `-I`, `--include APP`        | Application pattern to capture (repeatable)          |               |
| `-X`, `--exclude APP`        | Application pattern to exclude (repeatable)          |               |
| `-m`, `--mute-local`         | Don't play captured audio on the default output      | off           |
| `-p`, `--poll-interval SECS` | How often to scan for changes                        | `2`           |
| `-i`, `--interactive`        | Launch interactive TUI (requires a terminal)         |               |
| `-v`, `--verbose`            | Print debug-level log output                         |               |
| `-h`, `--help`               | Show built-in help text                              |               |

### Management commands

| Command       | Description                                                            |
| ------------- | ---------------------------------------------------------------------- |
| `--status`    | List all running audio-share instances with PID, module ID, and status |
| `--stop NAME` | Gracefully stop the instance managing the named sink                   |
| `--stop-all`  | Stop every running instance                                            |

### Pattern matching

Include and exclude patterns are matched **case-insensitively** as
**substrings** against both the PipeWire `node.name`
(e.g. `alsa_playback.firefox`) and the `application.name`
(e.g. `Firefox`).

Partial matches work: `-I fire` captures Firefox.

Include and exclude are mutually exclusive.

---

## Interactive TUI

Launch with `-i`:

```sh
./audio-share.sh -i
./audio-share.sh -i -n sunshine -I firefox -I mpv -I steam
```

The TUI runs inside an **alternate screen buffer** so it doesn't pollute
your scrollback. Background monitoring continues while you navigate menus.

### Menu structure

```text
Main ─┬─ [s] Streams ── toggle capture on individual applications
      ├─ [v] Volume ─── adjust sink and per-stream volume, mute/unmute
      ├─ [o] Output ─── switch default hardware sink, toggle mute-local
      ├─ [c] Config ─── auto-capture, poll interval, include/exclude
      ├─ [i] Info ───── sink details, captured streams, running instances
      └─ [q] Quit
```

### Streams menu

| Key               | Action                                |
| ----------------- | ------------------------------------- |
| **↑ / ↓**         | Navigate the stream list              |
| **Space / Enter** | Toggle capture on the selected stream |
| **1–9**           | Quick-toggle by number                |
| **a**             | Capture all streams                   |
| **r**             | Release all streams                   |
| **b / Esc**       | Back to main menu                     |

Manually toggled streams override the include/exclude. A manually
removed stream won't be re-captured by auto-capture, and a manually added
stream ignores filters.

### Volume menu

| Key         | Action                                       |
| ----------- | -------------------------------------------- |
| **↑ / ↓**   | Select the virtual sink or a captured stream |
| **← / →**   | Adjust volume by ±5%                         |
| **[ / ]**   | Fine adjustment by ±1%                       |
| **0**       | Toggle mute                                  |
| **b / Esc** | Back                                         |

Volume bars are colour-coded: green ≤60%, yellow 61–85%, red >85%.

### Output menu

| Key             | Action                                                            |
| --------------- | ----------------------------------------------------------------- |
| **↑ / ↓**       | Navigate available hardware sinks                                 |
| **Enter / 1–9** | Set as default output                                             |
| **m**           | Toggle mute-local (live — streams are moved/restored immediately) |
| **b / Esc**     | Back                                                              |

### Config menu

| Key         | Action                                              |
| ----------- | --------------------------------------------------- |
| **a**       | Toggle auto-capture                                 |
| **m**       | Toggle mute-local                                   |
| **p**       | Change poll interval (prompts for input)            |
| **w**       | Edit include (prompts for comma-separated patterns) |
| **e**       | Edit exclude (prompts for comma-separated patterns) |
| **b / Esc** | Back                                                |

---

## Multiple instances

Run as many instances as you need with different `--sink-name` values:

```sh
# Terminal 1: Sunshine gets browser and game audio
audio-share.sh -n sunshine -d "Sunshine" -I firefox -I steam &

# Terminal 2: Discord bot gets only the music player, silenced locally
audio-share.sh -n discord -d "Discord Bot" -I music --mute-local &

# Check on them
audio-share.sh --status

# Stop one
audio-share.sh --stop discord

# Stop everything
audio-share.sh --stop-all
```

Each instance:

- Has its own **PID file** in `$XDG_RUNTIME_DIR/audio-share/`
- Creates its own **null sink** with a unique module ID
- Manages its own set of **captured streams** independently
- **Refuses to start** if the sink name is already taken by a live instance
- **Recovers stale state** if a previous instance crashed (SIGKILL, power loss)

When multiple instances run with `--mute-local`, they are **peer-aware** —
an instance won't try to move a stream that's already parked on another
instance's sink.

---

## How it works

### Architecture

```text
┌──────────────┐     pw-link (supplementary)     ┌──────────────────┐
│  Application ├──────────────────────────────────▸ audio_share      │
│  (Firefox)   ├──┐                               │  (null sink)     │
└──────────────┘  │                               │                  │
                  │  WirePlumber (managed)         │  monitor_FL ─────▸ Sunshine / OBS
                  │                               │  monitor_FR ─────▸ reads these
                  ▼                               └──────────────────┘
           ┌──────────────┐
           │ Default Sink │  ◂── you still hear audio here
           │ (speakers)   │
           └──────────────┘
```

1. **`pactl load-module module-null-sink`** creates a virtual sink with
   playback (input) ports and monitor (output) ports.

2. For each matching audio stream, **`pw-link`** creates a _supplementary_
   link from the stream's output ports to the virtual sink's playback
   ports. The existing WirePlumber-managed link to your speakers stays
   in place — audio plays on both.

3. If **`--mute-local`** is given, **`pactl move-sink-input`** is used
   instead, which tells WirePlumber to route the stream _exclusively_ to
   the virtual sink. This cooperates with WirePlumber rather than fighting
   it, so there are no re-linking loops.

4. A **polling loop** (configurable interval, default 2s) continuously:
   - Discovers new streams and captures them (if auto-capture is on)
   - Verifies existing links haven't been broken and re-creates them
   - Re-evaluates skipped streams in case a peer instance released them

5. On **exit** (Ctrl+C, SIGTERM, SIGHUP), the cleanup handler:
   - Restores muted streams to the _current_ default sink (not the startup one)
   - Unloads the null-sink module
   - Removes the PID file

### Default sink changes

The script queries the default sink **live** whenever it needs to restore
a stream. If you switch from headphones to speakers while the script is
running, cleanup will restore streams to the correct device.

### Signal handling

```text
SIGTERM / SIGINT / SIGHUP  →  exit 0  →  EXIT trap  →  cleanup()
```

The EXIT trap is the sole owner of cleanup logic. Signal traps simply
trigger an exit, which guarantees cleanup runs exactly once regardless of
how the process is terminated. `sleep` is guarded with `|| true` to
prevent `set -e` from racing with signal delivery.

---

## Integration guides

### Sunshine

[Sunshine](https://github.com/LizardByte/Sunshine) is a self-hosted game
streaming server compatible with Moonlight.

1. Start audio-share before or alongside Sunshine:

   ```sh
   audio-share.sh -n sunshine -d "Sunshine Audio" &
   ```

2. In the Sunshine web UI (**Configuration → Audio**), set the
   **Virtual Sink** to:

   ```text
   sink:audio_share
   ```

   Or if Sunshine asks for a **monitor source**:

   ```text
   audio_share.monitor
   ```

3. All desktop audio now streams to your Moonlight client. Add
   `-I` to limit which applications are shared, or
   `--mute-local` to silence local speakers while streaming.

### OBS Studio

1. Start audio-share:

   ```sh
   audio-share.sh -n obs_capture -d "OBS Capture" &
   ```

2. In OBS, add an **Audio Input Capture** source (PulseAudio mode).

3. Select **"OBS Capture"** (or whatever you passed to `-d`) as the device.
   This corresponds to the sink's monitor source.

4. All captured application audio appears on that OBS source.

### pavucontrol / qpwgraph

The virtual sink appears in **pavucontrol** under the _Output Devices_ tab
with the description you passed to `-d`. Its monitor source appears under
_Input Devices_.

In **qpwgraph**, you'll see the additional links drawn from application
output ports to the virtual sink's input ports.

---

## Files

| Path                                 | Purpose                                        |
| ------------------------------------ | ---------------------------------------------- |
| `audio-share.sh`                     | The entire tool — single self-contained script |
| `$XDG_RUNTIME_DIR/audio-share/*.pid` | Per-instance PID files (`PID:MODULE_ID`)       |

---

## Troubleshooting

### "Sink 'audio_share' is already managed by PID …"

Another instance is already running with that sink name. Either stop it
first or use a different `--sink-name`:

```sh
audio-share.sh --stop audio_share
# or
audio-share.sh -n my_other_sink
```

### Stale sink after a crash

If the script was killed with SIGKILL (or the system crashed), the null
sink module may still be loaded. The next start auto-detects this via the
PID file and unloads the orphaned module:

```text
WARN: Found stale PID file for 'audio_share' (PID 12345 is dead)
Unloading orphaned module 536870916 from previous crash
```

If the PID file was also lost, the script detects the existing sink by
name and unloads just that specific module (not all null sinks).

### No audio in capture software

- Verify the sink exists: `pactl list short sinks | grep audio_share`
- Verify streams are linked: `pw-link -l | grep audio_share`
- Check that your capture software is reading from the **monitor** source
  (`audio_share.monitor`), not the sink itself
- Run with `-v` for verbose output to see exactly what's happening

### Volume is at 0% or muted

Use the interactive TUI (`-i`) to check and adjust volume, or:

```sh
pactl set-sink-volume audio_share 100%
pactl set-sink-mute audio_share 0
```

---

## License

Copyright © 2025 Luke Andrew Simmons

This program is free software: you can redistribute it and/or modify it
under the terms of the [GNU Affero General Public License, version 3](https://www.gnu.org/licenses/agpl-3.0.html)
only, as published by the Free Software Foundation.

If the FSF publishes a new version of the GNU Affero General Public
License, Luke Andrew Simmons (or their designated successor) is the proxy
who may decide whether future versions of that license apply to this work.

See [LICENSE](LICENSE) for the full text.
