//============================================================================
//
//  Music Player — FPGA Video Renderer
//
//  Reads structured metadata and waveform data from DDR3 into BRAM during
//  vblank, then renders text and waveform on-the-fly during active video.
//
//  No framebuffer needed. ARM writes ~2KB of metadata per frame instead
//  of 150KB of pixels. Over 200x bandwidth reduction.
//
//  Screen layout (320x240):
//    y=4:   Title (2x scale, white)
//    y=20:  Artist (1x, cyan)
//    y=32:  Game/Album (1x, green)
//    y=48:  System / Track / Loop status (1x, gray)
//    y=58:  Time / Play status (1x, gray)
//    y=72:  Waveform oscilloscope (320x120, green+cyan)
//    y=204: Format info (1x, dim gray)
//    y=224: Controls help (1x, dim gray)
//
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

module mp_video_renderer (
    input  wire        clk_vid,      // 31.25 MHz video clock
    input  wire        ce_pix,       // pixel enable (7.8125 MHz)
    input  wire        clk_sys,      // 100 MHz DDR3 clock
    input  wire        reset,

    // Video timing inputs
    input  wire        de,
    input  wire        hblank,
    input  wire        vblank,
    input  wire        new_frame,
    input  wire        new_line,
    input  wire  [9:0] hcount,
    input  wire  [8:0] vcount,

    // DDR3 interface (active during vblank)
    output reg         ddr_rd,
    output reg  [28:0] ddr_addr,
    output reg   [7:0] ddr_burstcnt,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready,
    output reg         ddr_we,
    output reg  [63:0] ddr_din,
    input  wire        ddr_busy,

    // File loading (ioctl passthrough)
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    output wire        ioctl_wait,

    // Joystick forwarding
    input  wire [31:0] joystick_0,
    input  wire [15:0] joystick_l_analog_0,

    // Audio grant interface
    input  wire        aud_req,
    output reg         aud_grant,

    // Pixel output
    output reg   [7:0] r_out,
    output reg   [7:0] g_out,
    output reg   [7:0] b_out,

    // Control
    input  wire        enable,
    output reg         frame_ready
);

// ── DDR3 Addresses (physical >> 3) ──────────────────────────────────
localparam [28:0] CTRL_ADDR     = 29'h07400000;  // 0x3A000000
localparam [28:0] JOY_ADDR      = 29'h07400001;  // 0x3A000008
localparam [28:0] FILE_CTRL     = 29'h07400002;  // 0x3A000010
localparam [28:0] STATE_ADDR    = 29'h07400003;  // 0x3A000018
localparam [28:0] TIME_ADDR     = 29'h07400004;  // 0x3A000020
localparam [28:0] FMT_ADDR      = 29'h07400005;  // 0x3A000028
localparam [28:0] TITLE_ADDR    = 29'h07400006;  // 0x3A000030 (8 qwords = 64 bytes)
localparam [28:0] ARTIST_ADDR   = 29'h0740000E;  // 0x3A000070
localparam [28:0] GAME_ADDR     = 29'h07400016;  // 0x3A0000B0
localparam [28:0] SYSTEM_ADDR   = 29'h0740001E;  // 0x3A0000F0 (2 qwords = 16 bytes)
localparam [28:0] WAVE_L_ADDR   = 29'h07400020;  // 0x3A000100 (80 qwords = 640 bytes)
localparam [28:0] WAVE_R_ADDR   = 29'h07400070;  // 0x3A000380
localparam [28:0] FILE_DATA_ADDR = 29'h07400920;  // 0x3A004900

// ── Color Palette (RGB565) ──────────────────────────────────────────
localparam [15:0] COL_BG        = 16'h0000;  // black
localparam [15:0] COL_TITLE     = 16'hFFFF;  // white
localparam [15:0] COL_ARTIST    = 16'h07FF;  // cyan
localparam [15:0] COL_GAME      = 16'h07E0;  // green
localparam [15:0] COL_INFO      = 16'hBDF7;  // light gray
localparam [15:0] COL_DIM       = 16'h7BEF;  // dim gray
localparam [15:0] COL_WAVE_L    = 16'h07E0;  // green
localparam [15:0] COL_WAVE_R    = 16'h07FF;  // cyan
localparam [15:0] COL_CENTER    = 16'h4208;  // dark gray
localparam [15:0] COL_PLAY      = 16'h07E0;  // green
localparam [15:0] COL_PAUSE     = 16'hFFE0;  // yellow
localparam [15:0] COL_BORDER    = 16'h2104;  // very dark gray

// ── BRAM: Metadata strings ──────────────────────────────────────────
reg [7:0] title_buf  [0:63];
reg [7:0] artist_buf [0:63];
reg [7:0] game_buf   [0:63];
reg [7:0] system_buf [0:15];

// ── BRAM: Playback state ────────────────────────────────────────────
reg [7:0]  state_flags;
reg [7:0]  current_track;
reg [7:0]  total_tracks;
reg [31:0] elapsed_ms;
reg [31:0] duration_ms;
reg [7:0]  format_id;
reg [31:0] sample_rate;
reg [7:0]  channels;

// ── BRAM: Waveform (320 samples per channel) ────────────────────────
reg signed [15:0] wave_l [0:319];
reg signed [15:0] wave_r [0:319];

// ── Frame counter tracking ──────────────────────────────────────────
reg [31:0] ctrl_word;
reg [29:0] prev_frame_counter;
reg        data_loaded;

// ── DDR3 vblank read state machine ──────────────────────────────────
localparam [3:0] VB_IDLE       = 4'd0;
localparam [3:0] VB_WRITE_JOY  = 4'd1;
localparam [3:0] VB_READ_CTRL  = 4'd2;
localparam [3:0] VB_WAIT_CTRL  = 4'd3;
localparam [3:0] VB_READ_STATE = 4'd4;
localparam [3:0] VB_WAIT_STATE = 4'd5;
localparam [3:0] VB_READ_STRS  = 4'd6;
localparam [3:0] VB_WAIT_STRS  = 4'd7;
localparam [3:0] VB_READ_WAVE  = 4'd8;
localparam [3:0] VB_WAIT_WAVE  = 4'd9;
localparam [3:0] VB_WRITE_FILE = 4'd10;
localparam [3:0] VB_WRITE_FSIZ = 4'd11;
localparam [3:0] VB_AUD_GRANT  = 4'd12;
localparam [3:0] VB_DONE       = 4'd13;

reg [3:0]  vb_state;
reg [7:0]  beat_cnt;
reg [28:0] read_addr;
reg [8:0]  bram_idx;
reg [1:0]  str_phase;    // 0=title, 1=artist, 2=game, 3=system
reg        wave_channel; // 0=L, 1=R

// ── CDC synchronizers ───────────────────────────────────────────────
reg [1:0] new_frame_sync;
always @(posedge clk_sys) begin
    if (reset) new_frame_sync <= 2'b0;
    else       new_frame_sync <= {new_frame_sync[0], new_frame};
end
wire new_frame_sys = ~new_frame_sync[1] & new_frame_sync[0];

reg new_frame_pending;

reg [1:0] enable_sync;
always @(posedge clk_sys) begin
    if (reset) enable_sync <= 2'b0;
    else       enable_sync <= {enable_sync[0], enable};
end
wire enable_sys = enable_sync[1];

// ── File loading (ioctl byte collection) ────────────────────────────
reg  [63:0] file_buf;
reg   [2:0] file_byte_cnt;
reg         file_write_pending;
reg  [28:0] file_write_addr;
reg  [63:0] file_write_data;
reg         file_size_pending;
reg  [26:0] file_total_bytes;
reg         file_dl_prev;
reg         file_loading;

assign ioctl_wait = file_write_pending & ioctl_download;

// ── DDR3 vblank state machine ───────────────────────────────────────
always @(posedge clk_sys) begin
    if (reset) begin
        vb_state           <= VB_IDLE;
        ddr_rd             <= 1'b0;
        ddr_we             <= 1'b0;
        ddr_din            <= 64'd0;
        ddr_addr           <= 29'd0;
        ddr_burstcnt       <= 8'd1;
        ctrl_word          <= 32'd0;
        prev_frame_counter <= 30'd0;
        data_loaded        <= 1'b0;
        frame_ready        <= 1'b0;
        new_frame_pending  <= 1'b0;
        beat_cnt           <= 8'd0;
        bram_idx           <= 9'd0;
        str_phase          <= 2'd0;
        wave_channel       <= 1'b0;
        aud_grant          <= 1'b0;
        state_flags        <= 8'd0;
        current_track      <= 8'd0;
        total_tracks       <= 8'd0;
        elapsed_ms         <= 32'd0;
        duration_ms        <= 32'd0;
        format_id          <= 8'd0;
        sample_rate        <= 32'd0;
        channels           <= 8'd0;
        file_buf           <= 64'd0;
        file_byte_cnt      <= 3'd0;
        file_write_pending <= 1'b0;
        file_write_addr    <= FILE_DATA_ADDR;
        file_write_data    <= 64'd0;
        file_size_pending  <= 1'b0;
        file_total_bytes   <= 27'd0;
        file_dl_prev       <= 1'b0;
        file_loading       <= 1'b0;
    end
    else begin
        ddr_rd    <= 1'b0;
        ddr_we    <= 1'b0;
        aud_grant <= 1'b0;

        if (new_frame_sys)
            new_frame_pending <= 1'b1;

        // ── ioctl file byte collector ──
        if (ioctl_download && ioctl_wr) begin
            file_loading <= 1'b1;
            file_buf <= {ioctl_dout, file_buf[63:8]};
            file_byte_cnt <= file_byte_cnt + 3'd1;
            file_total_bytes <= ioctl_addr + 27'd1;
            if (file_byte_cnt == 3'd7) begin
                file_write_pending <= 1'b1;
                file_write_data <= {ioctl_dout, file_buf[63:8]};
                file_write_addr <= FILE_DATA_ADDR + {2'd0, ioctl_addr[26:3]};
                file_byte_cnt <= 3'd0;
            end
        end
        file_dl_prev <= ioctl_download;
        if (file_dl_prev && !ioctl_download && file_loading) begin
            if (file_byte_cnt != 3'd0) begin
                file_write_pending <= 1'b1;
                file_write_data <= file_buf;
                file_write_addr <= FILE_DATA_ADDR + {2'd0, file_total_bytes[26:3]};
            end
            file_size_pending <= 1'b1;
            file_loading <= 1'b0;
            file_byte_cnt <= 3'd0;
        end

        // ── Main state machine ──
        case (vb_state)
            VB_IDLE: begin
                if (!enable_sys) begin
                    frame_ready <= 1'b0;
                end
                else if (file_write_pending && !ddr_busy) begin
                    ddr_addr     <= file_write_addr;
                    ddr_din      <= file_write_data;
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    file_write_pending <= 1'b0;
                    vb_state     <= VB_WRITE_FILE;
                end
                else if (file_size_pending && !ddr_busy) begin
                    ddr_addr     <= FILE_CTRL;
                    ddr_din      <= {32'd0, 5'd0, file_total_bytes};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    file_size_pending <= 1'b0;
                    vb_state     <= VB_WRITE_FSIZ;
                end
                else if (aud_req) begin
                    aud_grant <= 1'b1;
                    vb_state  <= VB_AUD_GRANT;
                end
                else if (new_frame_pending) begin
                    new_frame_pending <= 1'b0;
                    vb_state <= VB_WRITE_JOY;
                end
            end

            VB_WRITE_FILE: vb_state <= VB_IDLE;
            VB_WRITE_FSIZ: vb_state <= VB_IDLE;

            VB_AUD_GRANT: begin
                // Hold grant for audio module, release when it drops req
                if (!aud_req) begin
                    aud_grant <= 1'b0;
                    vb_state  <= VB_IDLE;
                end
                else
                    aud_grant <= 1'b1;
            end

            VB_WRITE_JOY: begin
                if (!ddr_busy) begin
                    ddr_addr     <= JOY_ADDR;
                    ddr_din      <= {16'd0, joystick_l_analog_0, joystick_0};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    vb_state     <= VB_READ_CTRL;
                end
            end

            VB_READ_CTRL: begin
                if (!ddr_busy) begin
                    ddr_addr     <= CTRL_ADDR;
                    ddr_burstcnt <= 8'd1;
                    ddr_rd       <= 1'b1;
                    vb_state     <= VB_WAIT_CTRL;
                end
            end

            VB_WAIT_CTRL: begin
                if (ddr_dout_ready) begin
                    ctrl_word <= ddr_dout[31:0];
                    if (ddr_dout[31:2] != prev_frame_counter || !data_loaded) begin
                        prev_frame_counter <= ddr_dout[31:2];
                        vb_state <= VB_READ_STATE;
                    end
                    else begin
                        // No new frame from ARM — skip metadata read
                        frame_ready <= data_loaded;
                        vb_state <= VB_DONE;
                    end
                end
            end

            VB_READ_STATE: begin
                // Burst read: state + time + format = 3 qwords
                if (!ddr_busy) begin
                    ddr_addr     <= STATE_ADDR;
                    ddr_burstcnt <= 8'd3;
                    ddr_rd       <= 1'b1;
                    beat_cnt     <= 8'd0;
                    vb_state     <= VB_WAIT_STATE;
                end
            end

            VB_WAIT_STATE: begin
                if (ddr_dout_ready) begin
                    case (beat_cnt)
                        8'd0: begin  // Playback state
                            state_flags   <= ddr_dout[7:0];
                            current_track <= ddr_dout[15:8];
                            total_tracks  <= ddr_dout[23:16];
                        end
                        8'd1: begin  // Timing
                            elapsed_ms <= ddr_dout[31:0];
                            duration_ms <= ddr_dout[63:32];
                        end
                        8'd2: begin  // Format
                            sample_rate <= ddr_dout[31:0];
                            channels    <= ddr_dout[39:32];
                            format_id   <= ddr_dout[47:40];
                        end
                    endcase
                    beat_cnt <= beat_cnt + 8'd1;
                    if (beat_cnt == 8'd2) begin
                        str_phase <= 2'd0;
                        vb_state  <= VB_READ_STRS;
                    end
                end
            end

            VB_READ_STRS: begin
                // Read strings: title(8qw) + artist(8qw) + game(8qw) + system(2qw)
                if (!ddr_busy) begin
                    case (str_phase)
                        2'd0: begin ddr_addr <= TITLE_ADDR;  ddr_burstcnt <= 8'd8; end
                        2'd1: begin ddr_addr <= ARTIST_ADDR; ddr_burstcnt <= 8'd8; end
                        2'd2: begin ddr_addr <= GAME_ADDR;   ddr_burstcnt <= 8'd8; end
                        2'd3: begin ddr_addr <= SYSTEM_ADDR; ddr_burstcnt <= 8'd2; end
                    endcase
                    ddr_rd   <= 1'b1;
                    beat_cnt <= 8'd0;
                    bram_idx <= 9'd0;
                    vb_state <= VB_WAIT_STRS;
                end
            end

            VB_WAIT_STRS: begin
                if (ddr_dout_ready) begin
                    // Each qword = 8 characters
                    case (str_phase)
                        2'd0: begin
                            title_buf[{beat_cnt[2:0], 3'd0}] <= ddr_dout[7:0];
                            title_buf[{beat_cnt[2:0], 3'd1}] <= ddr_dout[15:8];
                            title_buf[{beat_cnt[2:0], 3'd2}] <= ddr_dout[23:16];
                            title_buf[{beat_cnt[2:0], 3'd3}] <= ddr_dout[31:24];
                            title_buf[{beat_cnt[2:0], 3'd4}] <= ddr_dout[39:32];
                            title_buf[{beat_cnt[2:0], 3'd5}] <= ddr_dout[47:40];
                            title_buf[{beat_cnt[2:0], 3'd6}] <= ddr_dout[55:48];
                            title_buf[{beat_cnt[2:0], 3'd7}] <= ddr_dout[63:56];
                        end
                        2'd1: begin
                            artist_buf[{beat_cnt[2:0], 3'd0}] <= ddr_dout[7:0];
                            artist_buf[{beat_cnt[2:0], 3'd1}] <= ddr_dout[15:8];
                            artist_buf[{beat_cnt[2:0], 3'd2}] <= ddr_dout[23:16];
                            artist_buf[{beat_cnt[2:0], 3'd3}] <= ddr_dout[31:24];
                            artist_buf[{beat_cnt[2:0], 3'd4}] <= ddr_dout[39:32];
                            artist_buf[{beat_cnt[2:0], 3'd5}] <= ddr_dout[47:40];
                            artist_buf[{beat_cnt[2:0], 3'd6}] <= ddr_dout[55:48];
                            artist_buf[{beat_cnt[2:0], 3'd7}] <= ddr_dout[63:56];
                        end
                        2'd2: begin
                            game_buf[{beat_cnt[2:0], 3'd0}] <= ddr_dout[7:0];
                            game_buf[{beat_cnt[2:0], 3'd1}] <= ddr_dout[15:8];
                            game_buf[{beat_cnt[2:0], 3'd2}] <= ddr_dout[23:16];
                            game_buf[{beat_cnt[2:0], 3'd3}] <= ddr_dout[31:24];
                            game_buf[{beat_cnt[2:0], 3'd4}] <= ddr_dout[39:32];
                            game_buf[{beat_cnt[2:0], 3'd5}] <= ddr_dout[47:40];
                            game_buf[{beat_cnt[2:0], 3'd6}] <= ddr_dout[55:48];
                            game_buf[{beat_cnt[2:0], 3'd7}] <= ddr_dout[63:56];
                        end
                        2'd3: begin
                            system_buf[{beat_cnt[0], 3'd0}] <= ddr_dout[7:0];
                            system_buf[{beat_cnt[0], 3'd1}] <= ddr_dout[15:8];
                            system_buf[{beat_cnt[0], 3'd2}] <= ddr_dout[23:16];
                            system_buf[{beat_cnt[0], 3'd3}] <= ddr_dout[31:24];
                            system_buf[{beat_cnt[0], 3'd4}] <= ddr_dout[39:32];
                            system_buf[{beat_cnt[0], 3'd5}] <= ddr_dout[47:40];
                            system_buf[{beat_cnt[0], 3'd6}] <= ddr_dout[55:48];
                            system_buf[{beat_cnt[0], 3'd7}] <= ddr_dout[63:56];
                        end
                    endcase

                    beat_cnt <= beat_cnt + 8'd1;

                    // Check if this string phase is done
                    begin
                        reg phase_done;
                        case (str_phase)
                            2'd0: phase_done = (beat_cnt == 8'd7);
                            2'd1: phase_done = (beat_cnt == 8'd7);
                            2'd2: phase_done = (beat_cnt == 8'd7);
                            2'd3: phase_done = (beat_cnt == 8'd1);
                            default: phase_done = 1'b1;
                        endcase

                        if (phase_done) begin
                            if (str_phase == 2'd3) begin
                                wave_channel <= 1'b0;
                                vb_state <= VB_READ_WAVE;
                            end
                            else begin
                                str_phase <= str_phase + 2'd1;
                                vb_state  <= VB_READ_STRS;
                            end
                        end
                    end
                end
            end

            VB_READ_WAVE: begin
                // Read waveform: 320 samples * 2 bytes = 640 bytes = 80 qwords per channel
                if (!ddr_busy) begin
                    ddr_addr     <= wave_channel ? WAVE_R_ADDR : WAVE_L_ADDR;
                    ddr_burstcnt <= 8'd80;
                    ddr_rd       <= 1'b1;
                    beat_cnt     <= 8'd0;
                    bram_idx     <= 9'd0;
                    vb_state     <= VB_WAIT_WAVE;
                end
            end

            VB_WAIT_WAVE: begin
                if (ddr_dout_ready) begin
                    // Each qword = 4 int16_t samples
                    if (!wave_channel) begin
                        wave_l[{beat_cnt[6:0], 2'd0}] <= $signed(ddr_dout[15:0]);
                        wave_l[{beat_cnt[6:0], 2'd1}] <= $signed(ddr_dout[31:16]);
                        wave_l[{beat_cnt[6:0], 2'd2}] <= $signed(ddr_dout[47:32]);
                        wave_l[{beat_cnt[6:0], 2'd3}] <= $signed(ddr_dout[63:48]);
                    end
                    else begin
                        wave_r[{beat_cnt[6:0], 2'd0}] <= $signed(ddr_dout[15:0]);
                        wave_r[{beat_cnt[6:0], 2'd1}] <= $signed(ddr_dout[31:16]);
                        wave_r[{beat_cnt[6:0], 2'd2}] <= $signed(ddr_dout[47:32]);
                        wave_r[{beat_cnt[6:0], 2'd3}] <= $signed(ddr_dout[63:48]);
                    end

                    beat_cnt <= beat_cnt + 8'd1;
                    if (beat_cnt == 8'd79) begin
                        if (!wave_channel) begin
                            wave_channel <= 1'b1;
                            vb_state <= VB_READ_WAVE;
                        end
                        else begin
                            data_loaded <= 1'b1;
                            frame_ready <= 1'b1;
                            vb_state    <= VB_DONE;
                        end
                    end
                end
            end

            VB_DONE: begin
                vb_state <= VB_IDLE;
            end

            default: vb_state <= VB_IDLE;
        endcase
    end
end

// ── Pixel rendering (clk_vid domain) ────────────────────────────────
// This section runs purely from BRAM — no DDR3 access during scanlines.

// Reset synchronizer for clk_vid
reg [1:0] reset_vid_sync;
always @(posedge clk_vid or posedge reset)
    if (reset) reset_vid_sync <= 2'b11;
    else       reset_vid_sync <= {reset_vid_sync[0], 1'b0};
wire reset_vid = reset_vid_sync[1];

// CDC: frame_ready to clk_vid
reg [1:0] fr_sync;
always @(posedge clk_vid) begin
    if (reset_vid) fr_sync <= 2'b0;
    else           fr_sync <= {fr_sync[0], frame_ready};
end
wire frame_ready_vid = fr_sync[1];

// Font ROM instance
wire [3:0] font_pixels;
reg  [6:0] font_char;
reg  [2:0] font_row;

mp_font_rom font (
    .clk       (clk_vid),
    .char_code (font_char),
    .row       (font_row),
    .pixels    (font_pixels)
);

// ── Scanline-based pixel generation ─────────────────────────────────
// Regions:
//   y=4..15:   Title (2x scale, 12px tall = 6 font rows * 2)
//   y=20..25:  Artist (1x)
//   y=32..37:  Game (1x)
//   y=48..53:  Info line 1 (system, track, loop)
//   y=58..63:  Info line 2 (time, play status)
//   y=72..191: Waveform (120px)
//   y=204..209: Format info
//   y=224..229: Controls help

wire [8:0] y = vcount;
wire [9:0] x = hcount;

// Character position within a text line
wire [5:0] char_col_1x = x[9:0] / 10'd5;        // 1x: 5px per char
wire [2:0] pix_in_char_1x = x % 5;               // 0-4 within char cell
wire [5:0] char_col_2x = x[9:0] / 10'd10;        // 2x: 10px per char
wire [3:0] pix_in_char_2x = x % 10;              // 0-9 within char cell

// Current pixel color (RGB565)
reg [15:0] pixel_color;

// Text character lookup (one cycle ahead for font ROM latency)
// Simplified: determine what character to display based on y position
always @(posedge clk_vid) begin
    if (reset_vid) begin
        font_char <= 7'h20;
        font_row  <= 3'd0;
    end
    else if (ce_pix) begin
        // Default: space
        font_char <= 7'h20;
        font_row  <= 3'd0;

        if (y >= 9'd4 && y < 9'd16) begin
            // Title (2x scale)
            font_char <= (char_col_2x < 6'd32) ? {1'b0, title_buf[char_col_2x][6:0]} : 7'h20;
            font_row  <= y[3:1] - 3'd2;  // (y-4)/2
        end
        else if (y >= 9'd20 && y < 9'd26) begin
            // Artist (1x)
            font_char <= (char_col_1x < 6'd63) ? {1'b0, artist_buf[char_col_1x][6:0]} : 7'h20;
            font_row  <= y[2:0] - 3'd4;  // y-20
        end
        else if (y >= 9'd32 && y < 9'd38) begin
            // Game (1x)
            font_char <= (char_col_1x < 6'd63) ? {1'b0, game_buf[char_col_1x][6:0]} : 7'h20;
            font_row  <= y[2:0];  // y-32
        end
    end
end

// Waveform rendering
wire in_wave_region = (y >= 9'd72 && y < 9'd192);
wire [6:0] wave_y = y - 9'd72;         // 0..119
wire [8:0] wave_x = x[8:0];            // 0..319
wire wave_center = (wave_y == 7'd60);   // center line at y=132
wire wave_top_half = (wave_y < 7'd60);  // L channel region
wire wave_bot_half = (wave_y > 7'd60);  // R channel region

// Map waveform sample to pixel position
// Sample range: -32768..+32767 -> map to ±56 pixels from center
wire signed [15:0] cur_wave_l = (wave_x < 9'd320) ? wave_l[wave_x] : 16'sd0;
wire signed [15:0] cur_wave_r = (wave_x < 9'd320) ? wave_r[wave_x] : 16'sd0;

// Scale sample to ±56 pixel range: sample * 56 / 32768 = sample >>> 9 (approx)
wire signed [7:0] wave_l_offset = cur_wave_l[15:9];  // ÷512, gives ±63
wire signed [7:0] wave_r_offset = cur_wave_r[15:9];

// Y position of waveform bar endpoint (from center line at 60)
// Negative sample = bar goes up (lower y), positive = bar goes down
wire [6:0] wave_l_y = 7'd60 - wave_l_offset[6:0];
wire [6:0] wave_r_y = 7'd60 + wave_r_offset[6:0];

// Is this pixel inside the L waveform bar?
wire in_wave_l = wave_top_half && (
    (wave_l_offset < 0) ? (wave_y >= wave_l_y && wave_y < 7'd60) :
    (wave_l_offset > 0) ? (wave_y >= 7'd60 && wave_y <= wave_l_y) : 1'b0
);

// Is this pixel inside the R waveform bar?
wire in_wave_r = wave_bot_half && (
    (wave_r_offset > 0) ? (wave_y <= wave_r_y && wave_y > 7'd60) :
    (wave_r_offset < 0) ? (wave_y <= 7'd60 && wave_y >= wave_r_y) : 1'b0
);

// ── Final pixel output ──────────────────────────────────────────────
always @(posedge clk_vid) begin
    if (reset_vid) begin
        r_out <= 8'd0;
        g_out <= 8'd0;
        b_out <= 8'd0;
    end
    else if (ce_pix) begin
        if (de && frame_ready_vid) begin
            // Default: background
            pixel_color = COL_BG;

            // Text regions (check font_pixels from ROM)
            if (y >= 9'd4 && y < 9'd16) begin
                // Title (2x scale) — check if pixel is within the 2x char
                if (pix_in_char_2x < 4'd8 && font_pixels[3 - pix_in_char_2x[2:1]])
                    pixel_color = COL_TITLE;
            end
            else if (y >= 9'd20 && y < 9'd26) begin
                if (pix_in_char_1x < 3'd4 && font_pixels[3 - pix_in_char_1x[1:0]])
                    pixel_color = COL_ARTIST;
            end
            else if (y >= 9'd32 && y < 9'd38) begin
                if (pix_in_char_1x < 3'd4 && font_pixels[3 - pix_in_char_1x[1:0]])
                    pixel_color = COL_GAME;
            end
            // Waveform region
            else if (in_wave_region) begin
                if (wave_center)
                    pixel_color = COL_CENTER;
                else if (in_wave_l)
                    pixel_color = COL_WAVE_L;
                else if (in_wave_r)
                    pixel_color = COL_WAVE_R;
            end

            // RGB565 to RGB888
            r_out <= {pixel_color[15:11], pixel_color[15:13]};
            g_out <= {pixel_color[10:5],  pixel_color[10:9]};
            b_out <= {pixel_color[4:0],   pixel_color[4:2]};
        end
        else begin
            r_out <= 8'd0;
            g_out <= 8'd0;
            b_out <= 8'd0;
        end
    end
end

endmodule
