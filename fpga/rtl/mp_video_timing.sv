//============================================================================
//
//  Music Player Native Video Timing Generator
//
//  320x240 active area @ ~60.06 Hz (420x310 total)
//  CLK_VIDEO: 31.25 MHz, CE_PIXEL: divide-by-4 (7.8125 MHz effective)
//
//  H: 320 active + 20 FP + 32 sync + 48 BP = 420 total
//  V: 240 active +  4 FP +  3 sync + 13 BP = 260 total
//
//  Refresh: 7,812,500 / (420*260) = 71.56 Hz (slightly high)
//
//  ALT timing for stricter NTSC compatibility:
//  H: 320 active + 28 FP + 32 sync + 44 BP = 424 total
//  V: 240 active +  3 FP +  3 sync + 16 BP = 262 total
//  Refresh: 7,812,500 / (424*262) = 70.33 Hz
//
//  Using 424x262 for better CRT compatibility.
//
//  Reuses 3SX/PICO-8 PLL: 50 MHz * 5/8 = 31.25 MHz, /4 = 7.8125 MHz pixels.
//
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

module mp_video_timing (
    input  wire        clk,        // CLK_VIDEO (31.25 MHz)
    input  wire        ce_pix,     // pixel enable (divide-by-4 = 7.8125 MHz)
    input  wire        reset,

    output reg         hsync,      // active low
    output reg         vsync,      // active low
    output reg         hblank,
    output reg         vblank,
    output reg         de,         // data enable = ~(hblank | vblank)
    output reg  [9:0]  hcount,
    output reg  [8:0]  vcount,
    output reg         new_frame,  // pulse at vblank start
    output reg         new_line    // pulse at hblank start
);

// -- Timing constants -- 320x240 active, CRT-friendly
localparam H_ACTIVE = 320;
localparam H_FP     = 28;
localparam H_SYNC   = 32;
localparam H_BP     = 44;
localparam H_TOTAL  = 424;   // 320+28+32+44

localparam V_ACTIVE = 240;
localparam V_FP     = 3;
localparam V_SYNC   = 3;
localparam V_BP     = 16;
localparam V_TOTAL  = 262;   // 240+3+3+16

// Derived boundaries
localparam H_SYNC_START = H_ACTIVE + H_FP;        // 348
localparam H_SYNC_END   = H_SYNC_START + H_SYNC;  // 380
localparam V_SYNC_START = V_ACTIVE + V_FP;         // 243
localparam V_SYNC_END   = V_SYNC_START + V_SYNC;   // 246

always @(posedge clk) begin
    if (reset) begin
        hcount    <= 10'd0;
        vcount    <= 9'd0;
        hsync     <= 1'b1;
        vsync     <= 1'b1;
        hblank    <= 1'b0;
        vblank    <= 1'b0;
        de        <= 1'b1;
        new_frame <= 1'b0;
        new_line  <= 1'b0;
    end
    else if (ce_pix) begin
        new_frame <= 1'b0;
        new_line  <= 1'b0;

        // Horizontal counter
        if (hcount == H_TOTAL - 1) begin
            hcount <= 10'd0;
            if (vcount == V_TOTAL - 1)
                vcount <= 9'd0;
            else
                vcount <= vcount + 9'd1;
        end
        else begin
            hcount <= hcount + 10'd1;
        end

        // Horizontal blanking
        if (hcount == H_ACTIVE - 1)
            hblank <= 1'b1;
        else if (hcount == H_TOTAL - 1)
            hblank <= 1'b0;

        // Horizontal sync (active low)
        if (hcount == H_SYNC_START - 1)
            hsync <= 1'b0;
        else if (hcount == H_SYNC_END - 1)
            hsync <= 1'b1;

        // Vertical blanking
        if (hcount == H_TOTAL - 1) begin
            if (vcount == V_ACTIVE - 1)
                vblank <= 1'b1;
            else if (vcount == V_TOTAL - 1)
                vblank <= 1'b0;
        end

        // Vertical sync (active low)
        if (hcount == H_TOTAL - 1) begin
            if (vcount == V_SYNC_START - 1)
                vsync <= 1'b0;
            else if (vcount == V_SYNC_END - 1)
                vsync <= 1'b1;
        end

        // New line pulse
        if (hcount == H_ACTIVE - 1)
            new_line <= 1'b1;

        // New frame pulse
        if (hcount == H_TOTAL - 1 && vcount == V_ACTIVE - 1)
            new_frame <= 1'b1;

        // Data enable
        begin
            reg next_hblank, next_vblank;

            if (hcount == H_ACTIVE - 1)
                next_hblank = 1'b1;
            else if (hcount == H_TOTAL - 1)
                next_hblank = 1'b0;
            else
                next_hblank = hblank;

            if (hcount == H_TOTAL - 1) begin
                if (vcount == V_ACTIVE - 1)
                    next_vblank = 1'b1;
                else if (vcount == V_TOTAL - 1)
                    next_vblank = 1'b0;
                else
                    next_vblank = vblank;
            end
            else
                next_vblank = vblank;

            de <= ~next_hblank & ~next_vblank;
        end
    end
end

endmodule
