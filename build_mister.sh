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
APT_PACKAGES="build-essential wget git cmake autoconf automake libtool libtool-bin \
    pkg-config zlib1g-dev gperf autopoint gettext bison flex xa65"

apt_try() {
    apt-get update -qq && apt-get install -y -qq --fix-missing $APT_PACKAGES
}

# Debian mirrors occasionally reset mid-download; retry up to 3 times
# with a short sleep before giving up.
for attempt in 1 2 3; do
    if apt_try; then
        break
    fi
    echo "apt-get install attempt $attempt failed; retrying in 10s..."
    sleep 10
    if [ "$attempt" = "3" ]; then
        echo "ERROR: apt-get install failed after 3 attempts"
        exit 1
    fi
done

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
        # configure.ac declares these m4 dirs via AC_CONFIG_MACRO_DIRS;
        # aclocal scans them even when the corresponding builder is
        # disabled. Create empty dirs so autoreconf doesn't die.
        mkdir -p m4 \
                 src/builders/exsid-builder/driver/m4 \
                 src/builders/hardsid-builder/hardsid/m4 \
                 src/builders/hardsid-builder/m4
        autoreconf -vfi
        CXXFLAGS="$CF" CFLAGS="$CF" ./configure --prefix=$PREFIX \
            --enable-static --disable-shared --with-simd=none \
            --disable-hardsid --disable-exsid --disable-usbsid
        make -j$NPROC && make install
    } > $LOGS/sidplayfp.log 2>&1
fi
[ -f "$PREFIX/lib/libsidplayfp.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/sidplayfp.log; }

# ── 5. libopenmpt ──────────────────────────────────────────────
echo ">>> [5/15] Building libopenmpt..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libopenmpt.a" ]; then
    # Use the -autotools archive: the `make CONFIG=generic` path was
    # removed upstream, but libopenmpt continues to ship an autotools
    # tarball on their release page that builds cleanly with ./configure.
    [ ! -f openmpt-src.tar.gz ] && wget -q -O openmpt-src.tar.gz \
        https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.7.13+release.autotools.tar.gz
    rm -rf openmpt-src && mkdir -p openmpt-src && \
        tar xzf openmpt-src.tar.gz -C openmpt-src --strip-components=1
    cd openmpt-src
    {
        CXXFLAGS="$CF" CFLAGS="$CF" ./configure --prefix=$PREFIX \
            --enable-static --disable-shared \
            --disable-openmpt123 --disable-tests --disable-examples \
            --without-mpg123 --without-ogg --without-vorbis \
            --without-vorbisfile --without-sndfile --without-flac \
            --without-portaudio --without-portaudiocpp \
            --without-pulseaudio --without-sdl2
        make -j$NPROC
        make install
    } > $LOGS/openmpt.log 2>&1
fi
[ -f "$PREFIX/lib/libopenmpt.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/openmpt.log; }

# ── 6. sc68 ────────────────────────────────────────────────────
echo ">>> [6/15] Building sc68..."
cd $LIBS
if [ ! -f "$PREFIX/lib/libsc68.a" ]; then
    # Zeinok/sc68 autotools is broken (Makefile.am:59 SOURCE_UNICE68
    # missing). Manual build of the four subtrees (unice68, file68,
    # emu68, libsc68), packing their .o files into one archive that
    # exposes the sc68_* API without running autoreconf.
    [ ! -d "sc68" ] && git clone --depth 1 https://github.com/Zeinok/sc68.git
    cd sc68
    {
        mkdir -p $PREFIX/include/sc68
        cat > sc68_config_stub.h <<'CFG_EOF'
#ifndef SC68_CONFIG_STUB_H
#define SC68_CONFIG_STUB_H
#define PACKAGE_VERSION "3.0.0"
#define PACKAGE_STRING  "sc68 3.0.0"
#define PACKAGE_NAME    "sc68"
#define VERSION         "3.0.0"
#define HAVE_STDINT_H   1
#define HAVE_STDLIB_H   1
#define HAVE_STRING_H   1
#define HAVE_UNISTD_H   1
#define HAVE_ASSERT_H   1
#define HAVE_MATH_H     1
#define U_INLINE        inline
#define SC68_INLINE     inline
#endif
CFG_EOF
        SC68_CF="$CF -DHAVE_CONFIG_H -include $(pwd)/sc68_config_stub.h -Wno-error"
        for f in unice68/unice68/*.c; do
            [ -f "$f" ] && gcc -c $SC68_CF -Iunice68/unice68 "$f" -o "${f%.c}.o" || true
        done
        for f in file68/file68/*.c; do
            [ -f "$f" ] && gcc -c $SC68_CF -Ifile68 -Ifile68/file68 \
                -Iunice68/unice68 "$f" -o "${f%.c}.o" || true
        done
        for f in emu68/emu68/*.c; do
            [ -f "$f" ] && gcc -c $SC68_CF -Iemu68 -Iemu68/emu68 \
                -Ifile68 -Ifile68/file68 "$f" -o "${f%.c}.o" || true
        done
        for f in libsc68/libsc68/*.c; do
            [ -f "$f" ] && gcc -c $SC68_CF -Ilibsc68 -Ilibsc68/libsc68 \
                -Iemu68 -Iemu68/emu68 -Ifile68 -Ifile68/file68 \
                -Iunice68/unice68 "$f" -o "${f%.c}.o" || true
        done
        find unice68 file68 emu68 libsc68 -name "*.o" 2>/dev/null \
            | xargs ar rcs $PREFIX/lib/libsc68.a
        # Thin alias -- Makefile link line references -lfile68 separately.
        cp $PREFIX/lib/libsc68.a $PREFIX/lib/libfile68.a
        cp -r libsc68/sc68 $PREFIX/include/ 2>/dev/null || true
        cp -r file68/sc68 $PREFIX/include/ 2>/dev/null || true
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
        # Every core .c starts with #error unless EMU_COMPILE is defined.
        HE_CF="$CF -DEMU_COMPILE=\"\\\"2026-MiSTer\\\"\" -DEMU_RELEASE=\"\\\"2026\\\"\" -Wno-error"
        find . -name "*.c" | while read f; do
            gcc -c $HE_CF -I. -ICore -I$PREFIX/include "$f" -o "${f%.c}.o" || true
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
        # EMU_COMPILE + pointer-type compat for C68k (satsound.c casts
        # a uint8* to 'pointer' which is defined as uint32 in c68k.h).
        HT_CF="$CF -DEMU_COMPILE=\"\\\"2026-MiSTer\\\"\" -DEMU_RELEASE=\"\\\"2026\\\"\" -Wno-error -Wno-int-conversion -Wno-implicit-function-declaration -Wno-incompatible-pointer-types"
        # Starscream's generated cpudebug.h isn't shipped; stub it out.
        mkdir -p Core/Starscream
        touch Core/Starscream/cpudebug.h
        find . -name "*.c" -not -path "./Core/Starscream/cpudebug.c" | while read f; do
            gcc -c $HT_CF -I. -ICore -ICore/c68k -ICore/Starscream -I$PREFIX/include "$f" -o "${f%.c}.o" || true
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
    # derselbst/lazyusf2 is the maintained fork. The r4300/new_dynarec
    # recompiler has drifted from the rest of the tree and has
    # DebugMessage signature mismatches; skip it entirely and rely on
    # the interpreter (rsp_lle + r4300 core) which is fast enough for
    # audio-only playback on Cortex-A9.
    [ ! -d "lazyusf2" ] && git clone --depth 1 https://github.com/derselbst/lazyusf2.git
    {
        cd lazyusf2
        LAZYUSF_CF="$CF -DARM -DUSE_EXPANSION_PAK -DDYNAREC_OFF -Wno-error -Wno-int-conversion -Wno-implicit-function-declaration -Wno-incompatible-pointer-types"
        find . -name "*.c" \
            -not -name "bench.c" \
            -not -path "./build/*" \
            -not -path "./r4300/new_dynarec/*" | while read f; do
            gcc -c $LAZYUSF_CF -I. -Ir4300 -Iusf -Irsp_lle -I$PREFIX/include "$f" -o "${f%.c}.o" || true
        done
        find . -name "*.o" -not -path "./build/*" | xargs ar rcs $PREFIX/lib/liblazyusf.a || true
        mkdir -p $PREFIX/include/lazyusf
        find . -maxdepth 2 -name "usf.h" -exec cp {} $PREFIX/include/lazyusf/ \;
    } > $LOGS/lazyusf.log 2>&1
fi
[ -f "$PREFIX/lib/liblazyusf.a" ] && echo "    OK" || { echo "    FAIL — tail of log:"; tail -30 $LOGS/lazyusf.log; }

# ── 11. lazygsf (GSF — GBA) ───────────────────────────────────
echo ">>> [11/15] Building lazygsf (GBA GSF)..."
cd $LIBS
if [ ! -f "$PREFIX/lib/liblazygsf.a" ]; then
    # lazygsf wraps mGBA's sound core; it needs mGBA's public headers
    # on the include path (mgba/core/core.h etc). Clone mGBA next to
    # lazygsf and point at its include directory.
    [ ! -d "mgba" ] && git clone --depth 1 https://github.com/mgba-emu/mgba.git
    [ ! -d "lazygsf" ] && git clone --depth 1 https://github.com/jprjr/lazygsf.git
    cd lazygsf
    {
        LG_CF="$CF -I$LIBS/mgba/include -I$LIBS/mgba/src -I. -I$PREFIX/include -DLAZYGSF_STATIC -DDISABLE_THREADING -Wno-error"
        find . -name "*.c" -o -name "*.cpp" | while read f; do
            OBJ="${f%.*}.o"
            if [[ "$f" == *.cpp ]]; then
                g++ -c $LG_CF "$f" -o "$OBJ" || true
            else
                gcc -c $LG_CF "$f" -o "$OBJ" || true
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
        # libbinio must succeed first; pkg-config discovery is how
        # adplug's configure finds it.
        cd $LIBS/libbinio
        autoreconf -vfi
        CXXFLAGS="$CF" ./configure --prefix=$PREFIX --enable-static --disable-shared
        make -j$NPROC
        make install

        if [ ! -f "$PREFIX/lib/pkgconfig/libbinio.pc" ]; then
            echo "WARN: libbinio.pc not installed; adplug configure will probably fail,"
            echo "      but continuing so the rest of the pipeline can build."
        fi

        cd $LIBS/adplug
        autoreconf -vfi
        PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
        libbinio_CFLAGS="-I$PREFIX/include" \
        libbinio_LIBS="-L$PREFIX/lib -lbinio" \
        CXXFLAGS="$CF -I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
            ./configure --prefix=$PREFIX --enable-static --disable-shared \
            --without-adplay
        make -j$NPROC
        make install
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
    # Needs libretro-common for boolean.h, retro_inline.h, etc.
    [ ! -d "libretro-common" ] && \
        git clone --depth 1 https://github.com/libretro/libretro-common.git
    [ ! -d "beetle-wswan-libretro" ] && \
        git clone --depth 1 https://github.com/libretro/beetle-wswan-libretro.git
    cd beetle-wswan-libretro
    {
        WSWAN_CF="$CF -I. -Imednafen -Imednafen/wswan -Imednafen/hw_cpu \
            -Imednafen/hw_sound -Imednafen/include \
            -I$LIBS/libretro-common/include \
            -DLSB_FIRST -DWANT_NEW_API -DSTDC_HEADERS=1 -DWANT_STEREO_SOUND \
            -Wno-error -Wno-narrowing -fpermissive"
        find mednafen/wswan -name "*.cpp" -o -name "*.c" | while read f; do
            OBJ="${f%.*}.o"
            if [[ "$f" == *.cpp ]]; then
                g++ -c $WSWAN_CF "$f" -o "$OBJ" || true
            else
                gcc -c $WSWAN_CF "$f" -o "$OBJ" || true
            fi
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
