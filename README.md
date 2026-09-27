# OpenReliant

OpenReliant is an open-source, faithful engine reimplementation of **StarLancer**, the space combat simulator developed by Warthog and Digital Anvil and published by Microsoft in 2000.

Written in **Zig** and built on **SDL3**, OpenReliant renders with Vulkan (Metal on macOS) via SDL's GPU API. It runs natively on Linux, macOS, and Windows using assets directly from your retail copy of the game.

<p align="center">
  <img src="docs/images/predator-wireframe.svg" width="560"
       alt="Wireframe of the Predator light fighter exported from its .SHP model">
</p>

---

## Legal & Asset Policy

OpenReliant is an independent, non-commercial open-source project. It is not affiliated with, endorsed by, or associated with Warthog Games, Digital Anvil, or Microsoft. StarLancer is a trademark of its respective owner.

**This repository contains no copyrighted game assets**: no textures, 3D models, sound effects, music, cinematics, mission scripts, or game binaries. OpenReliant requires assets extracted from a legally owned copy of StarLancer to run. We do not support or condone software piracy.

---

## Current Status

OpenReliant is in active development: the campaign's first mission is fully playable, while the front end and the rest of the campaign are still to come. Mission 1 plays from start to finish as the original plays it: you launch from the Reliant, meet the convoy and fight off the Coalition's ambush, then land back aboard. The mission's script runs its triggers and orders, and its objectives show on the display. The pilots speak on the radio with their faces, the music follows the fight, and your wingmen answer the radio menu and the F keys. The sandbox, mission 0, is built through the same mission code and remains for testing.

- **Flight & Combat**: Fly any ship from the game using mouse/keyboard, flight sticks, HOTAS, or gamepads, with the authentic flight model, throttle, afterburners, and 8 camera modes (including 3D cockpits).
- **AI**: Coalition fighters fight with the original's maneuvers, capital ships' turrets track and fire, and wingmen take your orders.
- **Weapons & Damage**: Guns, missiles and torpedoes fire from ship stats and the power grid. Shields, armor and components wear down, and ships break up in explosions, debris and shockwaves.
- **Missions**: Every mission file, the game's own or a custom one, loads as the original loads it, and the script commands mission 1 uses run as the original runs them. The later missions' remaining commands are in progress.
- **HUD & Cockpit Displays**: The targeting reticle, radar, status indicators, the objectives, wing status, gunnery, damage and power windows, and the radio's face and menu all work.
- **Positional 3D Audio**: Sound effects, engine audio, directional flybys, speech and music are mixed with 3D spatial positioning, environmental reverb, and headphone HRTF support.
- **In Development**: The front end (menus, briefings, loadout), the rest of the campaign's missions, and multiplayer. See the [milestones](../../milestones) for the development roadmap.

---

## Documentation

The project documentation is organized into two distinct sections:

- [**User Guide**](docs/guide/README.md):
  - [Installation & Quickstart](docs/guide/installation.md): Requirements and installing from retail CDs or disc images.
  - [Controllers & Input](docs/guide/controllers.md): Setting up flight sticks, HOTAS hardware, gamepads, and button bindings.
  - [Configuration & Options](docs/guide/configuration.md): Command-line switches, graphics settings, audio modes, and `starlancer.ini`.
- [**Developer & Technical Documentation**](docs/README.md):
  - [Engine Architecture](docs/README.md#engine-architecture--subsystems): Runtime subsystems, physics, rendering pipeline, sound, and scripting VM.
  - [Asset & File Formats](docs/README.md#file--asset-formats): Specifications for `.SHP` models, `.HOG` archives, textures, and mission formats.
  - [Binary Reverse Engineering](docs/README.md#binary-reverse-engineering): Analysis of the retail binaries, C runtime, and decompilation.
  - [Toolchain & Setup](docs/toolchain.md): Build instructions, Ghidra disassembly setup, and the `sltool` command-line utility.

---

## Quickstart

### 1. Download OpenReliant
Download the pre-compiled archive for your platform from the [latest release](../../releases/latest) and extract it.

*(macOS users: run `xattr -d com.apple.quarantine openreliant` to clear the gatekeeper quarantine flag).*

### 2. Install Game Files
Insert StarLancer Disc 1 into your CD drive (or prepare `.bin`/`.iso` images) and run the built-in installer:

```bash
# Physical CD-ROM
./openreliant install StarLancer

# Or from disc image files
./openreliant install --from "StarLancer Disc 1.bin" --from "StarLancer Disc 2.bin" StarLancer
```

*(On Windows, use `.\openreliant.exe`.)*

### 3. Launch
Start the campaign's first mission:

```bash
./openreliant StarLancer --mission 1
```

Or the sandbox, mission 0, where you can fly any ship against Coalition wings:

```bash
./openreliant StarLancer
```

The game starts in the pause menu: choose **Continue** (or press **Escape**) to start flying. Number keys **1-8** change camera views, and **C** opens the radio menu, whose number keys call your wingmen and the base. In the sandbox, **F2** / **F3** restart it in another ship and **F4** brings in another enemy wing.

For complete setup instructions, see the [Installation Guide](docs/guide/installation.md).

---

## Building from Source

Building OpenReliant requires [Zig 0.16](https://ziglang.org). Dependencies (SDL3, OpenAL Soft, libarchive) are fetched and built automatically:

```bash
# Build optimized release binary
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Install and play mission 1
zig-out/bin/openreliant install StarLancer
zig-out/bin/openreliant StarLancer --mission 1
```

---

## Reverse Engineering & Analysis Tools

The repository includes tools used during reverse engineering:

```bash
make setup     # Download JDK and Ghidra, and build native decompilers
make build     # Compile development tools into zig-out/bin
make test      # Run unit test suite
make doctor    # Verify installed prerequisites
```

The `sltool` utility inspects and exports game formats:

| Command | Description | Documentation |
|---|---|---|
| `sltool cd` | Inspect CD images and ISO 9660 filesystems | [disc-images](docs/formats/disc-images.md) |
| `sltool hog` | Extract `.HOG` archives (`BIGF` container / RefPack) | [hog](docs/formats/hog.md), [refpack](docs/formats/refpack.md) |
| `sltool shp` | Inspect `.SHP` 3D models; export Wavefront OBJ | [shp](docs/formats/shp.md) |
| `sltool spr` | Inspect `.SPR` 2D interface sprites; export PNG | [spr](docs/formats/spr.md) |
| `sltool tcache` | Extract texture caches to PNG | [tcache](docs/formats/tcache.md) |
| `sltool fat` | Extract `.fat` sound banks to WAV | [fat](docs/formats/fat.md) |
| `sltool fnt` | Render `.fnt` bitmap fonts into glyph atlases | [fnt](docs/formats/fnt.md) |
| `sltool dte` | Disassemble `.DTE` mission bytecode | [dte](docs/formats/dte.md) |
| `sltool stats` | Parse ship, weapon, and pilot stat tables | [stats](docs/formats/stats.md) |
| `sltool render` | Render 3D ship models with the software reference renderer | [renderer](docs/port/renderer.md) |

---

## Repository Layout

| Directory | Contents |
|---|---|
| `src/openreliant/` | Main application entry point, CLI parser, and installer. |
| `src/engine/` | Reimplemented engine modules mirroring original source layout. |
| `src/platform/` | Platform abstraction layer: SDL3, Vulkan/Metal GPU backend, audio, and inputs. |
| `src/formats/` | Parsers and decoders for StarLancer file formats. |
| `src/tools/sltool/` | Command-line asset inspection and extraction tool. |
| `src/tools/tablegen/` | Generates static engine lookup tables from the original executable. |
| `docs/` | Documentation (see [docs/README.md](docs/README.md)). |
| `ghidra/` | Ghidra scripts, symbol annotations, and type maps. |

---

## License

Copyright 2026 the OpenReliant contributors.

- Source code is licensed under the [Mozilla Public License 2.0](LICENSE).
- Documentation under `docs/` is licensed under [Creative Commons Attribution-ShareAlike 4.0](docs/LICENSE).
- Statically linked libraries: [OpenAL Soft](https://github.com/kcat/openal-soft) is licensed under the GNU LGPL 2.1.
