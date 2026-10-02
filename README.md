# GuitarCozy Native

Native macOS port of GuitarCozy: C++20 core, Objective-C++ platform layer, Metal renderer, AppKit UI. The web build in `../guitarcozy` is the reference implementation; this port reproduces its gameplay rules and the GuitarCozy Paper design screen for screen.

## Build

Requirements: Xcode command line tools, CMake 3.24+, Homebrew `libvorbis`, `libogg` and `opus` (found through pkg-config).

```
cmake -S . -B build
cmake --build build -j8
./build/gctests                        # core tests (parsers, engine, bot playthrough, .sng)
open build/GuitarCozy.app
```

## Running from the terminal

```
./build/GuitarCozy.app/Contents/MacOS/GuitarCozy [options]
  --screen menu|songs|career|options|practice   open a screen directly
  --song <name substring>                       start that song (quickplay)
  --bot                                         autoplay (not persisted to settings)
  --difficulty expert  --instrument guitar
  --practice start,end,speed                    jump into practice mode
  --pause-at <seconds>                          auto-pause at that song time
  --actions down,down,confirm                   replay menu actions 0.25 s apart
  --song-folder <path>                          play a song folder or .sng directly (not added to the library)
  --rate N                                      play N× faster for quick playthroughs (nothing is saved)
  --actions-at <seconds>                        fire --actions at that wall time instead of at screen entry
  --screenshot out.png --seconds N              mute audio, capture after N s, quit
```

Screenshot mode is the visual test harness: it never plays audio, composites the Metal frame with the AppKit overlay and exits. `--keys 8:53` injects a real key press (seconds:keycode) through the normal event path.

Debug environment switches: `GC_BOT_JITTER=<ms>` makes the bot hit early/late at random, `GC_SP_AT=<s>` forces star power at a song time, `GC_WHAMMY=1` holds the whammy, `GC_RECORD_BOT=1` lets a bot run write a replay and history, `GC_SHADE=1|2` disables clearcoat / environment shading.

Set `GC_CLOCKLOG=1` to log frame pacing during normal play: song-time and wall-time deltas per 120 frames, any frame gap over 25 ms with a breakdown of the previous frame, run-loop busy time and label text changes. Measure in normal play, not screenshot mode, which serialises the CPU and GPU.

### Metal performance HUD

Run the bundle executable directly so it inherits the HUD environment variable:

```sh
cd /Users/brian/projects/GuitarCozyNative
MTL_HUD_ENABLED=1 ./build/GuitarCozy.app/Contents/MacOS/GuitarCozy
```

To jump straight into the demo highway:

```sh
MTL_HUD_ENABLED=1 ./build/GuitarCozy.app/Contents/MacOS/GuitarCozy --song "Highway Burn" --bot
```

The HUD shows Metal performance statistics while the renderer is active. Use normal play, not `--screenshot`, to measure performance. Quit and relaunch without `MTL_HUD_ENABLED=1` to disable it. Setting the variable on `open` does not reliably pass it to an app launched through Launch Services.

### App icon

`assets/icon/GuitarCozy.png` is the 1024px transparent icon master exported from the GuitarCozy Paper design. CMake bundles `assets/icon/GuitarCozy.icns` and declares it in the app's Info.plist. After replacing the PNG, regenerate the macOS icon sizes and rebuild:

```sh
bash scripts/generate-app-icon.sh
cmake -S . -B build
cmake --build build -j8
```

## Features

- Clone Hero song folders (`song.ini` + `notes.chart`/`notes.mid` + stems) and `.sng` packages. Packages are unpacked once into `~/Library/Application Support/GuitarCozy/sng/`.
- Stems in WAV/MP3/AAC/FLAC (AudioToolbox), Ogg Vorbis (libvorbis) and Opus (libopus), mixed sample-accurately on a CoreAudio output unit with an interpolated clock.
- Gameplay engine identical to the web build: ±90 ms window, strum leniency, HOPO/tap/open notes, chord anchoring, extended sustains, star power (whammy adds SP on phrases), solos, rock meter, sections, star ratings balancing the GH3 multiplier ladder with accuracy: 1–3★ from 1.0 / 2.0 / 2.8× or 50 / 70 / 85% hit; 4★ needs 3.6× (or 95% with 3.0×); 5★ needs 4.4× (or 98% with 4.0×); full combo → gold.
- Metal highway: HDR scene, instanced gems, neon rails, sustain trails with whammy wobble, procedural flames, sparks and hit rings, animated stage background or the song's `background.png/jpg`, bloom + colour grade + tone mapping, camera presets.
- Synthesized SFX (miss clank, star power on/off/ready, menu blips, fail, fanfare) and a crowd bed that swells with the rock meter and streak.
- Timing feedback: Perfect / Early / Late readout above the frets (perfect window adjustable under Options → Gameplay) and a hit-offset histogram on the results screen with an audio-offset hint.
- Quickplay modifiers on the song card: song speed (70–100%, records only save at 100%) and no-fail. Results offer "Practice <weakest section>" straight into a looping practice range.
- Play history per song/instrument/difficulty and input replays (every completed run is recorded; "Watch replay" on the results screen).
- Song video backgrounds (`video.mp4/mov/m4v`, synced to the transport) besides `background.png/jpg`.
- Controllers: GameController framework with haptics (star power, misses, fail) and motion tilt for star power, plus a raw IOKit HID fallback for guitars macOS does not expose as game controllers.
- Library: intensity bars from the song.ini ratings, "Sort: Recent" by last play. Scanning reads `.chart` files with a fast counter (no track building), so large libraries index in seconds.
- Engine on its own 1 kHz thread: hit judgement uses input timestamps and is independent of the frame rate; a stalled frame cannot turn a hit into a miss.
- Streaming audio: stems decode on a background thread into pre-sized buffers and playback starts immediately.
- Chart venue cues (`lighting (verse|chorus|flare_*|strobe_*|blackout_*)`, big rock endings) drive the stage lighting, strobes and blackouts. Gem reflections in the board, hit flashes sized by timing accuracy, beat-snapped pause resume, animated results with a miss timeline, a first-run welcome screen, and a render-scale option under Options → Video.
- Keyboard and guitar controllers (GameController framework, Xbox 360 GH layout by default; rebind under Options → Controls).
- Screens: main menu, song library (search, sort, folders, previews), career tiers, practice setup, gameplay HUD with lyrics, pause menu with a live Options overlay, results, options (gameplay, calibration with latency test, controls, audio, video).
- Settings persist as `settings.json`; the library (song cache, scores, career, play history) lives in `library.sqlite` (WAL mode, incremental writes). An existing `library.json` is imported once and kept as `library.json.bak`. Replays are JSON files under `replays/`. All under `~/Library/Application Support/GuitarCozy/`.

## Keyboard navigation

Every screen is fully usable without a mouse. Arrow keys move, Enter selects, Esc backs out, and **Tab** (Shift+Tab backwards) moves between panes or sections: the section list and the option rows in Options, the song list / sort / instrument / difficulty / speed / no-fail zones in the library, and sections / speed / loop in practice setup. `/` focuses the search box. The focused pane shows an ink outline; the footer of each screen lists its keys. Options → Library lists the linked song folders with Unlink and Add.

## Layout

- `src/core` — portable game code: chart/MIDI/song.ini/.sng parsers, tempo map, HOPO resolution, gameplay engine. No platform dependencies.
- `src/audio` — decoders, mixer, synthesized SFX.
- `src/render` — Metal renderer (`renderer.mm`, `shaders.metal`, `shader_types.h` shared with the shaders).
- `src/platform` — song folder/.sng loading, gamepad polling.
- `src/ui` — the AppKit "stage": a 1440×900 design-unit layout layer that scales uniformly to the window.
- `src/app` — app shell, settings, library, and one file per screen under `screens/`.
- `tests` — the same scenarios as the web build's vitest suite plus an .sng round trip.
- `assets/demo` — the built-in demo song; `assets/fonts` — Barlow Condensed (OFL).
