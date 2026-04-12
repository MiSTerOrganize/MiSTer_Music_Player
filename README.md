# MiSTer Music Player

A retro game music jukebox for **MiSTer FPGA**. Plays music rips from classic consoles and computers using Blargg's [Game_Music_Emu](https://github.com/libgme/game-music-emu) library.

## Supported Formats

| Format | System | Sound Chips |
|---|---|---|
| NSF / NSFe | NES / Famicom | 2A03, VRC6, VRC7, FDS, MMC5, Namco 163, FME-7 |
| SPC | SNES / Super Famicom | SPC700 + DSP |
| VGM / VGZ | Genesis, Master System, Game Gear, arcade | YM2612, SN76489, YM2413, YM2151, and more |
| GBS | Game Boy / Game Boy Color | DMG APU |
| HES | PC Engine / TurboGrafx-16 | HuC6280 |
| AY | ZX Spectrum / Amstrad CPC | AY-3-8910 |
| SAP | Atari 8-bit | POKEY |
| KSS | MSX | SN76489, AY-3-8910, SCC |
| GYM | Genesis | YM2612 + SN76489 |

## Features

- Waveform oscilloscope display
- File browser with directory navigation
- Multi-track support (NSF, GBS, etc. files with multiple songs)
- Track info display (game, song, system, time)
- Auto-advance to next track
- Loop mode toggle
- Full gamepad support

## Setup

1. Download from [Releases](../../releases)
2. Copy `MiSTer-Music-Player/` to `/media/fat/`
3. Copy `Scripts/*.sh` to `/media/fat/Scripts/`
4. Place your music files in `/media/fat/Music/`
5. Launch via **F12 → Scripts → music_player**

## Controls

| Input | Action |
|---|---|
| D-pad Up/Down | Browse files |
| D-pad Left/Right | Previous / Next track |
| A (Enter) | Select file / Play |
| X | Pause / Resume |
| Start | Toggle loop mode |
| Back / Guide | Quit |

## Where to Get Music Files

- [Zophar's Domain](https://www.zophar.net/music) — NSF, SPC, GBS, and more
- [VGMRips](https://vgmrips.net/) — VGM files for Genesis, Master System, arcade
- [SNESMusic](https://www.snesmusic.org/) — SPC files for SNES
- [Project2612](https://project2612.org/) — VGM files for Genesis
- [HCS Forum](https://hcs64.com/) — Various game music formats

## Building from Source

Push to `main` and GitHub Actions builds automatically, or build locally:

```bash
docker run --rm --platform linux/arm/v7 \
  -v $(pwd):/work -w /work \
  arm32v7/debian:bullseye-slim \
  bash build_mister.sh
```

### How It Works

- GME emulates the actual sound chips from each console in software
- Audio output via ALSA direct (dlopen, blocking snd_pcm_writei)
- Video via SDL 1.2 fbcon at 320x240 RGB565
- Audio thread on core 1, UI on core 0
- Follows all conventions from the [MiSTer FPGA Build Guide](docs/MiSTer-FPGA-Build-Guide.md)

## Credits

- **[Game_Music_Emu](https://github.com/libgme/game-music-emu)** by Blargg (Shay Green) — LGPL 2.1
- **MiSTer FPGA** by Sorgelig and community
- MiSTer adaptation by MiSTer Organize

## License

LGPL 2.1 (matching Game_Music_Emu)
