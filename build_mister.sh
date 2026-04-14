#!/bin/bash
# build_mister.sh — Build MiSTer Music Player ARM binary
# Runs inside arm32v7/debian:bullseye-slim Docker container via QEMU
set -e

echo "=== MiSTer Music Player Build ==="
echo "    27 systems, 1 binary, FPGA audio"
echo ""

# ── 1. Install dependencies ─────────────────────────────────────
echo ">>> Installing build dependencies..."
apt-get update -qq
apt-get install -y -qq build-essential wget git > /dev/null 2>&1
# Note: No libasound2-dev — we don't use ALSA. Audio goes through FPGA.

# ── 2. Build SDL 1.2.15 ─────────────────────────────────────────
SDL_PREFIX=/opt/sdl12
if [ ! -f "$SDL_PREFIX/lib/libSDL.a" ]; then
    echo ">>> Building SDL 1.2.15 (static, dummy video + joystick)..."
    cd /tmp
    wget -q https://www.libsdl.org/release/SDL-1.2.15.tar.gz
    tar xzf SDL-1.2.15.tar.gz && cd SDL-1.2.15
    ./configure --prefix=$SDL_PREFIX \
        --disable-video-x11 --disable-video-opengl --disable-cdrom \
        --disable-shared --enable-static \
        --disable-pulseaudio --disable-esd --disable-alsa \
        --disable-video-fbcon \
        --enable-video-dummy \
        --quiet
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
echo ">>> Building Music_Player ARM binary..."
make clean 2>/dev/null || true
SDL_PREFIX=$SDL_PREFIX make -j$(nproc) 2>&1

echo ""
ls -lh Music_Player 2>/dev/null

# ── 5. Package release ───────────────────────────────────────────
echo ""
echo ">>> Packaging release..."
RELEASE=release
rm -rf $RELEASE

# Create SD card directory structure
mkdir -p $RELEASE/games/Music_Player

# Copy binary
cp Music_Player $RELEASE/games/Music_Player/
chmod +x $RELEASE/games/Music_Player/Music_Player

# Create install script (wget-based for MiSTer)
cat > $RELEASE/Install_Music_Player.sh << 'INSTALL_EOF'
#!/bin/bash
# MiSTer Music Player — Install Script
# Run on MiSTer via SSH or Scripts menu
#
# Downloads and installs the ARM binary.
# RBFs must be placed manually in _Multimedia/_Music/ folders.

echo ""
echo "=== MiSTer Music Player Installer ==="
echo "    27 systems — FPGA audio — one binary"
echo ""

BASE_URL="https://github.com/MiSTerOrganize/MiSTer_Music_Player/releases/latest/download"
GAME_DIR="/media/fat/games/Music_Player"
MUSIC_CON="/media/fat/_Multimedia/_Music/_Console"
MUSIC_COM="/media/fat/_Multimedia/_Music/_Computer"

# Create directories
echo ">>> Creating directories..."
mkdir -p "$GAME_DIR"
mkdir -p "$MUSIC_CON"
mkdir -p "$MUSIC_COM"

# Download ARM binary
echo ">>> Downloading Music_Player binary..."
cd "$GAME_DIR"
if wget -q --no-check-certificate "$BASE_URL/Music_Player" -O Music_Player.tmp; then
    mv Music_Player.tmp Music_Player
    chmod +x Music_Player
    echo "    Binary installed: $GAME_DIR/Music_Player"
else
    echo "    ERROR: Download failed."
    echo "    You can manually copy Music_Player to $GAME_DIR/"
    rm -f Music_Player.tmp
fi

# Verify
if [ -x "$GAME_DIR/Music_Player" ]; then
    echo ""
    echo "=== Installation Complete ==="
    echo ""
    echo "ARM binary: $GAME_DIR/Music_Player"
    echo ""
    echo "Next steps:"
    echo "  1. Copy RBF files to:"
    echo "     $MUSIC_CON/"
    echo "     $MUSIC_COM/"
    echo ""
    echo "  2. Place music files in subfolders of:"
    echo "     $GAME_DIR/"
    echo "     Example: $GAME_DIR/NES/Mega Man 2.nsf"
    echo ""
    echo "  3. In MiSTer menu, navigate to:"
    echo "     _Multimedia > _Music > _Console or _Computer"
    echo "     Select a music player core and load a file."
    echo ""
    echo "Controls:"
    echo "  D-pad Left/Right  = Prev/Next track"
    echo "  A                 = Play / Pause"
    echo "  Start             = Toggle loop"
    echo ""
else
    echo ""
    echo "=== Installation Failed ==="
    echo "Binary not found or not executable."
    echo "Try manually copying Music_Player to $GAME_DIR/"
fi
INSTALL_EOF

# Put install script in Scripts folder for MiSTer menu access
mkdir -p $RELEASE/Scripts
mv $RELEASE/Install_Music_Player.sh $RELEASE/Scripts/
chmod +x $RELEASE/Scripts/Install_Music_Player.sh

echo ""
echo "=== Build Complete ==="
echo ""
echo "Release contents:"
find $RELEASE -type f | sort
echo ""
echo "To install on MiSTer:"
echo "  1. Copy games/Music_Player/ to /media/fat/games/"
echo "  2. Copy RBFs to /media/fat/_Multimedia/_Music/_Console/ and _Computer/"
echo "  3. Or run Install_Music_Player.sh on MiSTer"
