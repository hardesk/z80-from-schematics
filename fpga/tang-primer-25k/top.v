// top.v - RZ80 SoC for the Sipeed Tang Primer 25K (Gowin GW5A-LV25MG121)
//
// NASCOM BASIC 4.7 (RC2014 build) on the rz80 core, console on the
// dock's BL616 USB-UART (115200 8N1). Same SoC as fpga/icepi-zero
// (whose uart.v it shares); board differences only:
//
//   - 50 MHz crystal on E2; a PLLA generates the 20 MHz core clock
//     (2x per Z80 clock -> Z80 at 10 MHz). A PLL, not a divider: a
//     fabric-FF clock never reaches the BSRAM CLK pins skew-free on
//     GW5A (-2.9 ns => hold violations); PLLA output is a true global
//     clock. In simulation the PLLA is a black box, so a /4 divider
//     stands in and the Makefile overrides CORE_HZ to match.
//   - UART to the BL616: FPGA RX = B3, FPGA TX = C3
//   - two push-buttons on H10/H11 with pull-DOWNs -> ACTIVE-HIGH
//     (IcePi's are active-low); key[0] (H10) is the Z80 reset
//   - the dock has no user LEDs, so no led port
//
// Memory map / I/O map / interrupt semantics are identical to the
// IcePi port: 64 KiB BRAM with the ROM preloaded and write-protected
// below 0x2000, 68B50 ACIA shim at ports 0x80/0x81 (Tiny BASIC's
// 0x00/0x01 too), /INT = (RIE & RDRF) | (TIE & TDRE).

module top #(
    parameter CORE_HZ  = 20_000_000,            // PLLA output; sim overrides to 12_500_000
    parameter BAUD     = 115_200,
    parameter ROM_FILE = "rom.mem",
    parameter ROM_PROTECT_TOP = 16'h2000        // NASCOM 4.7 ROM is 0x0000-0x1FD9
) (
    input  wire       clk,       // 50 MHz crystal (E2)
    input  wire       uart_rx,   // BL616 -> FPGA serial (B3)
    output wire       uart_tx,   // FPGA -> BL616 serial (C3)
    input  wire [1:0] key        // push-buttons, ACTIVE HIGH (H10, H11)
);
    // ---- core clock ----
`ifdef SYNTHESIS
    // PLLA: VCO = 50 MHz x MDIV 18 = 900 MHz; CLKOUT0 = VCO / ODIV0
    // = 900 / 45 = 20 MHz. Instantiation and parameter boilerplate
    // follow apicula's examples/gw5a/pll7.v (YosysHQ/apicula, MIT).
    wire clk_cpu;
    wire pll_lock;
    wire gw_gnd = 1'b0;

    PLLA PLLA_inst (
        .LOCK(pll_lock),
        .CLKOUT0(clk_cpu),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(),
        .MDRDO(),
        .CLKIN(clk),
        .CLKFB(gw_gnd),
        .RESET(gw_gnd),
        .PLLPWD(gw_gnd),
        .RESET_I(gw_gnd),
        .RESET_O(gw_gnd),
        .PSSEL({gw_gnd,gw_gnd,gw_gnd}),
        .PSDIR(gw_gnd),
        .PSPULSE(gw_gnd),
        .SSCPOL(gw_gnd),
        .SSCON(gw_gnd),
        .SSCMDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
        .SSCMDSEL_FRAC({gw_gnd,gw_gnd,gw_gnd}),
        .MDCLK(gw_gnd),
        .MDOPC({gw_gnd,gw_gnd}),
        .MDAINC(gw_gnd),
        .MDWDI({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd})
    );

    defparam PLLA_inst.FCLKIN = "50";
    defparam PLLA_inst.IDIV_SEL = 1;
    defparam PLLA_inst.FBDIV_SEL = 1;
    defparam PLLA_inst.MDIV_SEL = 18;           // VCO = 900 MHz
    defparam PLLA_inst.MDIV_FRAC_SEL = 0;
    defparam PLLA_inst.ODIV0_SEL = 45;          // 900 / 45 = 20 MHz
    defparam PLLA_inst.ODIV0_FRAC_SEL = 0;
    // Unused outputs still need explicit ODIVs: apycula's defaults for
    // A_ODIV1..6_SEL are the string '8', which its own binary parser
    // rejects (gowin_pack ValueError). Values are don't-care (EN=FALSE).
    defparam PLLA_inst.ODIV1_SEL = 45;
    defparam PLLA_inst.ODIV2_SEL = 45;
    defparam PLLA_inst.ODIV3_SEL = 45;
    defparam PLLA_inst.ODIV4_SEL = 45;
    defparam PLLA_inst.ODIV5_SEL = 45;
    defparam PLLA_inst.ODIV6_SEL = 45;
    defparam PLLA_inst.CLKOUT0_EN = "TRUE";
    defparam PLLA_inst.CLKOUT1_EN = "FALSE";
    defparam PLLA_inst.CLKOUT2_EN = "FALSE";
    defparam PLLA_inst.CLKOUT3_EN = "FALSE";
    defparam PLLA_inst.CLKOUT4_EN = "FALSE";
    defparam PLLA_inst.CLKOUT5_EN = "FALSE";
    defparam PLLA_inst.CLKOUT6_EN = "FALSE";
    defparam PLLA_inst.CLKFB_SEL = "INTERNAL";
    defparam PLLA_inst.CLKOUT0_DT_DIR = 1'b1;
    defparam PLLA_inst.CLKOUT1_DT_DIR = 1'b1;
    defparam PLLA_inst.CLKOUT2_DT_DIR = 1'b1;
    defparam PLLA_inst.CLKOUT3_DT_DIR = 1'b1;
    defparam PLLA_inst.CLKOUT0_DT_STEP = 0;
    defparam PLLA_inst.CLKOUT1_DT_STEP = 0;
    defparam PLLA_inst.CLKOUT2_DT_STEP = 0;
    defparam PLLA_inst.CLKOUT3_DT_STEP = 0;
    defparam PLLA_inst.CLK0_IN_SEL = 1'b0;
    defparam PLLA_inst.CLK0_OUT_SEL = 1'b0;
    defparam PLLA_inst.CLK1_IN_SEL = 1'b0;
    defparam PLLA_inst.CLK1_OUT_SEL = 1'b0;
    defparam PLLA_inst.CLK2_IN_SEL = 1'b0;
    defparam PLLA_inst.CLK2_OUT_SEL = 1'b0;
    defparam PLLA_inst.CLK3_IN_SEL = 1'b0;
    defparam PLLA_inst.CLK3_OUT_SEL = 1'b0;
    defparam PLLA_inst.CLK4_IN_SEL = 2'b00;
    defparam PLLA_inst.CLK4_OUT_SEL = 1'b0;
    defparam PLLA_inst.CLK5_IN_SEL = 1'b0;
    defparam PLLA_inst.CLK5_OUT_SEL = 1'b0;
    defparam PLLA_inst.CLK6_IN_SEL = 1'b0;
    defparam PLLA_inst.CLK6_OUT_SEL = 1'b0;
    defparam PLLA_inst.DYN_DPA_EN = "FALSE";
    defparam PLLA_inst.CLKOUT0_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT0_PE_FINE = 0;
    defparam PLLA_inst.CLKOUT1_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT1_PE_FINE = 0;
    defparam PLLA_inst.CLKOUT2_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT2_PE_FINE = 0;
    defparam PLLA_inst.CLKOUT3_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT3_PE_FINE = 0;
    defparam PLLA_inst.CLKOUT4_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT4_PE_FINE = 0;
    defparam PLLA_inst.CLKOUT5_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT5_PE_FINE = 0;
    defparam PLLA_inst.CLKOUT6_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT6_PE_FINE = 0;
    defparam PLLA_inst.DYN_PE0_SEL = "FALSE";
    defparam PLLA_inst.DYN_PE1_SEL = "FALSE";
    defparam PLLA_inst.DYN_PE2_SEL = "FALSE";
    defparam PLLA_inst.DYN_PE3_SEL = "FALSE";
    defparam PLLA_inst.DYN_PE4_SEL = "FALSE";
    defparam PLLA_inst.DYN_PE5_SEL = "FALSE";
    defparam PLLA_inst.DYN_PE6_SEL = "FALSE";
    defparam PLLA_inst.DE0_EN = "FALSE";
    defparam PLLA_inst.DE1_EN = "FALSE";
    defparam PLLA_inst.DE2_EN = "FALSE";
    defparam PLLA_inst.DE3_EN = "FALSE";
    defparam PLLA_inst.DE4_EN = "FALSE";
    defparam PLLA_inst.DE5_EN = "FALSE";
    defparam PLLA_inst.DE6_EN = "FALSE";
    defparam PLLA_inst.RESET_I_EN = "FALSE";
    defparam PLLA_inst.RESET_O_EN = "FALSE";
    defparam PLLA_inst.ICP_SEL = 6'bXXXXXX;
    defparam PLLA_inst.LPF_RES = 3'bXXX;
    defparam PLLA_inst.LPF_CAP = 2'b00;
    defparam PLLA_inst.SSC_EN = "FALSE";
`else
    // Simulation stand-in: /4 divider (12.5 MHz). Build sims with
    // -GCORE_HZ=12500000 so the UART divisors match.
    reg [1:0] ckdiv = 0;
    always @(posedge clk) ckdiv <= ckdiv + 1'b1;
    wire clk_cpu = ckdiv[1];
    wire pll_lock = 1'b1;
`endif

    // ---- power-on + key[0] reset (core clk domain) ----
    // Same debounced stretch as the IcePi port: any press clears the
    // counter and reset_n stays low until ~5 ms after the last bounce.
    // Buttons are active high here (board pull-downs).
    reg [15:0] rst_cnt  = 16'd0;
    reg [1:0]  btn_sync = 2'b00;
    always @(posedge clk_cpu) begin
        btn_sync <= {btn_sync[0], key[0]};
        if (btn_sync[1] || !pll_lock)  rst_cnt <= 16'd0;      // pressed / PLL not locked
        else if (rst_cnt != 16'hFFFF)  rst_cnt <= rst_cnt + 1'b1;
    end
    wire reset_n = (rst_cnt == 16'hFFFF);

    // ---- Z80 core ----
    wire [15:0] addr;
    wire [7:0]  data_out;
    wire        data_drive;
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busack_n;
    reg  [7:0]  data_in;
    wire        int_n;

    z80_core cpu (
        .clk        (clk_cpu),
        .reset_n    (reset_n),
        .addr       (addr),
        .data_in    (data_in),
        .data_out   (data_out),
        .data_drive (data_drive),
        .m1_n       (m1_n),
        .mreq_n     (mreq_n),
        .iorq_n     (iorq_n),
        .rd_n       (rd_n),
        .wr_n       (wr_n),
        .rfsh_n     (rfsh_n),
        .halt_n     (halt_n),
        .busack_n   (busack_n),
        .wait_n     (1'b1),
        .int_n      (int_n),
        .nmi_n      (1'b1),
        .busreq_n   (1'b1),
        .dbg_t      (),
        .dbg_phi    (),
        .dbg_m      ()
    );

    // ---- 64 KiB block RAM, ROM image preloaded at configuration ----
    reg [7:0] ram [0:65535];
    initial $readmemh(ROM_FILE, ram);
    reg [7:0] ram_dout;
    always @(posedge clk_cpu) begin
        if (!mreq_n && !wr_n && data_drive && (addr >= ROM_PROTECT_TOP))
            ram[addr] <= data_out;
        ram_dout <= ram[addr];
    end

    // ---- UART ----
    wire       rx_valid;
    wire [7:0] rx_data;
    reg        tx_strobe;
    reg  [7:0] tx_data;
    wire       tx_busy;
    wire       uart_rx_s;

    uart_rx #(.CLK_HZ(CORE_HZ), .BAUD(BAUD)) urx (
        .clk(clk_cpu), .reset_n(reset_n), .rx(uart_rx), .rx_sync(uart_rx_s),
        .valid(rx_valid), .data(rx_data)
    );
    uart_tx #(.CLK_HZ(CORE_HZ), .BAUD(BAUD)) utx (
        .clk(clk_cpu), .reset_n(reset_n), .strobe(tx_strobe), .data(tx_data),
        .tx(uart_tx), .busy(tx_busy)
    );

    // ---- RX FIFO (32 deep) ----
    reg [7:0] fifo [0:31];
    reg [4:0] f_rd = 0, f_wr = 0;
    reg [5:0] f_cnt = 0;
    wire rx_avail = (f_cnt != 0);
    wire [7:0] fifo_head = fifo[f_rd];

    // ---- ACIA-style I/O decode (see fpga/icepi-zero/top.v) ----
    wire iord_active = !iorq_n && !rd_n;
    wire iowr_active = !iorq_n && !wr_n;
    wire inta_active = !iorq_n && !m1_n;
    reg  prev_iord = 0, prev_iowr = 0;
    reg  [7:0] io_dout = 8'hFF;
    wire [7:0] port = addr[7:0];
    wire tx_ready = !tx_busy;

    wire fifo_pop  = iord_active && !prev_iord && (port == 8'h81 || port == 8'h01) && rx_avail;
    wire fifo_push = rx_valid && (f_cnt != 6'd32);

    // 68B50 control register: bit7 RIE, bits 6:5 = 01 -> TIE. The
    // NASCOM/z88dk ACIA driver's TX is interrupt-driven, so TIE must
    // really work (a status-only shim deadlocks TX at real baud).
    reg [7:0] acia_ctrl = 8'h00;
    wire rie = acia_ctrl[7];
    wire tie = (acia_ctrl[6:5] == 2'b01);

    always @(posedge clk_cpu) begin
        if (!reset_n) begin
            f_rd <= 0; f_wr <= 0; f_cnt <= 0;
            prev_iord <= 0; prev_iowr <= 0;
            tx_strobe <= 0;
            acia_ctrl <= 8'h00;
        end else begin
            prev_iord <= iord_active;
            prev_iowr <= iowr_active;
            tx_strobe <= 1'b0;

            if (fifo_push) begin
                fifo[f_wr] <= rx_data;
                f_wr <= f_wr + 1'b1;
            end
            if (fifo_pop) f_rd <= f_rd + 1'b1;
            case ({fifo_push, fifo_pop})
                2'b10: f_cnt <= f_cnt + 1'b1;
                2'b01: f_cnt <= f_cnt - 1'b1;
                default: ;
            endcase

            if (iord_active && !prev_iord) begin
                case (port)
                    8'h80:   io_dout <= {6'b0, tx_ready, rx_avail};    // NASCOM status
                    8'h00:   io_dout <= rx_avail ? 8'hFF : 8'h00;      // Tiny status
                    8'h81,
                    8'h01:   io_dout <= rx_avail ? fifo_head : 8'h00;  // data
                    default: io_dout <= 8'hFF;
                endcase
            end

            if (iowr_active && !prev_iowr) begin
                if (port == 8'h81 || port == 8'h01) begin
                    tx_data   <= data_out;
                    tx_strobe <= 1'b1;
                end else if (port == 8'h80) begin
                    acia_ctrl <= data_out;   // divisor/format bits ignored
                end
            end
        end
    end

    // 68B50 IRQ: RX byte pending (if RIE) or TX empty (if TIE).
    assign int_n = ((rie && rx_avail) || (tie && tx_ready)) ? 1'b0 : 1'b1;

    // Data-bus input mux. INTA in IM 1 ignores the bus; 0xFF = RST 38h.
    always @(*) begin
        if (inta_active)      data_in = 8'hFF;
        else if (iord_active) data_in = io_dout;
        else                  data_in = ram_dout;
    end
endmodule
