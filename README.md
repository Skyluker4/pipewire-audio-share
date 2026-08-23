# pipewire-audio-share

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

| Feature                  | Description                                                                                   |
| ------------------------ | --------------------------------------------------------------------------------------------- |
| **Virtual null sink**    | Creates a dedicated PipeWire sink with monitor ports that capture software can read           |
| **Virtual source**       | Optionally exposes the sink as a regular input device (microphone) for apps like Discord      |
| **Input device routing** | Route hardware microphones and line-ins into the shared sink alongside application audio      |
| **Auto-capture**         | Automatically routes every new audio stream into the sink (on by default)                     |
| **Include / Exclude**    | Case-insensitive substring matching against application and node names                        |
| **Mute local**           | Optionally silence captured streams on your speakers — restored on exit                       |
| **Multiple instances**   | Run several sinks simultaneously with independent filters and options                         |
| **Instance management**  | `--status`, `--stop`, `--stop-all` for controlling background instances                       |
| **Stale recovery**       | Crashed instances leave no orphaned sinks — automatically cleaned up                          |
| **Interactive TUI**      | Full terminal UI for live stream toggling, volume control, output routing, and config editing |
| **Default-sink aware**   | Tracks the _current_ default sink dynamically, not just the one at startup                    |
| **Peer-aware muting**    | Multiple `--mute-local` instances won't fight over the same stream                            |

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
git clone <url> pipewire-audio-share
cd pipewire-audio-share
chmod +x pipewire-audio-share.sh

# Optional: symlink into your PATH
ln -s "$PWD/pipewire-audio-share.sh" ~/.local/bin/pipewire-audio-share
```

There is nothing to compile. The entire tool is a single self-contained
Bash script.

---

## Quick start

```sh
# Share all application audio — you still hear everything locally
./pipewire-audio-share.sh

# Share only Firefox and mpv
./pipewire-audio-share.sh -I firefox -I mpv

# Share everything except notification sounds
./pipewire-audio-share.sh -X notification -X alert

# Share everything, silence local speakers (restored on exit)
./pipewire-audio-share.sh --mute-local

# Launch the interactive TUI
./pipewire-audio-share.sh -i

# Also create a virtual microphone from the shared audio
./pipewire-audio-share.sh --source

# Virtual mic as default input (for apps that only see "default")
./pipewire-audio-share.sh -S --default-source

# Route a microphone into the shared audio mix
./pipewire-audio-share.sh -R headset

# Route multiple input devices
./pipewire-audio-share.sh -R webcam -R line-in
```

Press **Ctrl+C** to stop. The virtual sink is removed and all streams are
restored to their original routing.

---

## Usage

```text
pipewire-audio-share.sh [OPTIONS]
pipewire-audio-share.sh -i [OPTIONS]
pipewire-audio-share.sh --status
pipewire-audio-share.sh --stop NAME
pipewire-audio-share.sh --stop-all
```

### Options

| Flag                         | Description                                                   | Default        |
| ---------------------------- | ------------------------------------------------------------- | -------------- |
| `-n`, `--sink-name NAME`     | PipeWire sink name                                            | `audio_share`  |
| `-d`, `--description DESC`   | Human-readable description shown in pavucontrol etc.          | `Audio Share`  |
| `-a`, `--auto-capture`       | Capture new streams as they appear                            | **on**         |
| `-A`, `--no-auto-capture`    | Only capture streams present at startup                       |                |
| `-I`, `--include APP`        | Application pattern to capture (repeatable)                   |                |
| `-X`, `--exclude APP`        | Application pattern to exclude (repeatable)                   |                |
| `-m`, `--mute-local`         | Don't play captured audio on the default output               | off            |
| `-R`, `--route-input DEVICE` | Route an input device (mic, line-in) to the sink (repeatable) |                |
| `-S`, `--source`             | Also create a virtual input device (source/mic)               | off            |
| `--source-name NAME`         | Name for the virtual source                                   | `<sink>_input` |
| `--source-description DESC`  | Description for the virtual source                            |                |
| `--default-source`           | Set virtual source as system default input (implies `-S`)     | off            |
| `-p`, `--poll-interval SECS` | How often to scan for changes                                 | `2`            |
| `-i`, `--interactive`        | Launch interactive TUI (requires a terminal)                  |                |
| `-v`, `--verbose`            | Print debug-level log output                                  |                |
| `-h`, `--help`               | Show built-in help text                                       |                |

### Management commands

| Command       | Description                                                                     |
| ------------- | ------------------------------------------------------------------------------- |
| `--status`    | List all running pipewire-audio-share instances with PID, module ID, and status |
| `--stop NAME` | Gracefully stop the instance managing the named sink                            |
| `--stop-all`  | Stop every running instance                                                     |

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
./pipewire-audio-share.sh -i
./pipewire-audio-share.sh -i -n sunshine -I firefox -I mpv -I steam
```

The TUI runs inside an **alternate screen buffer** so it doesn't pollute
your scrollback. Background monitoring continues while you navigate menus.

### Menu structure

```text
Main ─┬─ [s] Streams ──── toggle capture on individual applications
      ├─ [v] Volume ───── adjust sink and per-stream volume, mute/unmute
      ├─ [r] Route inputs  toggle routing of hardware mics/line-ins
      ├─ [o] Output ───── switch default hardware sink, toggle mute-local
      ├─ [c] Config ───── auto-capture, poll interval, include/exclude
      ├─ [i] Info ─────── sink details, captured streams, running instances
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

### Route inputs menu

| Key               | Action                                |
| ----------------- | ------------------------------------- |
| **↑ / ↓**         | Navigate the input device list        |
| **Space / Enter** | Toggle routing on the selected device |
| **1--9**          | Quick-toggle by number                |
| **a**             | Route all input devices               |
| **n**             | Unroute all input devices             |
| **b / Esc**       | Back to main menu                     |

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
| **s**       | Toggle virtual source device on/off                 |
| **d**       | Toggle virtual source as default input device       |
| **w**       | Edit include (prompts for comma-separated patterns) |
| **e**       | Edit exclude (prompts for comma-separated patterns) |
| **b / Esc** | Back                                                |

---

## Multiple instances

Run as many instances as you need with different `--sink-name` values:

```sh
# Terminal 1: Sunshine gets browser and game audio
pipewire-audio-share.sh -n sunshine -d "Sunshine" -I firefox -I steam &

# Terminal 2: Discord bot gets only the music player, silenced locally
pipewire-audio-share.sh -n discord -d "Discord Bot" -I music --mute-local &

# Check on them
pipewire-audio-share.sh --status

# Stop one
pipewire-audio-share.sh --stop discord

# Stop everything
pipewire-audio-share.sh --stop-all
```

Each instance:

- Has its own **PID file** in `$XDG_RUNTIME_DIR/pipewire-audio-share/`
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
                  ▼                               │                  │
           ┌──────────────┐                       │                  │
           │ Default Sink │  ◂── you still hear   │                  │
           │ (speakers)   │      audio here       │                  │
           └──────────────┘                       │                  │
                                                  │                  │
┌──────────────┐     pw-link (--route-input)      │                  │
│  Microphone  ├──────────────────────────────────▸ playback_FL/FR   │
│  (headset)   │                                  └──────────────────┘
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

4. If **`--route-input`** is given, the matching input device's capture
   ports are linked to the sink's playback ports via `pw-link`, mixing
   mic/line-in audio into the shared sink alongside application audio.
   Mono inputs are mapped to both stereo channels.

5. If **`--source`** is given, a native PipeWire **`Audio/Source/Virtual`**
   node is created and linked to the sink's monitor, exposing it as a
   regular input device with the `HARDWARE` flag. This makes it visible
   to most applications (Discord, Zoom, OBS, etc.) as a selectable
   microphone. If **`--default-source`** is also given, it is set as the
   system default input device (restored on exit), which makes it
   available to applications like Audacity that only enumerate the
   default device.

6. A **polling loop** (configurable interval, default 2s) continuously:
   - Discovers new streams and captures them (if auto-capture is on)
   - Verifies existing links haven't been broken and re-creates them
   - Re-evaluates skipped streams in case a peer instance released them

7. On **exit** (Ctrl+C, SIGTERM, SIGHUP), the cleanup handler:
   - Restores muted streams to the _current_ default sink (not the startup one)
   - Unlinks routed input devices
   - Unloads the source node (if created)
   - Unloads the null-sink module
   - Removes the PID file

### Default sink changes

The script queries the default sink **live** whenever it needs to restore
a stream. If you switch from headphones to speakers while the script is
running, cleanup will restore streams to the correct device.

The default output is also **guarded**: some capture software (notably
Sunshine, which sets the default sink to a virtual sink such as
`sink-sunshine-stereo` or to its capture sink every time a client
connects) can switch the default output away from your real device. Once
per poll cycle the script notices any default that points at a virtual
(null) sink and switches it back to your last real output device, so your
local playback and per-app routing are undisturbed. Streams that got
pinned to the share sink by such a hijack are moved back too. Setting the
virtual sink as the default deliberately is still possible from the TUI's
_Output_ menu.

Capture clients (Sunshine, OBS, ...) that attach to the share's monitor
are **pinned** to it: when a default-sink change would move them over to
your real output's monitor — which would leak your entire local mix
(including excluded apps) into the stream — they are moved back to the
share's monitor automatically.

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

1. Start pipewire-audio-share before or alongside Sunshine:

   ```sh
   pipewire-audio-share.sh -n sunshine -d "Sunshine Audio" &
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

> **Note:** every time a client connects, Sunshine switches the system
> default sink (to `sink-sunshine-stereo` or to its configured capture
> sink) in order to locate the monitor to record. pipewire-audio-share
> detects this and switches the default back to your real output within
> one poll cycle, so your local audio is not hijacked and unrelated
> streams are not pinned into the share. Sunshine's capture stream is
> pinned to `audio_share.monitor`, so it keeps receiving exactly the
> shared audio instead of being dragged onto your real output's monitor.
>
> **Note:** when you stop pipewire-audio-share, the virtual sink and all
> of its links are removed completely. If your Moonlight client still
> hears audio afterwards, that is Sunshine re-acquiring the _default_
> output's monitor (your headphones/speakers) now that `audio_share` is
> gone — end the stream from Moonlight or stop Sunshine to cut it.

### OBS Studio

1. Start pipewire-audio-share:

   ```sh
   pipewire-audio-share.sh -n obs_capture -d "OBS Capture" &
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

| Path                                          | Purpose                                        |
| --------------------------------------------- | ---------------------------------------------- |
| `pipewire-audio-share.sh`                     | The entire tool — single self-contained script |
| `$XDG_RUNTIME_DIR/pipewire-audio-share/*.pid` | Per-instance PID files (`PID:MODULE_ID`)       |

---

## Troubleshooting

### "Sink 'audio_share' is already managed by PID …"

Another instance is already running with that sink name. Either stop it
first or use a different `--sink-name`:

```sh
pipewire-audio-share.sh --stop audio_share
# or
pipewire-audio-share.sh -n my_other_sink
```

### Stale sink after a crash

If the script was killed with SIGKILL (or the system crashed), the null
sink module may still be loaded. The next start auto-detects this via the
PID file and unloads the orphaned module:

```text
WARN: Found stale PID file for 'audio_share' (PID 12345 is dead)
Unloading orphaned module 536870916 from previous crash
```

### Virtual source not visible in Audacity

Audacity enumerates only a subset of PipeWire sources. It typically shows
a single "pipewire" or "default" device. To use the virtual source in
Audacity, add `--default-source`:

```sh
pipewire-audio-share.sh -S --default-source
```

This sets the virtual source as the system default input device (restored
on exit). In Audacity, select the **pipewire** or **default** source and
it will receive the shared audio. Alternatively, set the default source
manually in pavucontrol's _Input Devices_ tab.

If the PID file was also lost, the script detects the existing sink by
name and unloads just that specific module (not all null sinks).

### No audio in capture software

- Verify the sink exists: `pactl list short sinks | grep audio_share`
- Verify streams are linked: `pw-link -l | grep audio_share`
- Check that your capture software is reading from the **monitor** source
  (`audio_share.monitor`), not the sink itself
- Run with `-v` for verbose output to see exactly what's happening

### A removed stream is still audible in the share

If a stream appeared while the virtual sink was the system default (e.g.
right after a Sunshine client connected), WirePlumber linked the stream to
the share sink directly — outside of the links the script tracks. Releasing
such a stream removes **all** of its links to the share sink (whoever
created them) and moves it back to the current default output, so it can
no longer be heard in the share. This applies to both the TUI toggle and
"release all". Streams pinned to the share sink by a default-sink hijack
are also moved back to your real output automatically once per poll cycle.

### The stream contains my whole local mix / an echo of the remote side

When the default sink changes, capture clients that record a monitor get
moved to the new default's monitor by WirePlumber/pipewire-pulse. If that
moves your capture client (Sunshine, ...) from `audio_share.monitor` to
your headset/speaker monitor, the stream suddenly carries everything you
hear locally — including apps excluded from the share (your friends hear
themselves). The script pins every capture client that attaches to the
share's monitor and moves it back automatically, so this can only leak
for about one poll cycle per external default change.

### Volume is at 0% or muted

Use the interactive TUI (`-i`) to check and adjust volume, or:

```sh
pactl set-sink-volume audio_share 100%
pactl set-sink-mute audio_share 0
```

---

## License

Copyright © 2026 Luke Andrew Simmons

This program is free software: you can redistribute it and/or modify it
under the terms of the [GNU Affero General Public License, version 3](https://www.gnu.org/licenses/agpl-3.0.html)
only, as published by the Free Software Foundation.

If the FSF publishes a new version of the GNU Affero General Public
License, Luke Andrew Simmons (or their designated successor) is the proxy
who may decide whether future versions of that license apply to this work.

See [LICENSE](LICENSE) for the full text.
