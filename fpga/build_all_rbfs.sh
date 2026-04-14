#!/bin/bash
#============================================================================
#
#  build_all_rbfs.sh — Build all 28 Music Player RBF variants
#
#  Each variant is identical FPGA logic with a different CONF_STR.
#  Run from the fpga/ directory with Quartus in PATH.
#
#  Usage: ./build_all_rbfs.sh [output_dir]
#  Default output: ./output/
#
#  Requires: Quartus Prime (Lite or Standard), 17.0+
#
#  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
#
#============================================================================

set -e

OUTPUT_DIR="${1:-./output}"
PROJECT="Music_Player"
QSF="${PROJECT}.qsf"
SEED_QSF="${QSF}.seed"

# Save original QSF
cp "$QSF" "$SEED_QSF"

mkdir -p "$OUTPUT_DIR/_Multimedia/_Music/_Console"
mkdir -p "$OUTPUT_DIR/_Multimedia/_Music/_Computer"

# All 28 core variants: DEFINE|RBF_NAME|SUBFOLDER
CORES=(
    # Console (17)
    "CORE_NES|NES_Music_Player|_Console"
    "CORE_SNES|SNES_Music_Player|_Console"
    "CORE_MEGADRIVE|MegaDrive_Music_Player|_Console"
    "CORE_SMS|SMS_Music_Player|_Console"
    "CORE_GAMEGEAR|GameGear_Music_Player|_Console"
    "CORE_S32X|S32X_Music_Player|_Console"
    "CORE_GAMEBOY|Gameboy_Music_Player|_Console"
    "CORE_TURBOGRAFX16|TurboGrafx16_Music_Player|_Console"
    "CORE_COLECOVISION|ColecoVision_Music_Player|_Console"
    "CORE_SG1000|SG-1000_Music_Player|_Console"
    "CORE_VECTREX|Vectrex_Music_Player|_Console"
    "CORE_PSX|PSX_Music_Player|_Console"
    "CORE_SATURN|Saturn_Music_Player|_Console"
    "CORE_N64|N64_Music_Player|_Console"
    "CORE_GBA|GBA_Music_Player|_Console"
    "CORE_WONDERSWAN|WonderSwan_Music_Player|_Console"
    # Computer (11)
    "CORE_C64|C64_Music_Player|_Computer"
    "CORE_AMIGA|Amiga_Music_Player|_Computer"
    "CORE_ATARIST|AtariST_Music_Player|_Computer"
    "CORE_ATARI800|Atari800_Music_Player|_Computer"
    "CORE_ZXSPECTRUM|ZX-Spectrum_Music_Player|_Computer"
    "CORE_AMSTRAD|Amstrad_Music_Player|_Computer"
    "CORE_MSX|MSX_Music_Player|_Computer"
    "CORE_BBCMICRO|BBCMicro_Music_Player|_Computer"
    "CORE_AO486|ao486_Music_Player|_Computer"
    "CORE_PC98|PC-98_Music_Player|_Computer"
    "CORE_X68000|X68000_Music_Player|_Computer"
)

TOTAL=${#CORES[@]}
BUILT=0
FAILED=0

echo "============================================"
echo "  MiSTer Music Player — Building $TOTAL RBFs"
echo "============================================"
echo ""

for entry in "${CORES[@]}"; do
    IFS='|' read -r DEFINE RBF_NAME SUBFOLDER <<< "$entry"

    echo "[$((BUILT+FAILED+1))/$TOTAL] Building $RBF_NAME ($DEFINE)..."

    # Restore seed QSF and add the define
    cp "$SEED_QSF" "$QSF"

    # Add Verilog define for this variant
    echo "set_global_assignment -name VERILOG_MACRO \"${DEFINE}=1\"" >> "$QSF"

    # Run Quartus compile
    if quartus_sh --flow compile "$PROJECT" > "build_${RBF_NAME}.log" 2>&1; then
        # Get date for RBF filename
        DATE=$(date +%Y%m%d)
        SRC_RBF="output_files/${PROJECT}.rbf"
        DST_RBF="$OUTPUT_DIR/_Multimedia/_Music/${SUBFOLDER}/${RBF_NAME}_${DATE}.rbf"

        if [ -f "$SRC_RBF" ]; then
            cp "$SRC_RBF" "$DST_RBF"
            SIZE=$(ls -lh "$DST_RBF" | awk '{print $5}')
            echo "  ✓ $DST_RBF ($SIZE)"
            BUILT=$((BUILT+1))
        else
            echo "  ✗ RBF not found after compile!"
            FAILED=$((FAILED+1))
        fi
    else
        echo "  ✗ Compile failed! See build_${RBF_NAME}.log"
        FAILED=$((FAILED+1))
    fi
done

# Restore original QSF
cp "$SEED_QSF" "$QSF"
rm -f "$SEED_QSF"

echo ""
echo "============================================"
echo "  Build complete: $BUILT succeeded, $FAILED failed"
echo "  Output: $OUTPUT_DIR/_Multimedia/_Music/"
echo "============================================"
echo ""

if [ "$BUILT" -gt 0 ]; then
    echo "SD card layout:"
    find "$OUTPUT_DIR/_Multimedia" -name "*.rbf" | sort | while read f; do
        echo "  $f"
    done
fi
