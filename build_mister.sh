#!/bin/bash
# build_mister.sh — Build MiSTer Music Player for MiSTer FPGA
set -e

echo "=== MiSTer Music Player Build ==="
echo ""

# ── 1. Install dependencies ─────────────────────────────────────
echo ">>> Installing build dependencies..."
apt-get update -qq
apt-get install -y -qq build-essential wget git libasound2-dev > /dev/null 2>&1

# ── 2. Build SDL 1.2.15 ─────────────────────────────────────────
SDL_PREFIX=/opt/sdl12
if [ ! -f "$SDL_PREFIX/lib/libSDL.a" ]; then
    echo ">>> Building SDL 1.2.15..."
    cd /tmp
    wget -q https://www.libsdl.org/release/SDL-1.2.15.tar.gz
    tar xzf SDL-1.2.15.tar.gz && cd SDL-1.2.15
    ./configure --prefix=$SDL_PREFIX \
        --disable-video-x11 --disable-video-opengl --disable-cdrom \
        --disable-shared --enable-static --disable-pulseaudio --disable-esd \
        --enable-alsa --enable-video-fbcon --quiet
    make -j$(nproc) > /dev/null 2>&1
    make install > /dev/null 2>&1
    echo "    SDL 1.2.15 → $SDL_PREFIX"
else
    echo "    SDL 1.2.15 already built."
fi

# ── 3. Clone GME if needed ───────────────────────────────────────
cd /work
if [ ! -d "game-music-emu" ]; then
    echo ">>> Cloning Game_Music_Emu..."
    git clone --depth 1 https://github.com/libgme/game-music-emu.git
fi

# ── 4. Build ─────────────────────────────────────────────────────
echo ">>> Building MiSTer Music Player..."
make clean 2>/dev/null || true
SDL_PREFIX=$SDL_PREFIX make -j$(nproc) 2>&1

# ── 5. Package release ───────────────────────────────────────────
echo ">>> Packaging release..."
RELEASE=release
rm -rf $RELEASE
mkdir -p $RELEASE/MiSTer-Music-Player
mkdir -p $RELEASE/Scripts
mkdir -p $RELEASE/Music

# Copy binary
cp MiSTer-Music-Player $RELEASE/MiSTer-Music-Player/

# Create launcher script
cat > $RELEASE/Scripts/music_player.sh << 'LAUNCHER'
#!/bin/bash
# MiSTer Music Player Launcher
APP_DIR=/media/fat/MiSTer-Music-Player
MUSIC_DIR=/media/fat/Music

# Create music dir if it doesn't exist
mkdir -p "$MUSIC_DIR"

# Set video mode for MiSTer HDMI scaler (build guide §3)
vmode -r 320 240 rgb16 > /dev/null 2>&1

# Hide cursor
echo -e '\033[?17;0;0c' > /dev/tty1 2>/dev/null || true

# Set environment
export SDL_VIDEODRIVER=fbcon
export SDL_FBDEV=/dev/fb0
export SDL_AUDIODRIVER=alsa
export AUDIODEV=hw:0,0

# Launch with both CPU cores (build guide §7)
taskset 03 "$APP_DIR/MiSTer-Music-Player" "$MUSIC_DIR" "$@"

# Restore cursor
echo -e '\033[?0c' > /dev/tty1 2>/dev/null || true
LAUNCHER
chmod +x $RELEASE/Scripts/music_player.sh

# Create install script
cat > $RELEASE/Scripts/Install_MiSTer-Music-Player.sh << 'INSTALL'
#!/bin/bash
echo "Installing MiSTer Music Player..."
APP_DIR=/media/fat/MiSTer-Music-Player
MUSIC_DIR=/media/fat/Music

mkdir -p "$APP_DIR"
mkdir -p "$MUSIC_DIR"

if [ -f "$APP_DIR/MiSTer-Music-Player" ]; then
    chmod +x "$APP_DIR/MiSTer-Music-Player"
    echo ""
    echo "Done! Launch: F12 → Scripts → music_player"
    echo ""
    echo "Place music files in /media/fat/Music/"
    echo "Supported: NSF, SPC, VGM, VGZ, GBS, HES, AY, SAP, KSS, GYM"
    echo ""
    echo "Controls:"
    echo "  D-pad Up/Down    = Browse files"
    echo "  D-pad Left/Right = Prev/Next track"
    echo "  A                = Select / Pause / Resume"
    echo "  B                = Go back a folder"
    echo "  Start            = Toggle loop"
else
    echo "ERROR: Copy MiSTer-Music-Player/ folder to /media/fat/ first."
fi
INSTALL
chmod +x $RELEASE/Scripts/Install_MiSTer-Music-Player.sh

# README
cat > $RELEASE/MiSTer-Music-Player/README.txt << 'README'
MiSTer Music Player
====================
Retro game music jukebox for MiSTer FPGA.

Plays music rips from classic consoles and computers:

  NSF / NSFe  — NES / Famicom (2A03, VRC6, VRC7, FDS, MMC5, Namco 163, FME-7)
  SPC         — SNES / Super Famicom (SPC700 + DSP)
  VGM / VGZ   — Genesis, Master System, Game Gear, arcade chips
  GBS         — Game Boy / Game Boy Color
  HES         — PC Engine / TurboGrafx-16
  AY          — ZX Spectrum / Amstrad CPC
  SAP         — Atari 8-bit (POKEY)
  KSS         — MSX
  GYM         — Genesis (older format)

SETUP:
  1. Copy MiSTer-Music-Player/ to /media/fat/
  2. Copy Scripts/*.sh to /media/fat/Scripts/
  3. Place music files in /media/fat/Music/
  4. Launch: F12 → Scripts → music_player

CONTROLS:
  D-pad Up/Down    = Browse files
  D-pad Left/Right = Previous / Next track
  A                = Select file / Pause / Resume
  B                = Go back a folder
  Start            = Toggle loop mode

WHERE TO GET MUSIC FILES:
  Zophar's Domain: https://www.zophar.net/music
  VGMRips: https://vgmrips.net/
  SNESMusic: https://www.snesmusic.org/
  HCS Forum: https://hcs64.com/

Powered by Game_Music_Emu by Blargg (GPL-3.0)
README

echo ""
echo "=== Build Complete ==="
ls -lh MiSTer-Music-Player 2>/dev/null
file MiSTer-Music-Player 2>/dev/null
