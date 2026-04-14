@echo off
REM ============================================================================
REM
REM  build_all_rbfs.bat — Build all 27 Music Player RBF variants (Windows)
REM
REM  Double-click this file from the fpga\ folder.
REM  Quartus must be installed. No need to open the Quartus GUI.
REM
REM  This script runs quartus_sh.exe from the command line 27 times,
REM  each with a different VERILOG_MACRO to select the CONF_STR variant.
REM
REM  Output goes to: output\_Multimedia\_Music\_Console\ and _Computer\
REM
REM  Estimated time: 2-4 hours depending on your PC.
REM
REM  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
REM
REM ============================================================================

setlocal enabledelayedexpansion

REM ── Find Quartus ──────────────────────────────────────────────
REM Try common install paths. Edit this if yours is different.
set "QUARTUS_SH="
for %%Q in (
    "C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA_lite\18.0\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA_lite\19.1\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA_lite\20.1\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA_lite\21.1\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA_lite\22.1\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA_lite\23.1\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA\17.0\quartus\bin64\quartus_sh.exe"
    "C:\intelFPGA\17.1\quartus\bin64\quartus_sh.exe"
) do (
    if exist %%Q (
        set "QUARTUS_SH=%%~Q"
        goto :found_quartus
    )
)

REM Try PATH
where quartus_sh.exe >nul 2>&1
if %errorlevel%==0 (
    set "QUARTUS_SH=quartus_sh.exe"
    goto :found_quartus
)

echo ERROR: Cannot find quartus_sh.exe
echo.
echo Please edit this batch file and set the correct path to your
echo Quartus installation, or add Quartus bin64 to your PATH.
echo.
pause
exit /b 1

:found_quartus
echo Found Quartus: %QUARTUS_SH%
echo.

REM ── Setup ─────────────────────────────────────────────────────
set "PROJECT=Music_Player"
set "QSF=%PROJECT%.qsf"
set "DATE=%date:~10,4%%date:~4,2%%date:~7,2%"

REM Save original QSF
copy /Y "%QSF%" "%QSF%.seed" >nul

REM Create output folders
mkdir "output\_Multimedia\_Music\_Console" 2>nul
mkdir "output\_Multimedia\_Music\_Computer" 2>nul

set BUILT=0
set FAILED=0
set TOTAL=27

echo ============================================
echo   MiSTer Music Player — Building %TOTAL% RBFs
echo   This will take 2-4 hours. Go get coffee.
echo ============================================
echo.

REM ── Console cores (16) ────────────────────────────────────────
call :build_core CORE_NES            NES_Music_Player            _Console
call :build_core CORE_SNES           SNES_Music_Player           _Console
call :build_core CORE_MEGADRIVE      MegaDrive_Music_Player      _Console
call :build_core CORE_SMS            SMS_Music_Player            _Console
call :build_core CORE_GAMEGEAR       GameGear_Music_Player       _Console
call :build_core CORE_S32X           S32X_Music_Player           _Console
call :build_core CORE_GAMEBOY        Gameboy_Music_Player        _Console
call :build_core CORE_TURBOGRAFX16   TurboGrafx16_Music_Player   _Console
call :build_core CORE_COLECOVISION   ColecoVision_Music_Player   _Console
call :build_core CORE_SG1000         SG-1000_Music_Player        _Console
call :build_core CORE_VECTREX        Vectrex_Music_Player        _Console
call :build_core CORE_PSX            PSX_Music_Player            _Console
call :build_core CORE_SATURN         Saturn_Music_Player         _Console
call :build_core CORE_N64            N64_Music_Player            _Console
call :build_core CORE_GBA            GBA_Music_Player            _Console
call :build_core CORE_WONDERSWAN     WonderSwan_Music_Player     _Console

REM ── Computer cores (11) ───────────────────────────────────────
call :build_core CORE_C64            C64_Music_Player            _Computer
call :build_core CORE_AMIGA          Amiga_Music_Player          _Computer
call :build_core CORE_ATARIST        AtariST_Music_Player        _Computer
call :build_core CORE_ATARI800       Atari800_Music_Player       _Computer
call :build_core CORE_ZXSPECTRUM     ZX-Spectrum_Music_Player    _Computer
call :build_core CORE_AMSTRAD        Amstrad_Music_Player        _Computer
call :build_core CORE_MSX            MSX_Music_Player            _Computer
call :build_core CORE_BBCMICRO       BBCMicro_Music_Player       _Computer
call :build_core CORE_AO486          ao486_Music_Player          _Computer
call :build_core CORE_PC98           PC-98_Music_Player          _Computer
call :build_core CORE_X68000         X68000_Music_Player         _Computer

REM ── Done ──────────────────────────────────────────────────────
copy /Y "%QSF%.seed" "%QSF%" >nul
del "%QSF%.seed" 2>nul

echo.
echo ============================================
echo   Build complete: %BUILT% succeeded, %FAILED% failed out of %TOTAL%
echo   Output: output\_Multimedia\_Music\
echo ============================================
echo.

if %BUILT% GTR 0 (
    echo RBFs built:
    dir /s /b output\*.rbf 2>nul
)

echo.
pause
exit /b 0

REM ── Build one core variant ────────────────────────────────────
:build_core
set "DEFINE=%~1"
set "RBF_NAME=%~2"
set "SUBFOLDER=%~3"

set /a "COUNT=BUILT+FAILED+1"
echo [%COUNT%/%TOTAL%] Building %RBF_NAME% (%DEFINE%)...

REM Restore clean QSF and add define
copy /Y "%QSF%.seed" "%QSF%" >nul
echo set_global_assignment -name VERILOG_MACRO "%DEFINE%=1" >> "%QSF%"

REM Run Quartus compile
"%QUARTUS_SH%" --flow compile %PROJECT% > "build_%RBF_NAME%.log" 2>&1

if %errorlevel%==0 (
    if exist "output_files\%PROJECT%.rbf" (
        copy /Y "output_files\%PROJECT%.rbf" "output\_Multimedia\_Music\%SUBFOLDER%\%RBF_NAME%_%DATE%.rbf" >nul
        echo   OK: %RBF_NAME%_%DATE%.rbf
        set /a BUILT+=1
    ) else (
        echo   FAIL: RBF not found after compile
        set /a FAILED+=1
    )
) else (
    echo   FAIL: Compile error - see build_%RBF_NAME%.log
    set /a FAILED+=1
)

exit /b 0
