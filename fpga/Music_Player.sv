//============================================================================
//
//  Music Player for MiSTer — Hybrid FPGA+ARM Core
//
//  FPGA handles native video output (320x240 RGB565 from DDR3).
//  ARM runs Game_Music_Emu for audio synthesis and renders UI to DDR3.
//  OSD file browser loads music files via ioctl -> DDR3.
//
//  RBF goes in _Multimedia/ folder.
//  Core name: Music_Player (setname for games/ folder)
//
//  Adapted from PICO-8 core (MiSTerOrganize/MiSTer_PICO-8)
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

module emu
(
    //Master input clock
    input         CLK_50M,

    //Async reset from top-level module.
    input         RESET,

    //Must be passed to hps_io module
    inout  [48:0] HPS_BUS,

    //Base video clock
    output        CLK_VIDEO,

    //Multiple resolutions are supported using different CE_PIXEL rates.
    output        CE_PIXEL,

    //Video aspect ratio for HDMI.
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,

    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output        VGA_F1,
    output [1:0]  VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,

    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,
    output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,
    output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
    output        FB_PAL_CLK,
    output  [7:0] FB_PAL_ADDR,
    output [23:0] FB_PAL_DOUT,
    input  [23:0] FB_PAL_DIN,
    output        FB_PAL_WR,
`endif
`endif

    output        LED_USER,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,

    // I/O board button press simulation (directly directly directly directly directly directly accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent
    output  [1:0] BUTTONS,

    //SDRAM interface
    output        SDRAM_CLK,
    output        SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output        SDRAM_nCS,
    output        SDRAM_nCAS,
    output        SDRAM_nRAS,
    output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
    output [12:0] SDRAM2_A,
    output  [1:0] SDRAM2_BA,
    inout  [15:0] SDRAM2_DQ,
    output        SDRAM2_CLK,
    output        SDRAM2_CKE,
    output        SDRAM2_nCS,
    output        SDRAM2_nCAS,
    output        SDRAM2_nRAS,
    output        SDRAM2_nWE,
    output        SDRAM2_DQML,
    output        SDRAM2_DQMH,
`endif

    //High latance DDR3 RAM interface
    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    //directly accent accent accent accent accent accent
    input         UART_CTS,
    output        UART_RTS,
    input         UART_RXD,
    output        UART_TXD,
    output        UART_DTR,
    input         UART_DSR,

    // Open-drain accent accent accent
    output        USER_OSD,
    output [6:0]  USER_OUT,
    input  [6:0]  USER_IN,

    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

    input         OSD_STATUS,

    input         CLK_AUDIO, // 24.576 MHz from framework
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

    inout   [3:0] ADC_BUS
);

// -- Default assignments for unused ports --
wire NATIVE_VID_ACTIVE;

`ifdef MISTER_FB
assign FB_EN     = 0;
assign FB_FORMAT = 0;
assign FB_WIDTH  = 0;
assign FB_HEIGHT = 0;
assign FB_BASE   = 0;
assign FB_STRIDE = 0;
assign FB_FORCE_BLANK = 0;
`endif

assign USER_OSD   = 1'bZ;
assign UART_RTS   = 0;
assign UART_TXD   = 0;
assign UART_DTR   = 0;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = {16'bZ, 27'b0};
assign ADC_BUS = 4'bZZZZ;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

// -- Pixel clock -- integer divider, zero jitter
reg [1:0] ce_div;
wire ce_pix_div4 = (ce_div == 2'd0);
always @(posedge CLK_VIDEO) begin
    if (RESET) ce_div <= 2'd0;
    else ce_div <= ce_div + 2'd1;
end
assign CE_PIXEL = ce_pix_div4;

assign VGA_SL = 0;
assign VGA_F1 = 0;
// 320x240 = 4:3 aspect ratio
assign VIDEO_ARX = 13'd4;
assign VIDEO_ARY = 13'd3;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;

assign AUDIO_MIX = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;

assign LED_DISK = 0;
assign LED_POWER[1] = 1;
assign BUTTONS = 0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER    = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];
assign LED_POWER[0] = 0;

// -- CONF_STR --
// Parameterized per-system. Build with -DCORE_XXX to select variant.
// All variants share identical FPGA logic; only CONF_STR differs.
// Default (no define) = NES_Music_Player with NSF extensions.
`include "build_id.v"

// Setname must match the ARM binary folder: games/Music_Player/
// The OSD title shows the system-specific name.

localparam CONF_STR = {
`ifdef CORE_NES
    "NES_Music_Player;;",
    "F0,NSFNSFE,Load NSF;",
`elsif CORE_SNES
    "SNES_Music_Player;;",
    "F0,SPC,Load SPC;",
`elsif CORE_MEGADRIVE
    "MegaDrive_Music_Player;;",
    "F0,VGMVGZGYM,Load VGM;",
`elsif CORE_SMS
    "SMS_Music_Player;;",
    "F0,VGMVGZ,Load VGM;",
`elsif CORE_GAMEGEAR
    "GameGear_Music_Player;;",
    "F0,VGMVGZ,Load VGM;",
`elsif CORE_S32X
    "S32X_Music_Player;;",
    "F0,VGMVGZ,Load VGM;",
`elsif CORE_GAMEBOY
    "Gameboy_Music_Player;;",
    "F0,GBS,Load GBS;",
`elsif CORE_TURBOGRAFX16
    "TurboGrafx16_Music_Player;;",
    "F0,HES,Load HES;",
`elsif CORE_COLECOVISION
    "ColecoVision_Music_Player;;",
    "F0,VGMVGZ,Load VGM;",
`elsif CORE_SG1000
    "SG-1000_Music_Player;;",
    "F0,VGMVGZ,Load VGM;",
`elsif CORE_VECTREX
    "Vectrex_Music_Player;;",
    "F0,AY ,Load AY;",
`elsif CORE_PSX
    "PSX_Music_Player;;",
    "F0,PSFMINIPSF,Load PSF;",
`elsif CORE_SATURN
    "Saturn_Music_Player;;",
    "F0,SSF,Load SSF;",
`elsif CORE_N64
    "N64_Music_Player;;",
    "F0,USFMINIUSF,Load USF;",
`elsif CORE_GBA
    "GBA_Music_Player;;",
    "F0,GSFMINIGSF,Load GSF;",
`elsif CORE_WONDERSWAN
    "WonderSwan_Music_Player;;",
    "F0,WSR,Load WSR;",
`elsif CORE_C64
    "C64_Music_Player;;",
    "F0,SID,Load SID;",
`elsif CORE_AMIGA
    "Amiga_Music_Player;;",
    "F0,MODS3MXM IT MPTM,Load Module;",
`elsif CORE_ATARIST
    "AtariST_Music_Player;;",
    "F0,SNDHSC68,Load SNDH;",
`elsif CORE_ATARI800
    "Atari800_Music_Player;;",
    "F0,SAP,Load SAP;",
`elsif CORE_ZXSPECTRUM
    "ZX-Spectrum_Music_Player;;",
    "F0,AY ,Load AY;",
`elsif CORE_AMSTRAD
    "Amstrad_Music_Player;;",
    "F0,AY ,Load AY;",
`elsif CORE_MSX
    "MSX_Music_Player;;",
    "F0,KSS,Load KSS;",
`elsif CORE_BBCMICRO
    "BBCMicro_Music_Player;;",
    "F0,VGMVGZ,Load VGM;",
`elsif CORE_AO486
    "ao486_Music_Player;;",
    "F0,DROIMFCMF,Load AdLib;",
`elsif CORE_PC98
    "PC-98_Music_Player;;",
    "F0,S98,Load S98;",
`elsif CORE_X68000
    "X68000_Music_Player;;",
    "F0,MDX,Load MDX;",
`else
    // Default: NES
    "NES_Music_Player;;",
    "F0,NSFNSFE,Load NSF;",
`endif
    "-;",
    "J1,Play-Pause,Loop;",
    "jn,A,Start;",
    "-;",
    "V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [31:0] status;
wire [31:0] joystick_0;
wire [15:0] joystick_l_analog_0;

// ioctl signals for file loading
wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;
assign ioctl_wait = nv_ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .forced_scandoubler(forced_scandoubler),
    .status(status),
    .status_menumask(cfg),
    .joystick_0(joystick_0),
    .joystick_l_analog_0(joystick_l_analog_0),
    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index),
    .ioctl_wait(ioctl_wait)
);

////////////////////   CLOCKS   ///////////////////
wire locked, clk_sys;
wire clk_20m;
wire clk_pix;   // PLL outclk_2: 31.25 MHz
pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(clk_sys),
    .outclk_1(clk_20m),
    .outclk_2(clk_pix),
    .locked(locked)
);

assign CLK_VIDEO = clk_pix;

// --- Native video control ---
wire NATIVE_VID = 1'b1;  // Always on
assign NATIVE_VID_ACTIVE = NATIVE_VID;


/////////////////////   SDRAM   ///////////////////
// Music Player does not use SDRAM — only DDR3 for native video.
// SDRAM pins are already driven to zero/Z at the top of the module.
reg [15:0] cfg = 0;

// --- DDR3: Native video reader owns DDR3 exclusively ---
wire  [7:0] nv_ddr_burstcnt;
wire [28:0] nv_ddr_addr;
wire        nv_ddr_rd;
wire [63:0] nv_ddr_din;
wire  [7:0] nv_ddr_be;
wire        nv_ddr_we;
wire        nv_ioctl_wait;

// No legacy DDR3 user -- native video connects directly
assign DDRAM_CLK      = clk_sys;
assign DDRAM_BURSTCNT = nv_ddr_burstcnt;
assign DDRAM_ADDR     = nv_ddr_addr;
assign DDRAM_RD       = nv_ddr_rd;
assign DDRAM_DIN      = nv_ddr_din;
assign DDRAM_BE       = nv_ddr_be;
assign DDRAM_WE       = nv_ddr_we;

wire use_nv = NATIVE_VID;

////////////////////////////  AUDIO  //////////////////////////////////
// Audio comes from ARM via DDR3 ring buffer -> FPGA audio output.
// Same path as NES, SNES, Genesis: AUDIO_L/R -> I2S + SPDIF + DAC.
wire [15:0] nv_audio_l, nv_audio_r;
assign AUDIO_L = nv_audio_l;
assign AUDIO_R = nv_audio_r;
assign AUDIO_S = 1;  // signed (same as SNES, Genesis, Game Boy)

assign USER_OUT[0]   = 1;
assign USER_OUT[1]   = 1;
assign USER_OUT[6:2] = '1;

// --- Native video + audio module ---
wire [7:0] nv_r, nv_g, nv_b;
wire       nv_hs, nv_vs, nv_de;
wire       nv_active;

mp_video_top native_video
(
    .clk_sys        (clk_sys),
    .clk_vid        (CLK_VIDEO),
    .clk_audio      (CLK_AUDIO),
    .ce_pix         (ce_pix_div4),
    .reset          (RESET),

    // DDR3 interface
    .ddr_busy       (DDRAM_BUSY),
    .ddr_burstcnt   (nv_ddr_burstcnt),
    .ddr_addr       (nv_ddr_addr),
    .ddr_dout       (DDRAM_DOUT),
    .ddr_dout_ready (DDRAM_DOUT_READY & use_nv),
    .ddr_rd         (nv_ddr_rd),
    .ddr_din        (nv_ddr_din),
    .ddr_be         (nv_ddr_be),
    .ddr_we         (nv_ddr_we),

    // Video output
    .vga_r          (nv_r),
    .vga_g          (nv_g),
    .vga_b          (nv_b),
    .vga_hs         (nv_hs),
    .vga_vs         (nv_vs),
    .vga_de         (nv_de),

    // Audio output
    .audio_l        (nv_audio_l),
    .audio_r        (nv_audio_r),

    // Control
    .enable         (use_nv),
    .active         (nv_active),
    .vsync_out      (),

    // Joystick
    .joystick_0     (joystick_0),
    .joystick_l_analog_0 (joystick_l_analog_0),

    // File loading
    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_wait     (nv_ioctl_wait),

    // Audio enable (always on for now — ARM sets flag when ready)
    .audio_enable   (1'b1)
);

// Mux VGA outputs
assign VGA_DE  = NATIVE_VID_ACTIVE ? nv_de  : 1'b0;
assign VGA_HS  = NATIVE_VID_ACTIVE ? nv_hs  : 1'b1;
assign VGA_VS  = NATIVE_VID_ACTIVE ? nv_vs  : 1'b1;
assign VGA_R   = nv_active ? nv_r : 8'd0;
assign VGA_G   = nv_active ? nv_g : 8'd0;
assign VGA_B   = nv_active ? nv_b : 8'd0;

endmodule
