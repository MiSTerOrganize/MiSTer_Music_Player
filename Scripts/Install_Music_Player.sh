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
