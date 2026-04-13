//============================================================================
//
//  Music Player Native Video DDR3 Reader
//
//  Reads 320x240 RGB565 frames from DDR3 and outputs pixels directly
//  (no scaling -- 1:1 mapping from source to display).
//
//  DDR3 Memory Map (physical addresses):
//    0x3A000000 + 0x000    : Control word (frame_counter[31:2], active_buffer[1:0])
//    0x3A000000 + 0x008    : Joystick data (FPGA writes for ARM to read)
//    0x3A000000 + 0x010    : File control (file size from ioctl, ARM reads+acks)
//    0x3A000000 + 0x100    : Buffer 0 (320*240*2 = 153,600 bytes)
//    0x3A000000 + 0x25900  : Buffer 1 (153,600 bytes)
//    0x3A000000 + 0x4B200  : File data area (up to 256KB for music files)
//
//  Bandwidth: 150KB x 2 (double buffer) x 60fps = 17.6 MB/s (DDR3 can do >1000)
//
//  Adapted from PICO-8 pico8_video_reader.sv
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

module mp_video_reader (
    // DDR3 Avalon-MM master
    input  wire        ddr_clk,
    input  wire        ddr_busy,
    output reg   [7:0] ddr_burstcnt,
    output reg  [28:0] ddr_addr,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready,
    output reg         ddr_rd,
    output reg  [63:0] ddr_din,
    output wire  [7:0] ddr_be,
    output reg         ddr_we,

    // Pixel output (clk_vid domain)
    input  wire        clk_vid,
    input  wire        ce_pix,
    input  wire        reset,

    // Timing inputs (from mp_video_timing)
    input  wire        de,
    input  wire        hblank,
    input  wire        vblank,
    input  wire        new_frame,
    input  wire        new_line,
    input  wire  [8:0] vcount,

    // File loading via ioctl (from hps_io)
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    output wire        ioctl_wait,

    // Joystick input (from hps_io, clk_sys domain = ddr_clk domain)
    input  wire [31:0] joystick_0,
    input  wire [15:0] joystick_l_analog_0,

    // Pixel output
    output reg   [7:0] r_out,
    output reg   [7:0] g_out,
    output reg   [7:0] b_out,

    // Control
    input  wire        enable,
    output wire        frame_ready
);

// DDR3 byte enable (always all bytes)
assign ddr_be = 8'hFF;

// -- DDR3 Address Constants ------------------------------------------------
// 29-bit qword addresses = physical >> 3
// Buffer sizes: 320*240*2 = 153,600 bytes = 0x25800
localparam [28:0] CTRL_ADDR      = 29'h07400000;  // 0x3A000000 >> 3
localparam [28:0] JOY_ADDR       = 29'h07400001;  // 0x3A000008 >> 3
localparam [28:0] FILE_CTRL_ADDR = 29'h07400002;  // 0x3A000010 >> 3
localparam [28:0] BUF0_ADDR      = 29'h07400020;  // 0x3A000100 >> 3
localparam [28:0] BUF1_ADDR      = 29'h0740B320;  // 0x3A059900 >> 3 (BUF0 + 153600/8)

// File data starts after both video buffers
localparam [28:0] FILE_DATA_ADDR = 29'h07416640;  // 0x3A0B3200 >> 3
localparam [28:0] FILE_MAX_SIZE  = 29'h00040000;  // 256KB max

// 320px line: 320 * 2 bytes / 8 = 80 qwords per line
localparam [7:0]  LINE_BURST     = 8'd80;
localparam [28:0] LINE_STRIDE    = 29'd80;        // 80 qword addresses per line
localparam [8:0]  V_ACTIVE       = 9'd240;        // display lines

localparam [19:0] TIMEOUT_MAX    = 20'hF_FFFF;

// -- Enable synchronizer --------------------------------------------------
reg [1:0] enable_sync;
always @(posedge ddr_clk) begin
    if (reset) enable_sync <= 2'b0;
    else       enable_sync <= {enable_sync[0], enable};
end
wire enable_ddr = enable_sync[1];

// -- CDC: new_frame --------------------------------------------------------
reg [1:0] new_frame_sync;
always @(posedge ddr_clk) begin
    if (reset) new_frame_sync <= 2'b0;
    else       new_frame_sync <= {new_frame_sync[0], new_frame};
end
wire new_frame_ddr = ~new_frame_sync[1] & new_frame_sync[0];

reg new_frame_pending;
reg synced;

// -- CDC: new_line ---------------------------------------------------------
reg [1:0] new_line_sync;
always @(posedge ddr_clk) begin
    if (reset) new_line_sync <= 2'b0;
    else       new_line_sync <= {new_line_sync[0], new_line};
end
wire new_line_ddr = ~new_line_sync[1] & new_line_sync[0];

// -- CDC: vblank level -----------------------------------------------------
reg [1:0] vblank_sync;
always @(posedge ddr_clk) begin
    if (reset) vblank_sync <= 2'b0;
    else       vblank_sync <= {vblank_sync[0], vblank};
end
wire vblank_ddr = vblank_sync[1];

// -- Reset synchronizer for clk_vid ---------------------------------------
reg [1:0] reset_vid_sync;
always @(posedge clk_vid or posedge reset)
    if (reset) reset_vid_sync <= 2'b11;
    else       reset_vid_sync <= {reset_vid_sync[0], 1'b0};
wire reset_vid = reset_vid_sync[1];

// -- CDC: frame_ready ------------------------------------------------------
reg frame_ready_reg;
reg [1:0] frame_ready_sync;
always @(posedge clk_vid) begin
    if (reset_vid) frame_ready_sync <= 2'b0;
    else           frame_ready_sync <= {frame_ready_sync[0], frame_ready_reg};
end
wire frame_ready_vid = frame_ready_sync[1];
assign frame_ready = frame_ready_vid;

// -- DDR3 Read State Machine -----------------------------------------------
localparam [3:0] ST_IDLE            = 4'd0;
localparam [3:0] ST_POLL_CTRL       = 4'd1;
localparam [3:0] ST_WAIT_CTRL       = 4'd2;
localparam [3:0] ST_CHECK_CTRL      = 4'd3;
localparam [3:0] ST_READ_LINE       = 4'd4;
localparam [3:0] ST_WAIT_LINE       = 4'd5;
localparam [3:0] ST_LINE_DONE       = 4'd6;
localparam [3:0] ST_WAIT_DISPLAY    = 4'd7;
localparam [3:0] ST_WRITE_JOY       = 4'd8;
localparam [3:0] ST_WRITE_FILE      = 4'd9;
localparam [3:0] ST_WRITE_FILE_SIZE = 4'd10;

reg  [3:0]  state;
reg  [31:0] ctrl_word;
reg  [29:0] prev_frame_counter;
reg         active_buffer;
reg  [28:0] buf_base_addr;
reg  [8:0]  display_line;
reg  [6:0]  beat_count;
reg         first_frame_loaded;
reg  [4:0]  stale_vblank_count;
reg         preloading;
reg  [19:0] timeout_cnt;

// File loading registers
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

// -- FIFO write signals ---------------------------------------------------
reg         fifo_wr;
reg  [63:0] fifo_wr_data;
wire        fifo_full;

// -- FIFO async clear -----------------------------------------------------
reg [3:0] fifo_aclr_cnt;
wire fifo_aclr_ddr_active = (fifo_aclr_cnt != 4'd0);
wire fifo_aclr = reset | fifo_aclr_ddr_active;

// -- Main state machine ---------------------------------------------------
always @(posedge ddr_clk) begin
    if (reset) begin
        state              <= ST_IDLE;
        ddr_rd             <= 1'b0;
        ddr_we             <= 1'b0;
        ddr_din            <= 64'd0;
        ddr_burstcnt       <= 8'd1;
        ddr_addr           <= 29'd0;
        ctrl_word          <= 32'd0;
        prev_frame_counter <= 30'd0;
        active_buffer      <= 1'b0;
        buf_base_addr      <= 29'd0;
        display_line       <= 9'd0;
        beat_count         <= 7'd0;
        first_frame_loaded <= 1'b0;
        frame_ready_reg    <= 1'b0;
        stale_vblank_count <= 5'd0;
        preloading         <= 1'b0;
        timeout_cnt        <= 20'd0;
        new_frame_pending  <= 1'b0;
        synced             <= 1'b0;
        fifo_wr            <= 1'b0;
        fifo_wr_data       <= 64'd0;
        fifo_aclr_cnt      <= 4'd0;
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
        ddr_rd <= 1'b0;
        ddr_we <= 1'b0;
        fifo_wr <= 1'b0;

        if (fifo_aclr_cnt != 4'd0)
            fifo_aclr_cnt <= fifo_aclr_cnt - 4'd1;

        // Latch new_frame
        if (new_frame_ddr)
            new_frame_pending <= 1'b1;

        // -- ioctl file byte collector (runs every cycle) --
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

        // Detect download end -> write final partial qword + size
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

        // -- State machine --
        case (state)
            ST_IDLE: begin
                if (!enable_ddr) begin
                    frame_ready_reg <= 1'b0;
                end
                else if (file_write_pending && !ddr_busy) begin
                    ddr_addr     <= file_write_addr;
                    ddr_din      <= file_write_data;
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    file_write_pending <= 1'b0;
                    state        <= ST_WRITE_FILE;
                end
                else if (file_size_pending && !ddr_busy) begin
                    ddr_addr     <= FILE_CTRL_ADDR;
                    ddr_din      <= {32'd0, 5'd0, file_total_bytes};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    file_size_pending <= 1'b0;
                    state        <= ST_WRITE_FILE_SIZE;
                end
                else if (new_frame_pending) begin
                    new_frame_pending <= 1'b0;
                    state <= ST_WRITE_JOY;
                end
            end

            ST_WRITE_JOY: begin
                if (!ddr_busy) begin
                    ddr_addr     <= JOY_ADDR;
                    ddr_din      <= {16'd0, joystick_l_analog_0, joystick_0};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    state        <= ST_POLL_CTRL;
                end
            end

            ST_WRITE_FILE: begin
                state <= ST_IDLE;
            end

            ST_WRITE_FILE_SIZE: begin
                state <= ST_IDLE;
            end

            ST_POLL_CTRL: begin
                if (!ddr_busy) begin
                    ddr_addr     <= CTRL_ADDR;
                    ddr_burstcnt <= 8'd1;
                    ddr_rd       <= 1'b1;
                    timeout_cnt  <= 20'd0;
                    state        <= ST_WAIT_CTRL;
                end
            end

            ST_WAIT_CTRL: begin
                if (ddr_dout_ready) begin
                    ctrl_word <= ddr_dout[31:0];
                    state <= ST_CHECK_CTRL;
                end
                else if (timeout_cnt == TIMEOUT_MAX)
                    state <= ST_IDLE;
                else
                    timeout_cnt <= timeout_cnt + 20'd1;
            end

            ST_CHECK_CTRL: begin
                if (!synced) begin
                    prev_frame_counter <= ctrl_word[31:2];
                    synced <= 1'b1;
                    state <= ST_IDLE;
                end
                else if (ctrl_word[31:2] != prev_frame_counter) begin
                    prev_frame_counter <= ctrl_word[31:2];
                    active_buffer      <= ctrl_word[0];
                    stale_vblank_count <= 5'd0;
                    buf_base_addr      <= ctrl_word[0] ? BUF1_ADDR : BUF0_ADDR;
                    display_line       <= 9'd0;
                    preloading         <= 1'b1;
                    fifo_aclr_cnt      <= 4'd8;
                    state              <= ST_READ_LINE;
                end
                else if (first_frame_loaded) begin
                    if (stale_vblank_count < 5'd30)
                        stale_vblank_count <= stale_vblank_count + 5'd1;
                    if (stale_vblank_count >= 5'd29)
                        frame_ready_reg <= 1'b0;
                    display_line  <= 9'd0;
                    preloading    <= 1'b1;
                    fifo_aclr_cnt <= 4'd8;
                    state         <= ST_READ_LINE;
                end
                else
                    state <= ST_IDLE;
            end

            ST_READ_LINE: begin
                if (!ddr_busy && !fifo_aclr_ddr_active) begin
                    ddr_addr     <= buf_base_addr + ({20'd0, display_line} * LINE_STRIDE);
                    ddr_burstcnt <= LINE_BURST;
                    ddr_rd       <= 1'b1;
                    beat_count   <= 7'd0;
                    timeout_cnt  <= 20'd0;
                    state        <= ST_WAIT_LINE;
                end
            end

            ST_WAIT_LINE: begin
                if (beat_count == LINE_BURST[6:0])
                    state <= ST_LINE_DONE;
                else if (timeout_cnt == TIMEOUT_MAX)
                    state <= ST_IDLE;
                else if (!ddr_dout_ready)
                    timeout_cnt <= timeout_cnt + 20'd1;
            end

            ST_LINE_DONE: begin
                display_line <= display_line + 9'd1;

                if (display_line == V_ACTIVE - 9'd1) begin
                    first_frame_loaded <= 1'b1;
                    frame_ready_reg    <= 1'b1;
                    preloading         <= 1'b0;
                    state              <= ST_IDLE;
                end
                else if (preloading && display_line < 9'd1)
                    state <= ST_READ_LINE;
                else begin
                    preloading <= 1'b0;
                    state      <= ST_WAIT_DISPLAY;
                end
            end

            ST_WAIT_DISPLAY: begin
                if (display_line < V_ACTIVE && new_line_ddr && !vblank_ddr)
                    state <= ST_READ_LINE;
            end

            default: state <= ST_IDLE;
        endcase

        // FIFO write on DDR3 data ready during line read
        if (ddr_dout_ready && (state == ST_WAIT_LINE)) begin
            fifo_wr      <= 1'b1;
            fifo_wr_data <= ddr_dout;
            beat_count   <= beat_count + 7'd1;
        end
    end
end

// -- Dual-Clock FIFO -------------------------------------------------------
// 64-bit wide. 320px line = 80 beats. Need space for 2 lines = 160.
// Use depth 256 for safety.
wire [63:0] fifo_rd_data;
wire        fifo_empty;
reg         fifo_rd;

dcfifo #(
    .intended_device_family ("Cyclone V"),
    .lpm_numwords           (256),
    .lpm_showahead          ("ON"),
    .lpm_type               ("dcfifo"),
    .lpm_width              (64),
    .lpm_widthu             (8),
    .overflow_checking      ("ON"),
    .rdsync_delaypipe       (4),
    .underflow_checking     ("ON"),
    .use_eab                ("ON"),
    .wrsync_delaypipe       (4)
) line_fifo (
    .aclr     (fifo_aclr),
    .data     (fifo_wr_data),
    .rdclk    (clk_vid),
    .rdreq    (fifo_rd),
    .wrclk    (ddr_clk),
    .wrreq    (fifo_wr),
    .q        (fifo_rd_data),
    .rdempty  (fifo_empty),
    .wrfull   (fifo_full),
    .eccstatus(),
    .rdfull   (),
    .rdusedw  (),
    .wrempty  (),
    .wrusedw  ()
);

// -- Pixel Output (no scaling -- 1:1) --------------------------------------
// Each 64-bit FIFO word = 4 RGB565 pixels.
// 320px / 4 = 80 words per line = LINE_BURST.
reg  [63:0] pixel_word;
reg  [1:0]  pixel_sub;
reg         pixel_word_valid;

// RGB565 decode
wire [15:0] cur_pix = pixel_word[{pixel_sub, 4'b0000} +: 16];
wire  [7:0] dec_r = {cur_pix[15:11], cur_pix[15:13]};
wire  [7:0] dec_g = {cur_pix[10:5],  cur_pix[10:9]};
wire  [7:0] dec_b = {cur_pix[4:0],   cur_pix[4:2]};

always @(posedge clk_vid) begin
    if (reset_vid) begin
        fifo_rd          <= 1'b0;
        r_out            <= 8'd0;
        g_out            <= 8'd0;
        b_out            <= 8'd0;
        pixel_word       <= 64'd0;
        pixel_sub        <= 2'd0;
        pixel_word_valid <= 1'b0;
    end
    else begin
        fifo_rd <= 1'b0;

        if (ce_pix) begin
            if (de && frame_ready_vid) begin
                if (pixel_word_valid) begin
                    r_out <= dec_r;
                    g_out <= dec_g;
                    b_out <= dec_b;

                    if (pixel_sub == 2'd3) begin
                        pixel_word_valid <= 1'b0;
                        if (!fifo_empty) begin
                            pixel_word       <= fifo_rd_data;
                            pixel_word_valid <= 1'b1;
                            pixel_sub        <= 2'd0;
                            fifo_rd          <= 1'b1;
                        end
                    end
                    else begin
                        pixel_sub <= pixel_sub + 2'd1;
                    end
                end
                else if (!fifo_empty) begin
                    pixel_word       <= fifo_rd_data;
                    pixel_word_valid <= 1'b1;
                    pixel_sub        <= 2'd0;
                    fifo_rd          <= 1'b1;
                    r_out <= {fifo_rd_data[15:11], fifo_rd_data[15:13]};
                    g_out <= {fifo_rd_data[10:5],  fifo_rd_data[10:9]};
                    b_out <= {fifo_rd_data[4:0],   fifo_rd_data[4:2]};
                end
                else begin
                    r_out <= 8'd0;
                    g_out <= 8'd0;
                    b_out <= 8'd0;
                end
            end
            else begin
                r_out            <= 8'd0;
                g_out            <= 8'd0;
                b_out            <= 8'd0;
                pixel_sub        <= 2'd0;
                pixel_word_valid <= 1'b0;
            end
        end
    end
end

endmodule
