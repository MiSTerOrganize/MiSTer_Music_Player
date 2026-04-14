# MiSTer Music Player

A retro game music player for **MiSTer FPGA** covering **27 systems** with dedicated per-system cores.

Each system gets its own music player RBF with FPGA-native audio output (I2S, SPDIF, analog DAC) — the same audio path used by the NES, SNES, Genesis, and every other MiSTer core. No Linux audio stack. Cleanest possible sound.

## 27 Systems Supported

### Console (16 cores)

| Core | System | Formats | Sound Chips |
|---|---|---|---|
| NES_Music_Player | NES / Famicom | NSF, NSFe | 2A03, VRC6, VRC7, FDS, MMC5, N163, FME-7 |
| SNES_Music_Player | SNES / Super Famicom | SPC | SPC700 + DSP |
| MegaDrive_Music_Player | Genesis / Mega Drive | VGM, VGZ, GYM | YM2612 + SN76489 |
| SMS_Music_Player | Master System | VGM, VGZ | SN76489 + YM2413 |
| GameGear_Music_Player | Game Gear | VGM, VGZ | SN76489 |
| S32X_Music_Player | Sega 32X | VGM, VGZ | YM2612 + SN76489 + PWM |
| Gameboy_Music_Player | Game Boy / GBC | GBS | DMG APU |
| TurboGrafx16_Music_Player | PC Engine / TG-16 | HES | HuC6280 |
| ColecoVision_Music_Player | ColecoVision | VGM, VGZ | SN76489 |
| SG-1000_Music_Player | SG-1000 | VGM, VGZ | SN76489 |
| Vectrex_Music_Player | Vectrex | AY | AY-3-8912 |
| PSX_Music_Player | PlayStation | PSF | SPU |
| Saturn_Music_Player | Sega Saturn | SSF | SCSP |
| N64_Music_Player | Nintendo 64 | USF | AI (RSP) |
| GBA_Music_Player | Game Boy Advance | GSF | Custom DMA PCM |
| WonderSwan_Music_Player | WonderSwan / WSC | WSR | 4-ch wavetable |

### Computer (11 cores)

| Core | System | Formats | Sound Chips |
|---|---|---|---|
| C64_Music_Player | Commodore 64 / 128 | SID | MOS 6581 / 8580 |
| Amiga_Music_Player | Amiga | MOD, S3M, XM, IT | Paula |
| AtariST_Music_Player | Atari ST / STe | SNDH, SC68 | YM2149 + DMA |
| Atari800_Music_Player | Atari 800 / XL / XE | SAP | POKEY |
| ZX-Spectrum_Music_Player | ZX Spectrum | AY | AY-3-8910 |
| Amstrad_Music_Player | Amstrad CPC | AY | AY-3-8910 |
| MSX_Music_Player | MSX | KSS | AY-3-8910 + SCC |
| BBCMicro_Music_Player | BBC Micro | VGM, VGZ | SN76489 |
| ao486_Music_Player | PC (AdLib / Sound Blaster) | DRO, IMF, CMF | OPL2 / OPL3 |
| PC-98_Music_Player | NEC PC-9801 | S98 | YM2203 / YM2608 |
| X68000_Music_Player | Sharp X68000 | MDX | YM2151 + MSM6258 |

## Installation

### Quick Install (on MiSTer)

1. Copy `Install_Music_Player.sh` to `/media/fat/Scripts/` on your MiSTer SD card
2. Run it from MiSTer menu → Scripts → Install_Music_Player
3. It downloads the ARM binary and sets permissions automatically
4. Copy the 27 RBF files to the correct folders (see SD Card Layout below)
5. Add music files to `/media/fat/games/Music_Player/`

### Manual Install

1. Copy the `Music_Player` binary to `/media/fat/games/Music_Player/`
2. Copy console RBFs to `/media/fat/_Multimedia/_Music/_Console/`
3. Copy computer RBFs to `/media/fat/_Multimedia/_Music/_Computer/`
4. Place music files in subfolders of `/media/fat/games/Music_Player/`

## SD Card Layout

```
/media/fat/
├── _Multimedia/
│   └── _Music/
│       ├── _Console/
│       │   ├── NES_Music_Player.rbf
│       │   ├── SNES_Music_Player.rbf
│       │   ├── MegaDrive_Music_Player.rbf
│       │   └── ... (16 console cores)
│       └── _Computer/
│           ├── C64_Music_Player.rbf
│           ├── Amiga_Music_Player.rbf
│           └── ... (11 computer cores)
├── games/
│   └── Music_Player/
│       ├── Music_Player             ← ARM binary (one for all cores)
│       ├── NES/
│       │   ├── Mega Man 2.nsf
│       │   └── Castlevania III.nsf
│       ├── SNES/
│       │   ├── Chrono Trigger.spc
│       │   └── Final Fantasy VI.spc
│       ├── Genesis/
│       │   └── Sonic the Hedgehog.vgm
│       ├── C64/
│       │   └── Commando.sid
│       └── ...
└── Scripts/
    └── Install_Music_Player.sh      ← auto-installer
```

## Controls

| Button | Action |
|---|---|
| D-pad Left / Right | Previous / Next track |
| A | Play / Pause |
| Start | Toggle loop mode |
| Back / Guide | Quit |

## Architecture

Hybrid FPGA+ARM design. The FPGA handles all video and audio output. The ARM CPU runs the sound chip emulation libraries and writes data to DDR3.

**Audio path:** ARM (48KHz PCM) → DDR3 ring buffer → FPGA reads at 48KHz → AUDIO_L/AUDIO_R → I2S + SPDIF + analog DAC. Same audio path as the NES, SNES, Genesis, and every other MiSTer core. No ALSA. No Linux audio stack.

**Video path:** ARM writes metadata (title, artist, system, timing) + waveform samples to DDR3. FPGA renders text via built-in font ROM and draws waveform oscilloscope. No framebuffer needed — 1.5KB per frame instead of 150KB.

All 27 RBFs share identical FPGA logic. Only the CONF_STR (core name and file extension filter) differs per RBF. One ARM binary handles all formats.

## Implementation Phases

| Phase | Library | Formats | Status |
|---|---|---|---|
| 1 | Game_Music_Emu | NSF, SPC, VGM, VGZ, GBS, HES, AY, SAP, KSS, GYM | Built |
| 2 | libsidplayfp | SID | Planned |
| 3 | libopenmpt | MOD, S3M, XM, IT | Planned |
| 4 | sc68 | SNDH, SC68 | Planned |
| 5 | Highly Experimental | PSF, SSF | Planned |
| 6 | lazyusf2 | USF | Planned |
| 7 | lazygsf | GSF | Planned |
| 8 | adplug | DRO, IMF, CMF | Planned |
| 9 | libs98 | S98 | Planned |
| 10 | mdxmini | MDX | Planned |
| 11 | in_wsr | WSR | Planned |

## Where to Get Music Files

- [Zophar's Domain](https://www.zophar.net/music) — all formats, 19,000+ games
- [VGMRips](https://vgmrips.net/) — VGM files for Sega, arcade, and more
- [SNESMusic](https://www.snesmusic.org/) — SPC files for SNES
- [High Voltage SID Collection](https://hvsc.c64.org/) — 50,000+ SID files
- [The Mod Archive](https://modarchive.org/) — MOD, S3M, XM, IT tracker files
- [SNDH Archive](http://sndh.atari.org/) — 7,000+ Atari ST music files
- [Project2612](https://project2612.org/) — Genesis VGM files
- [ASMA](https://asma.atari.org/) — 6,000+ Atari 8-bit SAP files

## Building

### ARM Binary (via GitHub Actions)

Push to GitHub and CI builds automatically. Or build locally:

```bash
# Requires Docker with QEMU ARM support
docker run --rm --platform linux/arm/v7 \
    -v $(pwd):/work -w /work \
    arm32v7/debian:bullseye-slim \
    bash build_mister.sh
```

### FPGA RBFs (via Quartus)

Windows — double-click `fpga/build_all_rbfs.bat` to build all 27 RBFs.

Linux/Mac:
```bash
cd fpga && ./build_all_rbfs.sh
```

Requires Intel Quartus Prime (Lite edition, 17.0+).

## Credits

- **[Game_Music_Emu](https://github.com/libgme/game-music-emu)** by Blargg — audio emulation
- **MiSTer FPGA Project** by Sorgelig and community
- MiSTer adaptation by **MiSTer Organize**

## License

[GNU General Public License v3.0](LICENSE)

## Support

<p align="center">
  <a href="https://www.patreon.com/join/MiSTer_Organize">
    <img src="https://github.com/MiSTerOrganize/MiSTer_Music_Player/raw/main/assets/patreon_banner.png" alt="Support MiSTer Organize on Patreon" width="500">
  </a>
</p>
