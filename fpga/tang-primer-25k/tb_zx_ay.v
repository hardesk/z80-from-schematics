// tb_zx_ay.v - external-bus smoke test of the built-in AY (zx_ay.v).
//
// Runs the real chip-build top (EXTERNAL_BUS=1) against a model of a 48K Spectrum's
// bus: 64 KiB of memory on J3, a 3.5 MHz Z80 CLK, and an I/O space that
// answers every read with 0x55 (stand-in for the floating bus). The Z80
// program below programs the AY through 0xFFFD/0xBFFD, reads registers
// back with IN, stores the results to 0x8000.. and halts. Then:
//
//   1. readback: R8=0F, R1 (written F0) = 00 (AY masks unused bits),
//      R0=02, and IN 0xBFFD = 55 (not an AY read port)
//   2. pitch: channel A, period 2 -> toggles every 2 AY ticks (prescaler
//      /8): every 9.0219 us at the fixed 1.77345 MHz AY clock, or with
//      -DAY_CPU_CLK (AY clock = Z80 CLK / 2) every 32 Z80 CLKs. The Z80
//      CLK is deliberately not a divisor of the crystal, so the AY's
//      clock-domain crossing sees every phase.
//   3. mix: tone A at volume 15. Stereo (-DAY_STEREO): L ~ 0.249
//      (2*255/1024 x 50%), R = 0 (B and C silent). Mono (default): both
//      pins carry A+B+C ~ 0.125 (255/1024 x 50%).
//
// Every I/O cycle is stretched with WAIT, as the RP2350 driver does.
//
// With -DAY_OFF the AY is built out (AY_ENABLE=0): every IN must read 55
// and both audio pins must stay low.

`timescale 1ns / 1ps

module tb_zx_ay;
`ifdef AY_OFF
    localparam AY_ENABLE = 1'b0;
`else
    localparam AY_ENABLE = 1'b1;
`endif
`ifdef AY_CPU_CLK
    localparam AY_CLK_FROM_CPU = 1'b1;
`else
    localparam AY_CLK_FROM_CPU = 1'b0;
`endif
`ifdef AY_STEREO
    localparam AY_STEREO = 1'b1;
`else
    localparam AY_STEREO = 1'b0;
`endif

    reg clk = 0;
    always #10 clk = ~clk;                      // 50 MHz crystal

    reg z80_clk_r = 0;
    always #143 z80_clk_r = ~z80_clk_r;         // ~3.5 MHz Spectrum CPU clock
    // CLK / WAIT / INT / BUSREQ are inouts on the top (outputs in the sbc
    // build): drive them through nets.
    wire z80_clk = z80_clk_r;
    wire int_n = 1'b1, busreq_n = 1'b1;
    wire wait_n;                                // bus model below

    reg  z80_reset_n = 1'b0;
    wire [15:0] a;
    wire [7:0]  d;
    wire m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n;
    wire audio_l, audio_r;

    top #(.EXTERNAL_BUS(1'b1), .AY_ENABLE(AY_ENABLE), .AY_STEREO(AY_STEREO),
         .AY_CLK_FROM_CPU(AY_CLK_FROM_CPU)) dut (
        .clk(clk), .uart_rx(1'b1), .uart_tx(), .key(2'b00),
        .audio_l(audio_l), .audio_r(audio_r),
        .z80_clk(z80_clk), .z80_a(a), .z80_d(d),
        .z80_m1_n(m1_n), .z80_mreq_n(mreq_n), .z80_iorq_n(iorq_n),
        .z80_rd_n(rd_n), .z80_wr_n(wr_n), .z80_rfsh_n(rfsh_n), .z80_halt_n(halt_n),
        .z80_wait_n(wait_n), .z80_int_n(int_n), .z80_nmi_n(1'b1),
        .z80_busreq_n(busreq_n), .z80_reset_n(z80_reset_n)
    );

    // ---- Spectrum-side bus model ----
    // Like the RP2350 driver, stretch every I/O cycle with WAIT: low from
    // IORQ's fall for the first four Z80 CLKs, so the AY readback must hold
    // across inserted Tw states.
    integer io_clks = 0;
    always @(posedge z80_clk_r)
        io_clks <= (!iorq_n && m1_n) ? io_clks + 1 : 0;
    assign wait_n = !(!iorq_n && m1_n && io_clks < 4);

    reg [7:0] mem [0:65535];
    assign d = (!mreq_n && !rd_n)          ? mem[a] :
               (!iorq_n && !rd_n && m1_n)  ? 8'h55  : 8'hzz;
    always @(posedge clk)
        if (!mreq_n && !wr_n) mem[a] <= d;

    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        i = 0;
        // LD BC,FFFD
        mem[i] = 8'h01; mem[i+1] = 8'hFD; mem[i+2] = 8'hFF; i = i + 3;
        ay_write(7, 8'h3E);                     // mixer: tone A only
        ay_write(8, 8'h0F);                     // A volume 15
        ay_write(0, 8'h02);                     // A period = 2
        ay_write(1, 8'hF0);                     // coarse: only bits 3:0 exist
        ay_read(8, 16'h8000);
        ay_read(1, 16'h8001);
        ay_read(0, 16'h8002);
        // LD B,BF; IN A,(C); LD (8003),A  -- 0xBFFD is write-only
        mem[i] = 8'h06; mem[i+1] = 8'hBF; i = i + 2;
        mem[i] = 8'hED; mem[i+1] = 8'h78; i = i + 2;
        mem[i] = 8'h32; mem[i+1] = 8'h03; mem[i+2] = 8'h80; i = i + 3;
        mem[i] = 8'h76;                         // HALT
    end

    // B=FF; A=reg; OUT (C),A; B=BF; A=val; OUT (C),A
    task ay_write(input [3:0] r, input [7:0] v);
        begin
            mem[i] = 8'h06; mem[i+1] = 8'hFF; i = i + 2;
            mem[i] = 8'h3E; mem[i+1] = r;     i = i + 2;
            mem[i] = 8'hED; mem[i+1] = 8'h79; i = i + 2;
            mem[i] = 8'h06; mem[i+1] = 8'hBF; i = i + 2;
            mem[i] = 8'h3E; mem[i+1] = v;     i = i + 2;
            mem[i] = 8'hED; mem[i+1] = 8'h79; i = i + 2;
        end
    endtask

    // B=FF; A=reg; OUT (C),A; IN A,(C); LD (dst),A
    task ay_read(input [3:0] r, input [15:0] dst);
        begin
            mem[i] = 8'h06; mem[i+1] = 8'hFF; i = i + 2;
            mem[i] = 8'h3E; mem[i+1] = r;     i = i + 2;
            mem[i] = 8'hED; mem[i+1] = 8'h79; i = i + 2;
            mem[i] = 8'hED; mem[i+1] = 8'h78; i = i + 2;
            mem[i] = 8'h32; mem[i+1] = dst[7:0]; mem[i+2] = dst[15:8]; i = i + 3;
        end
    endtask

    // ---- checks ----
    integer errors = 0;
    task expect8(input [15:0] adr, input [7:0] want);
        begin
            if (mem[adr] !== want) begin
                $display("FAIL: mem[%h] = %h, expected %h", adr, mem[adr], want);
                errors = errors + 1;
            end else
                $display("ok:   mem[%h] = %h", adr, mem[adr]);
        end
    endtask

    // Channel A tone flips: Z80 CLKs apart (CPU clock) or ns apart (fixed:
    // 2 ticks x 8 / 1.77345 MHz = 9021.9 ns, +-1 crystal clock of jitter)
    localparam real FLIP_NS = 2.0 * 8.0 * 1.0e9 / 1_773_450.0;
    integer zclk = 0, last_flip = -1, flips = 0, flip_bad = 0;
    real    t_last = -1.0, t_first = 0.0, t_now;
    always @(posedge z80_clk) zclk = zclk + 1;
`ifndef AY_OFF                                  // g_ay is not built with AY_ENABLE=0
    always @(dut.g_ay.ay.ay.tone_A) if (halt_n === 1'b0) begin
        t_now = $realtime;
        if (AY_CLK_FROM_CPU) begin
            if (last_flip >= 0 && zclk - last_flip != 32) flip_bad = flip_bad + 1;
        end else if (t_last >= 0.0) begin
            if (t_now - t_last < FLIP_NS - 25.0 || t_now - t_last > FLIP_NS + 25.0)
                flip_bad = flip_bad + 1;
        end else
            t_first = t_now;
        last_flip = zclk;
        t_last = t_now;
        flips = flips + 1;
    end
`endif

    integer n, ones_l, ones_r;
    real fl, fr;
    initial begin
        // Skip the 262144-clock power-on reset stretch; the reset path is
        // the same one the hardware has already exercised.
        #100 force dut.rst_cnt = 18'h3FFFF;
        #2000 z80_reset_n = 1'b1;

        wait (halt_n === 1'b0);
        $display("halted at %0d ns", $time);
        if (AY_ENABLE) begin
            expect8(16'h8000, 8'h0F);
            expect8(16'h8001, 8'h00);
            expect8(16'h8002, 8'h02);
        end else begin
            expect8(16'h8000, 8'h55);
            expect8(16'h8001, 8'h55);
            expect8(16'h8002, 8'h55);
        end
        expect8(16'h8003, 8'h55);

        // Measure 64 AY tone periods' worth of sigma-delta output
        ones_l = 0; ones_r = 0;
        for (n = 0; n < 64 * 64 * 286 / 20; n = n + 1) begin
            @(posedge clk);
            ones_l = ones_l + audio_l;
            ones_r = ones_r + audio_r;
        end
        fl = ones_l * 1.0 / n; fr = ones_r * 1.0 / n;
        $display("density L=%0.4f R=%0.4f (%s), tone A flips=%0d (bad=%0d)",
                 fl, fr, AY_STEREO ? "stereo" : "mono", flips, flip_bad);

        if (AY_ENABLE) begin
            if (flips < 100 || flip_bad != 0) begin
                $display("FAIL: tone A flip interval"); errors = errors + 1;
            end
            if (!AY_CLK_FROM_CPU) begin
                $display("mean flip interval %0.2f ns (expected %0.2f)",
                         (t_last - t_first) / (flips - 1), FLIP_NS);
                if ((t_last - t_first) / (flips - 1) < FLIP_NS * 0.999 ||
                    (t_last - t_first) / (flips - 1) > FLIP_NS * 1.001) begin
                    $display("FAIL: mean AY pitch off"); errors = errors + 1;
                end
            end
            if (AY_STEREO) begin
                if (fl < 0.235 || fl > 0.263) begin
                    $display("FAIL: L density, expected ~0.249"); errors = errors + 1;
                end
                if (ones_r != 0) begin
                    $display("FAIL: R should be silent"); errors = errors + 1;
                end
            end else begin
                if (fl < 0.117 || fl > 0.132 || ones_l != ones_r) begin
                    $display("FAIL: mono, expected L == R ~0.125"); errors = errors + 1;
                end
            end
        end else if (ones_l + ones_r != 0) begin
            $display("FAIL: audio pins must stay low with the AY off"); errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: timeout (no HALT)");
        $finish;
    end
endmodule
