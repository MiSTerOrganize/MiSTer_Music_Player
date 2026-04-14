//============================================================================
//
//  Music Player — FPGA Audio Output
//
//  Reads stereo 16-bit PCM from a DDR3 ring buffer at 48KHz and holds
//  samples on AUDIO_L/AUDIO_R for the MiSTer audio framework.
//
//  The ARM writes interleaved L/R samples to the ring buffer at 48KHz.
//  This module consumes them at exactly 48KHz derived from CLK_AUDIO
//  (24.576 MHz). The framework's audio_out.v handles IIR filtering,
//  DC blocking, I2S, SPDIF, and sigma-delta DAC from there.
//
//  Same output pattern as NES, SNES, Genesis, Game Boy, and all other
//  MiSTer cores: just hold the sample value steady on AUDIO_L/AUDIO_R.
//
//  DDR3 layout:
//    0x3A000800  write_ptr (ARM writes, FPGA reads)
//    0x3A000804  read_ptr  (FPGA writes, ARM reads)
//    0x3A000810  ring buffer start (4096 stereo samples, interleaved)
//
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

module mp_audio_out (
    input  wire        clk_sys,       // DDR3 clock (100 MHz)
    input  wire        clk_audio,     // Audio clock (24.576 MHz)
    input  wire        reset,

    // DDR3 interface (active-high, active during idle DDR3 cycles)
    // Audio uses a separate request path; main state machine grants access
    output reg         aud_ddr_rd,
    output reg  [28:0] aud_ddr_addr,
    output reg   [7:0] aud_ddr_burstcnt,
    input  wire [63:0] aud_ddr_dout,
    input  wire        aud_ddr_dout_ready,
    output reg         aud_ddr_we,
    output reg  [63:0] aud_ddr_din,

    // Grant signal from main DDR3 state machine
    input  wire        aud_grant,
    output reg         aud_req,

    // Audio output (directly to AUDIO_L/AUDIO_R)
    output reg  [15:0] audio_l,
    output reg  [15:0] audio_r,

    // Status
    input  wire        audio_enable,  // ARM sets when buffer is pre-filled
    output wire [11:0] buffer_level   // samples available (for debug)
);

// -- DDR3 addresses (physical >> 3) --
localparam [28:0] WRITE_PTR_ADDR = 29'h07400100;  // 0x3A000800 >> 3
localparam [28:0] READ_PTR_ADDR  = 29'h07400100;  // same qword (ptr in low 32, rptr in high 32)
localparam [28:0] RING_BASE_ADDR = 29'h07400102;  // 0x3A000810 >> 3

localparam RING_SIZE = 4096;
localparam RING_MASK = RING_SIZE - 1;

// -- Local BRAM audio FIFO --
// Pre-fetch 64 stereo samples from DDR3 into BRAM
// 64 samples * 4 bytes = 256 bytes = 32 DDR3 qwords
localparam PREFETCH_SAMPLES = 64;
localparam PREFETCH_BEATS   = 16;  // 64 samples * 4B / 8B per beat = 32 bytes... 
// Actually: 64 samples * 2 channels * 2 bytes = 256 bytes / 8 = 32 beats
localparam PREFETCH_BEATS_ACTUAL = 32;

reg [31:0] bram_audio [0:127];  // 128 entries of 32-bit (L16 + R16)
reg  [6:0] bram_wr_idx;
reg  [6:0] bram_rd_idx;
wire [6:0] bram_count = bram_wr_idx - bram_rd_idx;

// -- Ring buffer pointers --
reg [11:0] ring_write_ptr;  // from ARM (read from DDR3)
reg [11:0] ring_read_ptr;   // our position (written to DDR3)
reg        ptrs_valid;

wire [11:0] ring_available = (ring_write_ptr - ring_read_ptr) & RING_MASK[11:0];
assign buffer_level = ring_available;

// -- 48KHz tick generator from CLK_AUDIO --
// CLK_AUDIO = 24.576 MHz, need 48KHz = divide by 512
reg [8:0] audio_div;
reg       tick_48k_audio;  // in clk_audio domain

always @(posedge clk_audio) begin
    if (reset) begin
        audio_div <= 9'd0;
        tick_48k_audio <= 1'b0;
    end
    else begin
        tick_48k_audio <= 1'b0;
        audio_div <= audio_div + 9'd1;
        if (audio_div == 9'd511) begin
            audio_div <= 9'd0;
            tick_48k_audio <= 1'b1;
        end
    end
end

// -- CDC: 48KHz tick to clk_sys domain --
reg [2:0] tick_sync;
always @(posedge clk_sys) begin
    if (reset) tick_sync <= 3'b0;
    else       tick_sync <= {tick_sync[1:0], tick_48k_audio};
end
wire tick_48k = tick_sync[1] & ~tick_sync[2];  // rising edge

// -- CDC: audio_enable to clk_sys --
reg [1:0] enable_sync;
always @(posedge clk_sys) begin
    if (reset) enable_sync <= 2'b0;
    else       enable_sync <= {enable_sync[0], audio_enable};
end
wire enabled = enable_sync[1];

// -- BRAM read at 48KHz --
// Consume one sample per 48KHz tick from BRAM
reg [15:0] audio_l_hold, audio_r_hold;

always @(posedge clk_sys) begin
    if (reset) begin
        audio_l_hold <= 16'd0;
        audio_r_hold <= 16'd0;
        bram_rd_idx  <= 7'd0;
    end
    else if (tick_48k && enabled && bram_count > 0) begin
        audio_l_hold <= bram_audio[bram_rd_idx][15:0];
        audio_r_hold <= bram_audio[bram_rd_idx][31:16];
        bram_rd_idx  <= bram_rd_idx + 7'd1;
    end
    // If BRAM empty, hold last sample (no click)
end

// Output to AUDIO_L/AUDIO_R (directly — framework samples at 48KHz)
always @(posedge clk_sys) begin
    audio_l <= audio_l_hold;
    audio_r <= audio_r_hold;
end

// -- DDR3 prefetch state machine --
// When BRAM drops below half full, request a prefetch from DDR3 ring buffer
localparam [2:0] AUD_IDLE       = 3'd0;
localparam [2:0] AUD_READ_PTRS  = 3'd1;
localparam [2:0] AUD_WAIT_PTRS  = 3'd2;
localparam [2:0] AUD_PREFETCH   = 3'd3;
localparam [2:0] AUD_WAIT_DATA  = 3'd4;
localparam [2:0] AUD_WRITE_RPTR = 3'd5;
localparam [2:0] AUD_DONE       = 3'd6;

reg [2:0]  aud_state;
reg [5:0]  beat_cnt;
reg [11:0] fetch_count;
reg [19:0] poll_timer;

always @(posedge clk_sys) begin
    if (reset) begin
        aud_state      <= AUD_IDLE;
        aud_req        <= 1'b0;
        aud_ddr_rd     <= 1'b0;
        aud_ddr_we     <= 1'b0;
        aud_ddr_din    <= 64'd0;
        aud_ddr_addr   <= 29'd0;
        aud_ddr_burstcnt <= 8'd1;
        ring_write_ptr <= 12'd0;
        ring_read_ptr  <= 12'd0;
        ptrs_valid     <= 1'b0;
        bram_wr_idx    <= 7'd0;
        beat_cnt       <= 6'd0;
        fetch_count    <= 12'd0;
        poll_timer     <= 20'd0;
    end
    else begin
        aud_ddr_rd <= 1'b0;
        aud_ddr_we <= 1'b0;

        case (aud_state)
            AUD_IDLE: begin
                aud_req <= 1'b0;
                
                if (!enabled) begin
                    // Not active yet
                end
                else if (bram_count < (PREFETCH_SAMPLES / 2)) begin
                    // BRAM needs refill — request DDR3 access
                    aud_req <= 1'b1;
                    if (aud_grant)
                        aud_state <= AUD_READ_PTRS;
                end
                else begin
                    // Periodically poll write pointer even when BRAM is OK
                    poll_timer <= poll_timer + 20'd1;
                    if (poll_timer[19]) begin
                        poll_timer <= 20'd0;
                        aud_req <= 1'b1;
                        if (aud_grant)
                            aud_state <= AUD_READ_PTRS;
                    end
                end
            end

            AUD_READ_PTRS: begin
                // Read write_ptr and read_ptr from DDR3 (both in one qword)
                aud_ddr_addr     <= WRITE_PTR_ADDR;
                aud_ddr_burstcnt <= 8'd1;
                aud_ddr_rd       <= 1'b1;
                aud_state        <= AUD_WAIT_PTRS;
            end

            AUD_WAIT_PTRS: begin
                if (aud_ddr_dout_ready) begin
                    ring_write_ptr <= aud_ddr_dout[11:0];
                    ptrs_valid <= 1'b1;

                    // Calculate how many samples to fetch
                    // Available in ring = (write - read) & mask
                    // Fetch up to PREFETCH_SAMPLES or whatever is available
                    begin
                        reg [11:0] avail;
                        avail = (aud_ddr_dout[11:0] - ring_read_ptr) & RING_MASK[11:0];
                        
                        if (avail == 12'd0) begin
                            // Nothing to fetch
                            aud_state <= AUD_WRITE_RPTR;
                        end
                        else begin
                            fetch_count <= (avail > PREFETCH_SAMPLES) ? PREFETCH_SAMPLES : avail;
                            aud_state <= AUD_PREFETCH;
                        end
                    end
                end
            end

            AUD_PREFETCH: begin
                // Read samples from ring buffer
                // Each DDR3 qword = 2 stereo samples (8 bytes)
                // ring_read_ptr indexes samples; DDR3 addr = base + (ptr * 4 / 8)
                // = base + (ptr >> 1)
                if (fetch_count > 12'd0) begin
                    aud_ddr_addr     <= RING_BASE_ADDR + {17'd0, ring_read_ptr[11:1]};
                    aud_ddr_burstcnt <= 8'd1;
                    aud_ddr_rd       <= 1'b1;
                    beat_cnt         <= 6'd0;
                    aud_state        <= AUD_WAIT_DATA;
                end
                else begin
                    aud_state <= AUD_WRITE_RPTR;
                end
            end

            AUD_WAIT_DATA: begin
                if (aud_ddr_dout_ready) begin
                    // Each qword has 2 stereo samples: [L0 R0 L1 R1]
                    // Sample 0: bits [15:0]=L, [31:16]=R
                    // Sample 1: bits [47:32]=L, [63:48]=R
                    bram_audio[bram_wr_idx]     <= aud_ddr_dout[31:0];
                    bram_audio[bram_wr_idx + 1] <= aud_ddr_dout[63:32];
                    bram_wr_idx <= bram_wr_idx + 7'd2;
                    
                    ring_read_ptr <= (ring_read_ptr + 12'd2) & RING_MASK[11:0];
                    fetch_count   <= fetch_count - 12'd2;

                    if (fetch_count <= 12'd2)
                        aud_state <= AUD_WRITE_RPTR;
                    else
                        aud_state <= AUD_PREFETCH;
                end
            end

            AUD_WRITE_RPTR: begin
                // Write our read_ptr back to DDR3 so ARM can monitor
                aud_ddr_addr     <= WRITE_PTR_ADDR;
                aud_ddr_din      <= {20'd0, ring_read_ptr, 20'd0, ring_write_ptr};
                // Actually we only want to write read_ptr at [35:32] position...
                // Since both ptrs are in one qword, write the whole thing back
                // with write_ptr unchanged and read_ptr updated
                aud_ddr_din      <= {32'd0, 20'd0, ring_read_ptr};
                // Hmm, this would overwrite write_ptr. Better: use a separate qword.
                // Let's put read_ptr at 0x3A000808 = next qword
                aud_ddr_addr     <= WRITE_PTR_ADDR + 29'd1;  // 0x3A000808 >> 3
                aud_ddr_din      <= {52'd0, ring_read_ptr};
                aud_ddr_burstcnt <= 8'd1;
                aud_ddr_we       <= 1'b1;
                aud_state        <= AUD_DONE;
            end

            AUD_DONE: begin
                aud_req   <= 1'b0;
                aud_state <= AUD_IDLE;
            end

            default: aud_state <= AUD_IDLE;
        endcase
    end
end

endmodule
