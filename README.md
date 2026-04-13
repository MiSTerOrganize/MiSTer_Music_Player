# MiSTer_Music_Player

A retro game music jukebox for **MiSTer FPGA**, powered by [Game_Music_Emu](https://github.com/libgme/game-music-emu).

Plays music rips from classic consoles and computers with a waveform oscilloscope display, file browser, and full controller support.

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

## Installation

### Option A — Automatic (Recommended)

1. Copy `Scripts/Install_MiSTer-Music-Player.sh` to `/media/fat/Scripts/` on your MiSTer SD card
2. On MiSTer: **F12 → Scripts → Install_MiSTer-Music-Player**
3. The script downloads and installs everything automatically

### Option B — Manual

1. Download from [Releases](../../releases)
2. Copy `MiSTer-Music-Player/` to `/media/fat/`
3. Copy `Scripts/*.sh` to `/media/fat/Scripts/`
4. Place your music files in `/media/fat/Music/`

### Adding Music

Place your music rip files in `/media/fat/Music/`. You can organize them into subfolders by system or game:

```
/media/fat/Music/
├── NES/
│   ├── Mega Man 2.nsf
│   ├── Castlevania III.nsf
│   └── Kirby's Adventure.nsf
├── SNES/
│   ├── Chrono Trigger/
│   ├── Final Fantasy VI/
│   └── Super Metroid/
├── Genesis/
│   ├── Sonic the Hedgehog.vgm
│   └── Streets of Rage 2/
└── Game Boy/
    └── Pokemon Red.gbs
```

The file browser scans folders live — add or remove files anytime.

### Running

**F12 → Scripts → music_player**

## Controls

| Controller | Action |
|---|---|
| D-pad Up/Down | Browse files |
| D-pad Left/Right | Previous / Next track |
| A | Select file / Pause / Resume |
| B | Go back a folder |
| Start | Toggle loop mode |

## Features

- Waveform oscilloscope display
- File browser with directory navigation
- Multi-track support (NSF, GBS, etc. files contain multiple songs)
- Track info display (game, song, system, elapsed/total time)
- Auto-advance to next track
- Loop mode toggle
- Full gamepad support with analog stick and d-pad

## Where to Get Music Files

- [Zophar's Domain](https://www.zophar.net/music) — NSF, SPC, GBS, and more
- [VGMRips](https://vgmrips.net/) — VGM files for Genesis, Master System, arcade
- [SNESMusic](https://www.snesmusic.org/) — SPC files for SNES
- [Project2612](https://project2612.org/) — VGM files for Genesis
- [HCS Forum](https://hcs64.com/) — Various game music formats

## MiSTer SD Card Layout

```
/media/fat/
├── MiSTer-Music-Player/
│   └── MiSTer-Music-Player   ← player binary
├── Music/                     ← your music files
│   ├── NES/
│   ├── SNES/
│   └── ...
└── Scripts/
    ├── music_player.sh                    ← launcher
    └── Install_MiSTer-Music-Player.sh     ← installer
```

## Credits

- **[Game_Music_Emu](https://github.com/libgme/game-music-emu)** by Blargg (Shay Green) — audio emulation library
- **MiSTer FPGA Project** by Sorgelig and community
- MiSTer adaptation by MiSTer Organize

## License

[GNU General Public License v3.0](LICENSE)

## Contributing

Developers: see the source code and build scripts for build instructions and project structure.

## Support

Thank you to all my [Patreon](https://www.patreon.com/MiSTer_Organize) supporters for making projects like this possible. If you enjoy MiSTer_Music_Player and want to support future MiSTer projects, consider joining:

<p align="center">
  <a href="https://www.patreon.com/join/MiSTer_Organize">
    <img src="https://github.com/MiSTerOrganize/MiSTer_Music_Player/raw/main/assets/patreon_banner.png" alt="Support my work at Patreon" width="500">
  </a>
</p>
