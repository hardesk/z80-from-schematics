// zx_ay.v - ZX Spectrum 128-style AY-3-8912 on the rz80 core's own bus
//
// The FPGA *is* the Z80, so the AY snoops the core's bus outputs directly
// instead of the J3 header, and answers IN 0xFFFD through the core's
// data_in mux (port 0xFFFD is odd, so the 48K ULA never drives it).
//
// Port decode is the 128K one, using partial address decoding:
//   OUT (0xFFFD) A15=1 A14=1 A1=0  BDIR=1 BC1=1  latch register number
//   OUT (0xBFFD) A15=1 A14=0 A1=0  BDIR=1 BC1=0  write register
//   IN  (0xFFFD) A15=1 A14=1 A1=0  BDIR=0 BC1=1  read register
// M1 excludes interrupt acknowledge.
//
// Two clock domains:
//   clk_z80  the Z80 clock (header CLK). Decode, write capture and the
//            readback register live here, next to the core.
//   clk      the 50 MHz crystal. The AY chip itself, its clock and the
//            sigma-delta DACs: the Z80 clock may be slow, irregular or
//            stopped, the AY keeps playing at its own rate.
// A write crosses as a toggle: the byte and its kind (latch / data) are
// captured in clk_z80 registers and held until the next OUT, which is
// dozens of Z80 clocks away, while the toggle goes through a two-flop
// synchronizer. Readback crosses the other way as a level: register
// contents only change on a write, and the next IN is again many Z80
// clocks after it.
//
// AY clock (AY_CLK_FROM_CPU):
//   0 (default) 1.77345 MHz, the Spectrum 128's AY clock, from a 32-bit
//     phase accumulator on the crystal, whatever the host's Z80 CLK is
//     (the RP2350 driver runs it at 5-6 MHz). Error < 0.01 Hz; prescaler
//     ticks land on crystal edges (+-20 ns on a 4.5 us tick).
//   1 Z80 CLK / 2, as wired in a real 128K (1.7734 MHz at 3.5469 MHz).
//     The core's /8 prescaler tick is then every 16 Z80 CLKs.
//
// Output: ABC stereo (L = A + B/2, R = C + B/2, both scaled x2 to stay
// integer) and their mono sum, each as a first-order sigma-delta bitstream
// at the crystal clock. An RC low-pass on the pin is the DAC.

module zx_ay #(
    parameter CLK_HZ          = 50_000_000, // clk (crystal) frequency
    parameter AY_CLK_HZ       = 1_773_450,  // fixed AY input clock
    parameter AY_CLK_FROM_CPU = 1'b0,       // 1: AY clock = Z80 CLK / 2 instead
    parameter CLKS_PER_TICK   = 16          // Z80 CLKs per prescaler tick
) (
    input  wire        clk,                 // 50 MHz crystal
    input  wire        clk_z80,             // Z80 clock
    input  wire        reset_n,             // clk_z80 domain; /RESET also resets the AY
    input  wire        enable,              // clk domain; 0: AY absent (decode off, silent)

    // core bus outputs (clk_z80 domain)
    input  wire [15:0] addr,
    input  wire [7:0]  data_out,
    input  wire        m1_n,
    input  wire        iorq_n,
    input  wire        rd_n,
    input  wire        wr_n,

    output wire        rd_active,           // clk_z80: put rd_data on the core's data_in
    output wire [7:0]  rd_data,

    output wire        audio_l,             // clk domain
    output wire        audio_r,
    output wire        audio_mono
);
    // ================= clk_z80 domain =================
    reg [1:0] en_z = 2'b00;
    always @(posedge clk_z80) en_z <= {en_z[0], enable};

    wire sel = en_z[1] && !iorq_n && m1_n && addr[15] && !addr[1];

    // Write capture: one toggle per OUT, data and kind held until the next.
    // The bus outputs are registers on the same clock, so the decode cannot
    // glitch; it is seen from the rising edge after WR falls.
    reg       wr_prev = 1'b0;
    reg       wr_tog  = 1'b0;
    reg       wr_latch = 1'b0;              // 1: register number (0xFFFD), 0: data (0xBFFD)
    reg [7:0] wr_data = 8'h00;
    // Prescaler ticks from the CPU clock (AY_CLK_FROM_CPU), also a toggle.
    reg [$clog2(CLKS_PER_TICK)-1:0] tick_cnt = 0;
    reg       tick_tog = 1'b0;
    always @(posedge clk_z80) begin
        if (!reset_n) begin
            wr_prev  <= 1'b0;
            tick_cnt <= 0;
        end else begin
            wr_prev <= sel && !wr_n;
            if (sel && !wr_n && !wr_prev) begin
                wr_data  <= data_out;
                wr_latch <= addr[14];
                wr_tog   <= !wr_tog;
            end
            tick_cnt <= tick_cnt + 1'b1;
            if (tick_cnt == CLKS_PER_TICK - 1) begin
                tick_cnt <= 0;
                tick_tog <= !tick_tog;
            end
        end
    end

    // Readback: synchronized AY output, answered while IN 0xFFFD is on the
    // bus. Registered: from the rising edge after IORQ/RD fall (the I/O
    // cycle's automatic Tw) until after T3, so it is settled well before the
    // falling edge of T3 where the core samples data_in.
    wire [7:0] ay_dout_q;
    wire       ay_dout_en_q;
    reg  [7:0] rd_s1 = 8'hFF, rd_s2 = 8'hFF;
    reg  [1:0] rd_en_s = 2'b00;
    reg        rd_q = 1'b0;
    always @(posedge clk_z80) begin
        rd_s1   <= ay_dout_q;               // CDC: level, stable between writes
        rd_s2   <= rd_s1;
        rd_en_s <= {rd_en_s[0], ay_dout_en_q};
        rd_q    <= sel && addr[14] && !rd_n && rd_en_s[1];
    end
    assign rd_active = rd_q;
    assign rd_data   = rd_s2;

    // ================= clk (crystal) domain =================
    // enable only gates the decode and the DACs: AY registers survive an
    // off/on toggle, as on the old sampler build.
    reg [1:0] rst_s = 2'b00;
    always @(posedge clk) rst_s <= {rst_s[0], reset_n};
    wire ay_rst_n = rst_s[1];

    reg [2:0] wr_s   = 3'b000;
    reg [2:0] tick_s = 3'b000;
    always @(posedge clk) begin
        wr_s   <= {wr_s[1:0],   wr_tog};    // CDC: toggle synchronizers
        tick_s <= {tick_s[1:0], tick_tog};
    end
    wire wr_pulse = wr_s[2] ^ wr_s[1];

    // ---- AY prescaler tick (AY clock / 8) ----
    // Fixed: the accumulator overflows AY_CLK_HZ/8 times a second.
    localparam [63:0] PHASE_INC =
        (((64'd1 << 32) * AY_CLK_HZ) + 4 * CLK_HZ) / (8 * CLK_HZ);
    reg [32:0] phase = 33'd0;
    reg ay_ce = 1'b0;
    always @(posedge clk) begin
        if (!ay_rst_n) begin
            phase <= 33'd0;
            ay_ce <= 1'b0;
        end else if (!AY_CLK_FROM_CPU) begin
            phase <= {1'b0, phase[31:0]} + PHASE_INC[32:0];
            ay_ce <= phase[32];
        end else
            ay_ce <= tick_s[2] ^ tick_s[1];
    end

    // ---- the chip ----
    // Idle bus state is "read" (BDIR=0 BC1=1): dout/dout_en then always
    // show the latched register, ready to be synchronized back. A write is
    // one crystal clock of BDIR=1, BC1 selecting latch or data.
    wire [7:0] vol_a, vol_b, vol_c;
    wire [7:0] dout;
    wire       dout_en;
    ay8913_core #(.CHANNEL_OUTPUT_BITS(8)) ay (
        .clk      (clk),
        .rst_n    (ay_rst_n),
        .ce       (ay_ce),
        .bdir     (wr_pulse),
        .bc1      (wr_pulse ? wr_latch : 1'b1),
        .din      (wr_data),                // CDC: held since before wr_tog flipped
        .dout     (dout),
        .dout_en  (dout_en),
        .ioa_in   (8'hFF),                  // 128K keypad/RS232 port: nothing attached
        .iob_in   (8'hFF),
        .volume_A (vol_a),
        .volume_B (vol_b),
        .volume_C (vol_c)
    );

    reg [7:0] dout_q = 8'hFF;
    reg       dout_en_q = 1'b0;
    always @(posedge clk) begin
        dout_q    <= dout;
        dout_en_q <= dout_en && !wr_pulse;
    end
    assign ay_dout_q    = dout_q;
    assign ay_dout_en_q = dout_en_q;

    // ---- ABC stereo mix and sigma-delta DACs ----
    // 2A+B and 2C+B peak at 765 of 1023 (10 bits); A+B+C peaks at 765 too.
    wire [9:0] mix_l    = {1'b0, vol_a, 1'b0} + {2'b00, vol_b};
    wire [9:0] mix_r    = {1'b0, vol_c, 1'b0} + {2'b00, vol_b};
    wire [9:0] mix_mono = {2'b00, vol_a} + {2'b00, vol_b} + {2'b00, vol_c};
    wire       dac_reset = !ay_rst_n || !enable;

    pwm #(.VALUE_BITS(10)) dac_l (
        .clk(clk), .reset(dac_reset), .value(mix_l), .out(audio_l));
    pwm #(.VALUE_BITS(10)) dac_r (
        .clk(clk), .reset(dac_reset), .value(mix_r), .out(audio_r));
    pwm #(.VALUE_BITS(10)) dac_mono (
        .clk(clk), .reset(dac_reset), .value(mix_mono), .out(audio_mono));
endmodule
