// zx_ula_audio.v - the ZX Spectrum ULA's sound, from the rz80 core's own bus
//
// The ULA itself lives in the host (the RP2350 driver answers port FE),
// but the FPGA is the Z80 and sees the same I/O cycles, so the audio the
// ULA would make can be rebuilt here and mixed with the AY:
//   speaker  OUT to an even port, D4 (the beeper)
//   MIC      OUT to an even port, D3 (tape save signal; on a real Spectrum
//            it shares the speaker pin, much quieter)
//   EAR      IN from an even port, D6 as the host answered it (the tape
//            input, heard as loading noise; the host drives D6 from its
//            tape player, so fast-mode loads stay silent)
// Port decode is the 48K ULA's: A0=0, M1 high (not an interrupt
// acknowledge), as the RP2350 driver's handle_io_out / handle_io_in.
//
// clk_z80 domain throughout. OUT data is valid from the rising edge after
// WR falls. IN data on data_in is the host's reply only once it has
// released WAIT, so EAR follows data_in on every rising edge of the read
// and is committed when IORQ rises: the last edge with RD low is T3's,
// after the reply. Earlier edges (Tw, before the reply) never reach
// the output.
module zx_ula_audio (
    input  wire       clk_z80,
    input  wire       reset_n,              // clk_z80 domain: all three off

    // core bus (clk_z80 domain)
    input  wire [15:0] addr,
    input  wire [7:0]  data_out,
    input  wire [7:0]  data_in,
    input  wire        m1_n,
    input  wire        iorq_n,
    input  wire        rd_n,
    input  wire        wr_n,

    output reg         speaker = 1'b0,
    output reg         mic     = 1'b0,
    output reg         ear     = 1'b0
);
    wire sel = !iorq_n && m1_n && !addr[0];

    reg wr_prev  = 1'b0;
    reg in_read  = 1'b0;                    // an even-port IN is on the bus
    reg ear_cand = 1'b0;
    always @(posedge clk_z80) begin
        if (!reset_n) begin
            speaker <= 1'b0;
            mic     <= 1'b0;
            ear     <= 1'b0;
            wr_prev <= 1'b0;
            in_read <= 1'b0;
        end else begin
            wr_prev <= sel && !wr_n;
            if (sel && !wr_n && !wr_prev) begin
                speaker <= data_out[4];
                mic     <= data_out[3];
            end
            in_read <= sel && !rd_n;
            if (sel && !rd_n)  ear_cand <= data_in[6];
            else if (in_read)  ear      <= ear_cand;
        end
    end
endmodule
