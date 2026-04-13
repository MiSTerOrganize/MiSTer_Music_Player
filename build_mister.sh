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
mkdir -p $RELEASE/games/Music_Player/Music
mkdir -p $RELEASE/Scripts

# Copy binary
cp Music_Player $RELEASE/games/Music_Player/

# Create install script
cat > $RELEASE/Scripts/Install_Music_Player.sh << 'INSTALL'
#!/bin/bash
echo "Installing MiSTer Music Player..."
GAME_DIR=/media/fat/games/Music_Player

mkdir -p "$GAME_DIR/Music"

if [ -f "$GAME_DIR/Music_Player" ]; then
    chmod +x "$GAME_DIR/Music_Player"
    echo ""
    echo "Done! Select Music Player from the MiSTer main menu."
    echo ""
    echo "Place music files in /media/fat/games/Music_Player/Music/"
    echo "Supported: NSF, SPC, VGM, VGZ, GBS, HES, AY, SAP, KSS, GYM"
    echo ""
    echo "Controls:"
    echo "  D-pad Up/Down    = Browse tracks"
    echo "  D-pad Left/Right = Prev/Next track"
    echo "  A                = Pause / Resume"
    echo "  Start            = Toggle loop"
else
    echo "ERROR: Copy games/Music_Player/ folder to /media/fat/games/ first."
fi
INSTALL
chmod +x $RELEASE/Scripts/Install_Music_Player.sh

echo ""
echo "=== Build Complete ==="
ls -lh Music_Player 2>/dev/null
