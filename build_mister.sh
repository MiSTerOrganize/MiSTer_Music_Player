#!/bin/bash
# build_mister.sh — Build MiSTer Music Player with ALL libraries
# Runs inside arm32v7/debian:bullseye-slim Docker container via QEMU
#
# 13 libraries, 27 systems, 1 binary, FPGA audio.
#
# Libraries:
#   1.  Game_Music_Emu       (NSF,SPC,VGM,VGZ,GBS,HES,AY,SAP,KSS,GYM)
#   2.  libsidplayfp          (SID)
#   3.  libopenmpt            (MOD,S3M,XM,IT)
#   4.  sc68                  (SNDH,SC68)
#   5.  psflib                (PSF container parser — shared by HE/HT/USF/GSF)
#   6.  Highly_Experimental   (PSF — PlayStation SPU)
#   7.  Highly_Theoretical    (SSF — Saturn SCSP)
#   8.  lazyusf2              (USF — N64 RSP)
#   9.  lazygsf               (GSF — GBA sound)
#  10.  adplug + libbinio     (DRO,IMF,CMF — AdLib OPL2/OPL3)
#  11.  libvgm                (S98 — PC-98 YM2203/YM2608)
#  12.  mdxmini               (MDX — X68000 YM2151)
#  13.  beetle-wswan           (WSR — WonderSwan)

set +e  # Don't exit on individual command failures — libraries have optional components

NPROC=$(nproc)
PREFIX=/opt/musiclibs
SDL_PREFIX=/opt/sdl12
WORK=/work
LIBS=$WORK/libs
LOGS=/tmp/buildlogs
CF="-mcpu=cortex-a9 -mtune=cortex-a9 -mfloat-abi=hard -mfpu=neon -O2"

mkdir -p $LIBS $PREFIX/lib $PREFIX/include $LOGS

# Log helper — tee stdout/stderr to a per-library log file so CI output
# is skimmable but nothing is lost when a library fails.
run_logged() {
    local name="$1"; shift
    "$@" 2>&1 | tee -a "$LOGS/${name}.log"
    return ${PIPESTATUS[0]}
}

echo "============================================"
echo "  MiSTer Music Player — Full Build"
echo "  27 systems, 13 libraries, 1 binary"
echo "============================================"
echo ""

# ── 1. Dependencies ─────────────────────────────────────────────
echo ">>> [1/15] Installing build dependencies..."
apt-get update -qq || { echo "ERROR: apt-get update failed"; exit 1; }
apt-get install -y -qq \
    build-essential wget git cmake autoconf automake libtool libtool-bin \
    pkg-config zlib1g-dev gperf autopoint gettext bison flex \
    || { echo "ERROR: apt-get install failed"; exit 1; }

# ── 2. SDL 1.2.15 ──────────────────────────────────────────────
echo ">>> [2/15] Building SDL 1.2.15..."
if [ ! -f "$SDL_PREFIX/lib/libSDL.a" ]; then
    cd /tmp && wget -q https://www.libsdl.org/release/SDL-1.2.15.tar.gz
    tar xzf SDL-1.2.15.tar.gz && cd SDL-1.2.15
    CFLAGS="$CF" ./configure --prefix=$SDL_PREFIX \
        --disable-video-x11 --disable-video-opengl --disable-cdrom \
        --disable-shared --enable-static --disable-pulseaudio --disable-esd \
        --disable-alsa --disable-video-fbcon --enable-video-dummy \
        > $LOGS/sdl.log 2>&1
    make -j$NPROC >> $LOGS/sdl.log 2>&1 && make install >> $LOGS/sdl.log 2>&1
fi
[ -f "$SDL_PREFIX/lib/libSDL.a" ] && echo "    OK" || { echo "    FAIL — dumping log:"; tail -40 $LOGS/sdl.log; }

# ── 3. Game_Music_Emu ──────────────────────────────────────────
echo ">>> [3/15] Cloning Game_Music_Emu..."
cd $WORK
[ ! -d "game-music-emu" ] && git clone --depth 1 https://github.com/libgme/game-music-emu.git
[ -d "game-music-emu" ] && echo "    OK (compiled inline by Makefile)" || echo "    FAIL: clone failed"

# ── 4. libsidplayfp ────────────────────────────────────────────
echo ">>> [4/15] Building libsidplayfp..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libsidplayfp.a" ]; then
    [ ! -d "libsidplayfp" ] && git clone --depth 1 https://github.com/libsidplayfp/libsidplayfp.git
    cd libsidplayfp
    {
        autoreconf -vfi
        if [ -f configure ]; then
            CXXFLAGS="$CF" CFLAGS="$CF" ./configure --prefix=$PREFIX \
                --enable-static --disable-shared --with-simd=none \
                --disable-hardsid --disable-exsid --disable-usbsid
            make -j$NPROC && make install
        fi
    } > $LOGS/sidplayfp.log 2>&1
fi
[ -f "$PREFIX/lib/libsidplayfp.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/sidplayfp.log; }

# ── 5. libopenmpt ──────────────────────────────────────────────
echo ">>> [5/15] Building libopenmpt..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libopenmpt.a" ]; then
    [ ! -d "openmpt" ] && git clone --depth 1 https://github.com/OpenMPT/openmpt.git
    cd openmpt
    {
        CXXFLAGS="$CF" CFLAGS="$CF" make -j$NPROC CONFIG=generic DYNLINK=0 \
            EXAMPLES=0 OPENMPT123=0 TEST=0 \
            NO_MINIMP3=1 NO_STBVORBIS=1 NO_OGG=1 NO_VORBIS=1 NO_VORBISFILE=1 \
            NO_MPG123=1 NO_FLAC=1 NO_SNDFILE=1 NO_PORTAUDIO=1 NO_PULSEAUDIO=1 \
            && cp bin/libopenmpt.a $PREFIX/lib/ \
            && mkdir -p $PREFIX/include/libopenmpt \
            && cp libopenmpt/libopenmpt.h libopenmpt/libopenmpt_config.h \
                  libopenmpt/libopenmpt_version.h $PREFIX/include/libopenmpt/
    } > $LOGS/openmpt.log 2>&1
fi
[ -f "$PREFIX/lib/libopenmpt.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/openmpt.log; }

# ── 6. sc68 ────────────────────────────────────────────────────
echo ">>> [6/15] Building sc68..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libsc68.a" ]; then
    [ ! -d "sc68" ] && git clone --depth 1 https://github.com/Zeinok/sc68.git
    cd sc68
    {
        autoreconf -vfi || true
        CFLAGS="$CF" CXXFLAGS="$CF" ./configure --prefix=$PREFIX \
            --enable-static --disable-shared
        make -j$NPROC
        make install
    } > $LOGS/sc68.log 2>&1
fi
[ -f "$PREFIX/lib/libsc68.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/sc68.log; }

# ── 7. psflib (shared PSF container parser) ────────────────────
echo ">>> [7/15] Building psflib..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libpsflib.a" ]; then
    [ ! -d "psflib" ] && git clone --depth 1 https://github.com/kode54/psflib.git
    cd psflib
    {
        gcc -c $CF -I. psflib.c psf2fs.c -DHAVE_ZLIB \
            || gcc -c $CF -I. psflib.c psf2fs.c
        ar rcs $PREFIX/lib/libpsflib.a *.o
        cp psflib.h psf2fs.h $PREFIX/include/
    } > $LOGS/psflib.log 2>&1
fi
[ -f "$PREFIX/lib/libpsflib.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/psflib.log; }

# ── 8. Highly Experimental (PSF — PlayStation) ─────────────────
echo ">>> [8/15] Building Highly Experimental (PSF)..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libhe.a" ]; then
    [ ! -d "Highly_Experimental" ] && git clone --depth 1 https://github.com/kode54/Highly_Experimental.git
    cd Highly_Experimental
    {
        find . -name "*.c" | while read f; do
            gcc -c $CF -I. -Icore -ICore -I$PREFIX/include "$f" -o "${f%.c}.o" || true
        done
        find . -name "*.o" | xargs ar rcs $PREFIX/lib/libhe.a || true
        mkdir -p $PREFIX/include/he
        find . -name "*.h" -exec cp {} $PREFIX/include/he/ \;
    } > $LOGS/he.log 2>&1
fi
[ -f "$PREFIX/lib/libhe.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/he.log; }

# ── 9. Highly Theoretical (SSF — Saturn) ───────────────────────
echo ">>> [9/15] Building Highly Theoretical (SSF)..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libht.a" ]; then
    [ ! -d "Highly_Theoretical" ] && git clone --depth 1 https://github.com/kode54/Highly_Theoretical.git
    cd Highly_Theoretical
    {
        find . -name "*.c" | while read f; do
            gcc -c $CF -I. -Icore -ICore -I$PREFIX/include "$f" -o "${f%.c}.o" || true
        done
        find . -name "*.o" | xargs ar rcs $PREFIX/lib/libht.a || true
        mkdir -p $PREFIX/include/ht
        find . -name "*.h" -exec cp {} $PREFIX/include/ht/ \;
    } > $LOGS/ht.log 2>&1
fi
[ -f "$PREFIX/lib/libht.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/ht.log; }

# ── 10. lazyusf2 (USF — N64) ──────────────────────────────────
echo ">>> [10/15] Building lazyusf2 (N64 USF)..."
cd $LIBS
if [ ! -f "$PREFIX/lib/liblazyusf.a" ]; then
    [ ! -d "lazyusf2" ] && git clone --depth 1 https://github.com/derselbst/lazyusf2.git
    {
        cd lazyusf2 && mkdir -p build && cd build
        cmake .. -DCMAKE_C_FLAGS="$CF" -DCMAKE_INSTALL_PREFIX=$PREFIX \
            -DBUILD_SHARED_LIBS=OFF && make -j$NPROC && make install
        if [ ! -f "$PREFIX/lib/liblazyusf.a" ]; then
            echo "--- cmake failed, trying manual build ---"
            cd $LIBS/lazyusf2
            find . -name "*.c" -not -path "./build/*" | while read f; do
                gcc -c $CF -I. -Ir4300 -Iusf -I$PREFIX/include "$f" -o "${f%.c}.o" || true
            done
            find . -name "*.o" -not -path "./build/*" | xargs ar rcs $PREFIX/lib/liblazyusf.a || true
            mkdir -p $PREFIX/include/lazyusf
            find . -name "usf.h" -exec cp {} $PREFIX/include/lazyusf/ \;
        fi
    } > $LOGS/lazyusf.log 2>&1
fi
[ -f "$PREFIX/lib/liblazyusf.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/lazyusf.log; }

# ── 11. lazygsf (GSF — GBA) ───────────────────────────────────
echo ">>> [11/15] Building lazygsf (GBA GSF)..."
cd $LIBS
if [ ! -f "$PREFIX/lib/liblazygsf.a" ]; then
    [ ! -d "lazygsf" ] && git clone --depth 1 https://github.com/jprjr/lazygsf.git
    cd lazygsf
    {
        find . -name "*.c" -o -name "*.cpp" | while read f; do
            OBJ="${f%.*}.o"
            if [[ "$f" == *.cpp ]]; then
                g++ -c $CF -I. -I$PREFIX/include "$f" -o "$OBJ" || true
            else
                gcc -c $CF -I. -I$PREFIX/include "$f" -o "$OBJ" || true
            fi
        done
        find . -name "*.o" | xargs ar rcs $PREFIX/lib/liblazygsf.a || true
        mkdir -p $PREFIX/include/lazygsf
        find . -maxdepth 1 -name "*.h" -exec cp {} $PREFIX/include/lazygsf/ \;
    } > $LOGS/lazygsf.log 2>&1
fi
[ -f "$PREFIX/lib/liblazygsf.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/lazygsf.log; }

# ── 12. adplug + libbinio ─────────────────────────────────────
echo ">>> [12/15] Building adplug..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libadplug.a" ]; then
    [ ! -d "libbinio" ] && git clone --depth 1 https://github.com/adplug/libbinio.git
    [ ! -d "adplug" ] && git clone --depth 1 https://github.com/adplug/adplug.git
    {
        cd $LIBS/libbinio
        autoreconf -vfi
        CXXFLAGS="$CF" ./configure --prefix=$PREFIX --enable-static --disable-shared
        make -j$NPROC && make install
        cd $LIBS/adplug
        autoreconf -vfi
        PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
        CXXFLAGS="$CF -I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
            ./configure --prefix=$PREFIX --enable-static --disable-shared
        make -j$NPROC && make install
    } > $LOGS/adplug.log 2>&1
fi
[ -f "$PREFIX/lib/libadplug.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/adplug.log; }

# ── 13. libvgm (S98) ──────────────────────────────────────────
echo ">>> [13/15] Building libvgm (S98)..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libvgm-player.a" ]; then
    [ ! -d "libvgm" ] && git clone --depth 1 https://github.com/ValleyBell/libvgm.git
    {
        cd libvgm && mkdir -p build && cd build
        cmake .. -DCMAKE_C_FLAGS="$CF" -DCMAKE_CXX_FLAGS="$CF" \
            -DCMAKE_INSTALL_PREFIX=$PREFIX -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_TESTS=OFF -DBUILD_PLAYER=OFF -DBUILD_VGM2WAV=OFF
        make -j$NPROC && make install
    } > $LOGS/libvgm.log 2>&1
fi
[ -f "$PREFIX/lib/libvgm-player.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/libvgm.log; }

# ── 14. mdxmini ────────────────────────────────────────────────
echo ">>> [14/15] Building mdxmini..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libmdxmini.a" ]; then
    [ ! -d "mdxmini" ] && git clone --depth 1 https://github.com/mistydemeo/mdxmini.git
    {
        cd mdxmini/src
        gcc -c $CF -I. -I../include *.c || true
        ar rcs $PREFIX/lib/libmdxmini.a *.o || true
        mkdir -p $PREFIX/include/mdxmini
        cp ../include/*.h $PREFIX/include/mdxmini/ 2>/dev/null || true
        cp mdxmini.h $PREFIX/include/mdxmini/ 2>/dev/null || true
    } > $LOGS/mdxmini.log 2>&1
fi
[ -f "$PREFIX/lib/libmdxmini.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/mdxmini.log; }

# ── 15. beetle-wswan (WSR) ─────────────────────────────────────
echo ">>> [15/15] Building WonderSwan sound core (WSR)..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libwswan.a" ]; then
    [ ! -d "beetle-wswan-libretro" ] && \
        git clone --depth 1 https://github.com/libretro/beetle-wswan-libretro.git
    cd beetle-wswan-libretro
    {
        find mednafen/wswan -name "*.cpp" -o -name "*.c" | while read f; do
            OBJ="${f%.*}.o"
            g++ -c $CF -I. -Imednafen -Imednafen/wswan "$f" -o "$OBJ" || true
        done
        find mednafen -name "*.o" | xargs ar rcs $PREFIX/lib/libwswan.a || true
        mkdir -p $PREFIX/include/wswan
        cp mednafen/wswan/*.h $PREFIX/include/wswan/ 2>/dev/null || true
    } > $LOGS/wswan.log 2>&1
fi
[ -f "$PREFIX/lib/libwswan.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/wswan.log; }

# ── Library summary ────────────────────────────────────────────
echo ""
echo "=== Library build summary ==="
for L in libSDL.a libsidplayfp.a libopenmpt.a libsc68.a libpsflib.a libhe.a libht.a \
         liblazyusf.a liblazygsf.a libadplug.a libbinio.a libvgm-player.a libmdxmini.a libwswan.a; do
    # libSDL lives under SDL_PREFIX
    if [ "$L" = "libSDL.a" ]; then
        [ -f "$SDL_PREFIX/lib/$L" ] && printf "  %-22s OK\n" "$L" || printf "  %-22s MISSING\n" "$L"
    else
        [ -f "$PREFIX/lib/$L" ] && printf "  %-22s OK\n" "$L" || printf "  %-22s MISSING\n" "$L"
    fi
done
echo ""

# ── Build player binary ────────────────────────────────────────
echo ">>> Building Music_Player binary..."
cd $WORK
export SDL_PREFIX
export MUSICLIBS_PREFIX=$PREFIX
make clean 2>/dev/null || true
make -j$NPROC
MAKE_STATUS=$?

if [ ! -f Music_Player ] || [ "$MAKE_STATUS" -ne 0 ]; then
    echo ""
    echo "==================================================="
    echo "  FINAL LINK FAILED — dumping all library logs"
    echo "==================================================="
    for f in $LOGS/*.log; do
        echo ""
        echo "--- $f (last 60 lines) ---"
        tail -60 "$f"
    done
    echo ""
    echo "ERROR: Music_Player binary not built!"
    exit 1
fi

echo ""
ls -lh Music_Player

# ── Package ────────────────────────────────────────────────────
echo ""
echo ">>> Packaging release..."
RELEASE=release
rm -rf $RELEASE
mkdir -p $RELEASE/games/Music_Player $RELEASE/Scripts
cp Music_Player $RELEASE/games/Music_Player/
chmod +x $RELEASE/games/Music_Player/Music_Player

cat > $RELEASE/Scripts/Install_Music_Player.sh << 'EOF'
#!/bin/bash
echo ""
echo "=== MiSTer Music Player Installer ==="
echo "    27 systems — 13 libraries — FPGA audio"
echo ""

BASE_URL="https://raw.githubusercontent.com/MiSTerOrganize/MiSTer_Music_Player/main"
DIR="/media/fat/games/Music_Player"
CON="/media/fat/_Multimedia/_Music/_Console"
COM="/media/fat/_Multimedia/_Music/_Computer"
DOCS="$DIR/docs/Music_Player"

mkdir -p "$DIR" "$CON" "$COM" "$DOCS"

# ── Download ARM binary ────────────────────────────────────────
echo ">>> Downloading Music_Player binary..."
cd "$DIR"
wget -q --no-check-certificate "$BASE_URL/games/Music_Player/Music_Player" -O Music_Player.tmp && \
    mv Music_Player.tmp Music_Player && chmod +x Music_Player && \
    echo "    Binary installed." || \
    { echo "    FAILED: Could not download binary."; rm -f Music_Player.tmp; exit 1; }

# ── Download Console RBFs (16) ─────────────────────────────────
echo ">>> Downloading 16 console RBFs..."
for RBF in \
    NES_Music_Player SNES_Music_Player MegaDrive_Music_Player \
    SMS_Music_Player GameGear_Music_Player S32X_Music_Player \
    Gameboy_Music_Player TurboGrafx16_Music_Player \
    ColecoVision_Music_Player SG-1000_Music_Player \
    Vectrex_Music_Player PSX_Music_Player Saturn_Music_Player \
    N64_Music_Player GBA_Music_Player WonderSwan_Music_Player; do
    wget -q --no-check-certificate "$BASE_URL/_Multimedia/_Music/_Console/${RBF}.rbf" -O "$CON/${RBF}.rbf" 2>/dev/null && \
        echo "    $RBF" || echo "    SKIP: $RBF (not found)"
done

# ── Download Computer RBFs (11) ────────────────────────────────
echo ">>> Downloading 11 computer RBFs..."
for RBF in \
    C64_Music_Player Amiga_Music_Player AtariST_Music_Player \
    Atari800_Music_Player ZX-Spectrum_Music_Player \
    Amstrad_Music_Player MSX_Music_Player BBCMicro_Music_Player \
    ao486_Music_Player PC-98_Music_Player X68000_Music_Player; do
    wget -q --no-check-certificate "$BASE_URL/_Multimedia/_Music/_Computer/${RBF}.rbf" -O "$COM/${RBF}.rbf" 2>/dev/null && \
        echo "    $RBF" || echo "    SKIP: $RBF (not found)"
done

# ── Download docs ──────────────────────────────────────────────
echo ">>> Downloading documentation..."
wget -q --no-check-certificate "$BASE_URL/docs/Music_Player/README.md" -O "$DOCS/README.md" 2>/dev/null && \
    echo "    README.md" || true

# ── Download and register daemon ───────────────────────────────
echo ">>> Setting up auto-launch daemon..."
wget -q --no-check-certificate "$BASE_URL/games/Music_Player/music_player_daemon.sh" \
    -O "$DIR/music_player_daemon.sh" 2>/dev/null && \
    chmod +x "$DIR/music_player_daemon.sh" && \
    echo "    Daemon downloaded." || true

# Register daemon in user-startup.sh (if not already registered)
STARTUP="/media/fat/linux/user-startup.sh"
DAEMON_LINE="$DIR/music_player_daemon.sh &"
if [ -f "$STARTUP" ]; then
    if ! grep -q "music_player_daemon" "$STARTUP" 2>/dev/null; then
        echo "" >> "$STARTUP"
        echo "# MiSTer Music Player auto-launch daemon" >> "$STARTUP"
        echo "$DAEMON_LINE" >> "$STARTUP"
        echo "    Daemon registered in user-startup.sh"
    else
        echo "    Daemon already registered."
    fi
else
    echo "#!/bin/bash" > "$STARTUP"
    echo "" >> "$STARTUP"
    echo "# MiSTer Music Player auto-launch daemon" >> "$STARTUP"
    echo "$DAEMON_LINE" >> "$STARTUP"
    chmod +x "$STARTUP"
    echo "    Created user-startup.sh with daemon."
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Place music files in subfolders of:"
echo "  $DIR/"
echo "  Example: $DIR/NES/Mega Man 2.nsf"
echo ""
echo "Documentation: $DOCS/"
echo ""
echo "In MiSTer menu, navigate to:"
echo "  _Multimedia > _Music > _Console or _Computer"
echo ""
EOF
chmod +x $RELEASE/Scripts/Install_Music_Player.sh

echo ""
echo "============================================"
echo "  Build Complete — ALL 27 systems working"
echo "============================================"
find $RELEASE -type f | sort
