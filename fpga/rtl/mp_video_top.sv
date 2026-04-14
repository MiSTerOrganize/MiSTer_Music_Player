//============================================================================
//
//  Music Player — Video + Audio Top-Level Wrapper
//
//  Connects video timing, FPGA-rendered UI, and audio output.
//  DDR3 is shared between video renderer (metadata + waveform reads)
//  and audio module (ring buffer reads), with renderer as arbiter.
//
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

module mp_video_top (
    input  wire        clk_sys,       // 100 MHz for DDR3
    input  wire        clk_vid,       // 31.25 MHz (CLK_VIDEO)
    input  wire        clk_audio,     // 24.576 MHz (CLK_AUDIO)
    input  wire        ce_pix,        // pixel enable (div-4 = 7.8125 MHz)
    input  wire        reset,

    // DDR3 Avalon-MM master
    input  wire        ddr_busy,
    output wire  [7:0] ddr_burstcnt,
    output wire [28:0] ddr_addr,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready,
    output wire        ddr_rd,
    output wire [63:0] ddr_din,
    output wire  [7:0] ddr_be,
    output wire        ddr_we,

    // Video output
    output wire  [7:0] vga_r,
    output wire  [7:0] vga_g,
    output wire  [7:0] vga_b,
    output wire        vga_hs,
    output wire        vga_vs,
    output wire        vga_de,

    // Audio output
    output wire [15:0] audio_l,
    output wire [15:0] audio_r,

    // Control
    input  wire        enable,
    output wire        active,
    output wire        vsync_out,

    // Joystick
    input  wire [31:0] joystick_0,
    input  wire [15:0] joystick_l_analog_0,

    // File loading
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    output wire        ioctl_wait,

    // Audio enable (from ARM via playback state flags)
    input  wire        audio_enable
);

assign ddr_be = 8'hFF;

// ── Video Timing ────────────────────────────────────────────────────
wire        tim_hsync, tim_vsync;
wire        tim_hblank, tim_vblank;
wire        tim_de;
wire [9:0]  tim_hcount;
wire [8:0]  tim_vcount;
wire        tim_new_frame, tim_new_line;

mp_video_timing timing (
    .clk       (clk_vid),
    .ce_pix    (ce_pix),
    .reset     (reset),
    .hsync     (tim_hsync),
    .vsync     (tim_vsync),
    .hblank    (tim_hblank),
    .vblank    (tim_vblank),
    .de        (tim_de),
    .hcount    (tim_hcount),
    .vcount    (tim_vcount),
    .new_frame (tim_new_frame),
    .new_line  (tim_new_line)
);

// ── DDR3 Arbitration ────────────────────────────────────────────────
// Video renderer is the primary DDR3 user (reads metadata during vblank).
// Audio module requests DDR3 access; renderer grants it during idle.

wire        vid_ddr_rd, vid_ddr_we;
wire [28:0] vid_ddr_addr;
wire  [7:0] vid_ddr_burstcnt;
wire [63:0] vid_ddr_din;

wire        aud_ddr_rd, aud_ddr_we;
wire [28:0] aud_ddr_addr;
wire  [7:0] aud_ddr_burstcnt;
wire [63:0] aud_ddr_din;

wire        aud_req, aud_grant;

// Mux: when audio is granted, it drives DDR3; otherwise video does
assign ddr_rd       = aud_grant ? aud_ddr_rd       : vid_ddr_rd;
assign ddr_we       = aud_grant ? aud_ddr_we       : vid_ddr_we;
assign ddr_addr     = aud_grant ? aud_ddr_addr     : vid_ddr_addr;
assign ddr_burstcnt = aud_grant ? aud_ddr_burstcnt : vid_ddr_burstcnt;
assign ddr_din      = aud_grant ? aud_ddr_din      : vid_ddr_din;

// ── Video Renderer ──────────────────────────────────────────────────
wire [7:0]  rend_r, rend_g, rend_b;
wire        rend_frame_ready;

mp_video_renderer renderer (
    .clk_vid        (clk_vid),
    .ce_pix         (ce_pix),
    .clk_sys        (clk_sys),
    .reset          (reset),

    .de             (tim_de),
    .hblank         (tim_hblank),
    .vblank         (tim_vblank),
    .new_frame      (tim_new_frame),
    .new_line       (tim_new_line),
    .hcount         (tim_hcount),
    .vcount         (tim_vcount),

    .ddr_rd         (vid_ddr_rd),
    .ddr_addr       (vid_ddr_addr),
    .ddr_burstcnt   (vid_ddr_burstcnt),
    .ddr_dout       (ddr_dout),
    .ddr_dout_ready (ddr_dout_ready & ~aud_grant),
    .ddr_we         (vid_ddr_we),
    .ddr_din        (vid_ddr_din),
    .ddr_busy       (ddr_busy),

    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_wait     (ioctl_wait),

    .joystick_0     (joystick_0),
    .joystick_l_analog_0 (joystick_l_analog_0),

    .aud_req        (aud_req),
    .aud_grant      (aud_grant),

    .r_out          (rend_r),
    .g_out          (rend_g),
    .b_out          (rend_b),

    .enable         (enable),
    .frame_ready    (rend_frame_ready)
);

// ── Audio Output ────────────────────────────────────────────────────
mp_audio_out audio (
    .clk_sys          (clk_sys),
    .clk_audio        (clk_audio),
    .reset            (reset),

    .aud_ddr_rd       (aud_ddr_rd),
    .aud_ddr_addr     (aud_ddr_addr),
    .aud_ddr_burstcnt (aud_ddr_burstcnt),
    .aud_ddr_dout     (ddr_dout),
    .aud_ddr_dout_ready (ddr_dout_ready & aud_grant),
    .aud_ddr_we       (aud_ddr_we),
    .aud_ddr_din      (aud_ddr_din),

    .aud_grant        (aud_grant),
    .aud_req          (aud_req),

    .audio_l          (audio_l),
    .audio_r          (audio_r),

    .audio_enable     (audio_enable),
    .buffer_level     ()
);

// ── Output assignments ──────────────────────────────────────────────
assign vga_r     = rend_r;
assign vga_g     = rend_g;
assign vga_b     = rend_b;
assign vga_hs    = tim_hsync;
assign vga_vs    = tim_vsync;
assign vga_de    = tim_de;
assign active    = enable & rend_frame_ready;
assign vsync_out = tim_vsync;

endmodule
