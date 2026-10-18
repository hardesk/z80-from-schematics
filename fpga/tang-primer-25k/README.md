# RZ80 on the Tang Primer 25K — BASIC SBC and Z80 chip replacement

Two bitstreams from one `top.v` for the
[Sipeed Tang Primer 25K](https://wiki.sipeed.com/hardware/en/tang/tang-primer-25k/primer-25k.html)
(Gowin **GW5A-LV25MG121NES**, Arora-V, 50 MHz crystal):

| build | what it is | clock | J3 header |
|---|---|---|---|
| **sbc** (`make sbc`) | BASIC single-board computer: rz80 + 64 KiB RAM with **NASCOM BASIC 4.7** preloaded + 68B50-style ACIA on the dock's BL616 USB-UART (**230400 8N1**) | internal, PLL → **4 MHz** | the Z80 bus as **outputs**, same pinout as the chip build; only /RESET and /NMI are inputs |
| **chip** (`make chip`) | Z80 chip replacement: the live CPU bus on J3, memory and peripherals are whatever you wire up | **external**, CLK in on J3-22 | a Z80's own pin directions |

> Naming: Sipeed's 25K-LUT Tang board is the *Primer* 25K — the Nano
> line tops out at 20K. openFPGALoader knows it as `tangprimer25k`.

    make venv              # once: python venv + pip toolchain (see below)
    make                   # both bitstreams -> build/top_sbc.fs, build/top_chip.fs
    make prog MODE=sbc     # load to FPGA SRAM (volatile); MODE=chip for the other
    make flash MODE=sbc    # write to SPI flash (persistent)

For the sbc build, connect a terminal to the dock's USB serial port:

    screen /dev/cu.usbserial-* 230400      # macOS; Ctrl-A K to quit
    tio -b 230400 /dev/cu.usbserial-*      # or tio (Ctrl-T Q to quit)

Press Enter at the `Memory top?` cold-start prompt and you're at
`Z80 BASIC Ver 4.7c` / `Ok`. The **H10 push-button** (key[0]) or a low
on header /RESET resets the Z80 — RAM survives, so you get the ROM's
warm-start `C|W` prompt. BASIC wants CR line endings (screen sends CR),
Ctrl-C is BREAK, and the backspace key works as in `make basic`: the ACIA hands BASIC a DEL (7Fh, what macOS terminals send for ⌫) as BS (08h). Tiny BASIC has no line editing.

## Clocking

The Z80 clock is a real clock, one T-state per period: `rtl/z80_top.v`
keeps all core state on its rising edge and reproduces the chip's
falling-edge pin behaviour (MREQ/RD/WR edges, WAIT / read-data / INT /
NMI sampling) with native negative-edge flops (`docs/clocking.md`). No 2×
clock, no clock enable, nothing resamples the clock.

- **sbc**: 50 MHz → PLLA → 8 MHz → hard `CLKDIV` /2 → 4 MHz on the global
  clock network (`CORE_HZ = 4_000_000`; `3_500_000` gives 3.516 MHz, the
  Spectrum rate). The PLLA cannot go below 6.25 MHz by itself, and a
  fabric-FF divider never reaches the BSRAM CLK pins skew-free on GW5A
  (−2.9 ns ⇒ hold violations), hence PLL + CLKDIV. The 4 MHz clock is also
  driven out on J3-22.
- **chip**: CLK on J3-22 (ball J1) drives `z80_top` directly. Every
  rising edge is a T-state; WAIT must be valid around the falling edge of
  T2 and read data around the falling edge of T3 — the Z80's own
  setup/hold contract. Holding CLK stops the CPU, as on a CMOS Z80. Keep
  external CLK at or below 10 MHz.

  *Clock routing.* J1 is a Gowin clock pin (`GCLKT_5`) and the right
  ball for CLK, but the open flow (apicula / nextpnr-himbaechel as of
  2026-10) describes the dedicated pin-to-clock-network path on GW5A-25
  only for the crystal ball E2. Left to itself, nextpnr routes CLK to
  each of the ~350 flops through general fabric (`Failed to route net
  'clk_z80' ... using dedicated routing`), with skew that shows up as
  placement-dependent hold violations. So `tang_primer_25k.cst` has
  `CLOCK_LOC "z80_clk" BUFG;`: J1 makes one short fabric hop to a BUFG
  beside it and then rides the global clock network, like the sbc
  build's clock. No hold violations in four placement seeds, and the few
  ns of insertion delay are the same for every flop. Header balls that
  are not GCLKT pins get such a BUFG automatically, so moving CLK gains
  nothing; Gowin's own tools route J1 on its dedicated path. In the sbc
  build z80_clk is an output and the line changes nothing.

  Hold violations still depend on placement, and a placement
  with them can boot to a garbage screen (the ULA-sound build did, with
  four violations of up to 0.37 ns). The chip build therefore uses a
  fixed seed (`NEXTPNR_SEED_chip`, 1) and fails if any hold violation
  remains; after a design change, rebuild with
  `make chip NEXTPNR_SEED_chip=2` (3, ...) until one routes clean.

RESET (power-on, key[0], header /RESET) asserts asynchronously and its
release is synchronized to the Z80 clock, so the first T1 starts on a
clean rising edge whatever the phase of the release.
`tests/iverilog/tb_reset_top.v` sweeps 200 release phases against a 1 MHz
external clock and `tb_wait_top.v` checks that header /WAIT is honoured
exactly on falling edges (`make bus_controls` at the repo top).

## J3 header pinout (both builds)

The dock's 2×20 J3. J3-11 is fixed +5 V and J3-12 fixed GND; FPGA ball
B2 (J3-14) is faulty on this board, so D4 is rerouted to J3-35, which was
BUSACK's position — **BUSACK is the one Z80 pin not brought out** (37 of
38). All I/O is 3.3 V and **not 5 V tolerant**; use bidirectional level
translators towards a 5 V Z80 system. Full table with FPGA balls in
`tang_primer_25k.cst`.

| direction | chip build | sbc build |
|---|---|---|
| outputs | A0–A15, /M1, /MREQ, /IORQ, /RD, /WR, /RFSH, /HALT | the same, plus CLK (4 MHz), /WAIT (high), /INT (the ACIA's), /BUSREQ (high) |
| bidirectional | D0–D7 (driven only while the CPU drives, released on BUSACK) | D0–D7 as outputs: the CPU's write data, otherwise what memory / the ACIA returned |
| inputs | CLK, /WAIT, /INT, /NMI, /BUSREQ, /RESET | /RESET, /NMI |

In the chip build, address, data and control drivers are released while
the internal BUSACK is asserted (DMA); /HALT stays driven.

## sbc details

Same SoC as the IcePi Zero port (it shares `uart.v` and `hex2mem.py`
with [`../icepi-zero`](../icepi-zero/README.md); see that README for the
memory map, ACIA shim and 68B50 RIE/TIE interrupt semantics). A TX write
that finds the transmitter still busy holds the CPU with `/WAIT` until
the previous byte is out (Tiny BASIC writes without polling TDRE); the
sbc build shows that `/WAIT` on J3. Board deltas:

| | IcePi Zero | Tang Primer 25K |
|---|---|---|
| FPGA | Lattice ECP5 LFE5U-25F | Gowin GW5A-LV25MG121NES |
| Z80 clock | EHXPLLL → 4 MHz | PLLA → 8 MHz → CLKDIV → 4 MHz |
| UART pins | K15/K16 (FT231X) | C3 (TX) / B3 (RX) to the BL616 |
| Buttons | active **low** (pull-ups) | active **high** (pull-downs), H10 = reset |
| LEDs | 5 user LEDs | none on the dock (no led port) |
| Header | 28-pin bus subset (outputs) | full 37-pin Z80 pinout; chip build too |
| P&R | nextpnr-ecp5 + ecppack | nextpnr-himbaechel + apycula `gowin_pack` |
| Bitstream | `top.bit`, `-b icepi-zero` | `top_{sbc,chip}.fs`, `-b tangprimer25k` |

## AY-3-8912 sound (chip build)

`zx_ay.v` adds a ZX Spectrum 128-compatible AY to the chip build, so a
48K Spectrum with this board in its CPU socket plays 128K AY music. The
chip is rejunity's AY-3-8913 core (`../third_party/ay-3-8913`, a git
submodule — clone with `--recursive` or run `git submodule update --init`).

| | |
|---|---|
| Ports | `OUT (0xFFFD)` select register, `OUT (0xBFFD)` write, `IN (0xFFFD)` read (128K partial decode: A15, A14, A1) |
| Clock | fixed 1.77345 MHz (the 128K's AY clock) from the 50 MHz crystal, whatever the host's Z80 CLK — e.g. the RP2350 driver's 5–6 MHz. `make AY_CLK_FROM_CPU=1` uses Z80 CLK / 2 instead, as wired in a real 128K (right pitch only at a 3.5469 MHz CLK) |
| Readback | answered inside the FPGA; J3's data bus is never driven on reads. Unused register bits read as 0, like a real AY |
| key[1] (H11) | toggles the AY on/off (starts on; no visible feedback) — use *off* on a 128K/+2 or with an AY add-on, which already answer these ports |
| Build switches | `AY_ENABLE` (`top.v`); `make AY_STEREO=1` for ABC stereo |

The AY chip runs on the crystal, like the DACs in `top.v`; only the port
decode, the write capture and the readback register sit on the Z80
clock, and writes and readback cross between the two through
synchronizers (`zx_ay.v`).
A stopped or slow Z80 CLK therefore does not stop the sound.

Quick check from BASIC (≈554 Hz tone on A, then read R8 back → 15;
silence with `OUT 65533,8: OUT 49149,0`):

    OUT 65533,7: OUT 49149,62
    OUT 65533,8: OUT 49149,15
    OUT 65533,0: OUT 49149,200
    OUT 65533,1: OUT 49149,0
    OUT 65533,8: PRINT IN 65533

## ULA sound: beeper, MIC and tape EAR (chip build)

The host's ULA (the RP2350 driver) answers port FE, but the FPGA sees the
same cycles, so `zx_ula_audio.v` rebuilds the sound a Spectrum's speaker
would make and `top.v` adds it to both PMOD pins, whether the AY is on,
off (key[1]) or built out:

| Source | Bus | Level (of 1024) |
|---|---|---|
| Speaker (beeper) | `OUT` to an even port, D4 | 160 |
| EAR (tape input) | `IN` from an even port, D6 as the host answered it | 48 |
| MIC (tape output) | `OUT` to an even port, D3 | 16 |

EAR is taken from the host's reply after WAIT is released, so a read
that is still being served never reaches the output. Tape loading is
audible with the driver's normal tape mode; fast mode feeds no pulses
and stays silent. With the AY peaking at 765, the sum peaks at 989.

Quick check from BASIC: `BEEP 1,0` (440 Hz for a second); `LOAD ""` with a
tape playing in normal mode gives the loading noise.

## Audio output

Audio (AY + ULA) leaves as two 50 MHz sigma-delta bitstreams (0/3.3 V)
on one dock PMOD:

| PMOD pin | Ball | `AY_STEREO=0` (default) | `AY_STEREO=1` |
|---|---|---|---|
| 1 (IO0) | D11 | `audio_l` = A + B + C + ULA | `audio_l` = A + B/2 + ULA |
| 2 (IO1) | G11 | `audio_r` = A + B + C + ULA | `audio_r` = C + B/2 + ULA |
| 5, 11 | — | GND | GND |

**MuseLab PMOD-AUDIO v1.2** (iCESugar, "MUSE" silk) plugs straight in. Its
speaker amp (PAM8403) is fed from pin 1 only, through the volume pot and
1 µF + 22 kΩ; the right channel's input parts are not fitted. That's why
the default puts the full mono mix on both pins. Its 3.5 mm jack is wired
directly to pins 1/2 with no filter, so treat it as a raw bitstream, not
a headphone or line output.

**Stereo amplifier** (`make AY_STEREO=1`): no active circuit is needed,
only a passive RC low-pass and a DC-blocking capacitor per channel into
the amp's line input (RCA / 3.5 mm, or the L/R/GND input pads of a
PAM8403/TPA31xx board):

    pin 1/2 ──[1 kΩ]──┬──[1 µF]──> amp L / R in    fc ≈ 16 kHz
                      │                            (2 × 1 kΩ/10 nF stages
                    [10 nF]                         for less hiss)
                      │
    PMOD GND ─────────┴──────────> amp input GND

Peak level is about 2.5 Vpp, which is hot for a line input; start with
the amp's volume low. Never drive a speaker from a PMOD pin directly, and
never ground the speaker minus of a class-D (bridged) amp.

## Toolchain — venv, no system packages

`make venv` pip-installs the whole open Gowin flow into `.venv/`:
`yowasp-yosys` (`synth_gowin -family gw5a`),
`yowasp-nextpnr-himbaechel-gowin` (WASM place & route), and
[`apycula`](https://github.com/YosysHQ/apicula) (Project Apicula's
`gowin_pack` bitstream writer — GW5A/Arora-V support incl. BSRAM, PLLA
and CLKDIV). Flashing is the one native tool: `openFPGALoader`
(`brew install openfpgaloader`).

Like the ECP5 port, synthesis keeps the core's asynchronous reset
(GW5A DFFC/DFFP flops; no `async2sync`, which cost ~3,900 LUTs by
defeating clock-enable inference) and sources are staged into
`build/` for the YoWASP sandbox. The two builds differ only in the
`-chparam EXTERNAL_BUS` passed to yosys.

## Serial: 230400 baud

The console runs at **230400 8N1** (115200 before; set the terminal to
match). The dock's BL616 bridge sets its UART from the rate the terminal asks
for; 230400 has not been tried on a board yet.

The UART (`uart.v`) runs off the Z80 clock, which is not a whole
multiple of 230400: a bit is 4,000,000 / 230,400 = 17.36 Z80 clocks
(15.19 with `CORE_HZ = 3_500_000`). Its bit timer is a phase
accumulator: every clock it adds `BAUD / G`, and a bit ends where the sum
passes `CORE_HZ / G` (`G` their greatest common divisor: 36 of 625 at
4 MHz, a 10-bit register). The rate averages exactly 230400, and every
bit edge lands within one Z80 clock of its ideal time (at worst 5.3 % of
a bit at 4 MHz, 5.6 % at 3.5 MHz). That keeps the UART in the one clock
domain everything else runs in: clocking it from the PLL instead would
take a second domain and synchronisers to the ACIA for the same
accuracy.

The receiver restarts its accumulator at half a bit, plus one clock for
its input synchroniser, at each start edge, so every sample lands within
one clock of its bit's centre. `make sim_uart` (`tb_uart.v`, part of
`make ci`) measures it at both clock rates, with the sender's start edge
at 16 phases of the Z80 clock:

| sender's rate error | 4 MHz: worst sample from the bit's centre (margin left) | 3.5 MHz |
|---|---|---|
| 0 | 5.5 % of a bit (44.5 %) | 6.0 % (44.0 %) |
| ±1 % | 14.5 % (35.5 %) | 14.3 % (35.7 %) |
| ±2 % | 23.9 % (26.1 %) | 23.6 % (26.4 %) |
| ±3 % | 33.4 % (16.6 %) | 33.1 % (16.9 %) |

Every byte still arrives with the sender 4.5 % off either way; USB
bridges are within a fraction of a percent. Pasting still needs a
per-character delay (1 ms is plenty): a character now arrives every
43 µs, about 174 Z80 clocks at 4 MHz, less than BASIC spends on one.

## Simulation

    make sim        # Verilator, sbc build, fast serial (~seconds)
    make sim_real   # the hardware's pacing — exercises the ROM's
                    # interrupt-driven TX (TIE) path
    make sim_uart   # uart.v at 4 and 3.5 MHz against 230400: TX edges, RX at ±3 %
    make sim_tiny   # 1K Tiny BASIC (SIM_BAUD=240000: the hardware's pacing)
    make ci         # all of these, both bitstreams, the Tiny BASIC
                    # bitstream and the top-level `make bus_controls`
    make sim_ay     # (not in ci) Icarus: chip-build top against a Spectrum bus model
                    # (I/O cycles WAIT-stretched like the RP2350 driver) —
                    # AY ports, readback, pitch, mono and stereo mix, the
                    # Z80 CLK / 2 clock, and the AY built out (AY_ENABLE=0)

The PLL is a black box in simulation; a /12 toggle divider stands in
(4.17 MHz) and the Makefile overrides `CORE_HZ` to match. Script: answer
`Memory top?`, `PRINT 123+456` → `579`, press key[0] with a bouncy
release, expect the warm-start `C|W` prompt, answer `W`, expect `Ok`.

`make sim_tiny` runs the 1K Tiny BASIC ROM with RAM from `0x0400`: it
types a short session one character per echo and compares the whole
console transcript byte for byte with the C model's
(`scripts/basicrunner`), so a TX byte the UART dropped fails it.

The chip build is exercised by the repo-level `make bus_controls`
(`tests/iverilog/tb_wait_top.v`, `tb_reset_top.v`), which instantiate
this `top.v` with an external 1 MHz clock on the header (AY built out:
CI does not check out the AY submodule).

`make ci` is what GitHub Actions runs: on every push to this branch
(`.github/workflows/fpga-tang-primer-25k.yml`) and nightly with this branch
merged into main (`targets.yml`), so a core change on main that
breaks the board shows up within a day.

## Known issue: stock BL616 debugger firmware vs openFPGALoader

On this dock the JTAG probe is a BL616 MCU *emulating* an FT2232, and
Sipeed's stock emulation firmware corrupts long JTAG shifts: IDCODE
reads fine, but every SRAM configuration ends `FAIL` with status
`CRC Error + ID Verify Failed` — even loading Sipeed's own prebuilt
bitstreams ([openFPGALoader #539](https://github.com/trabucayre/openFPGALoader/issues/539)
is the same signature). JTAG frequency, openFPGALoader master, and the
GW5A footer-checksum PR make no difference; the corruption is
deterministic.

Fix (verified on this board): update the dock's debugger firmware per
[Sipeed's procedure](https://wiki.sipeed.com/hardware/en/tang/common-doc/update_debugger.html) —
short the `3V3` & `TDO` test points (underside, "Debugger" pad group by
the corner mounting hole) while plugging USB so the BL616 enumerates as
`/dev/cu.usbmodem*`, then flash Sipeed's
`bl616_fpga_partner_25kDock.bin` (release 2025030317). No DevCube GUI
needed — the pip-installable CLI works from macOS:

    .venv/bin/pip install bflb-iot-tool
    .venv/bin/bflb-iot-tool --chipname bl616 --interface uart \
        --port /dev/cu.usbmodem* --baudrate 2000000 \
        --addr 0x0 --firmware bl616_fpga_partner_25kDock.bin --single

Replug normally afterwards; the debugger's USB serial number becomes
the firmware release id, so the tty paths change (e.g.
`/dev/cu.usbserial-20250303171` for the UART console). With the
updated firmware, `make prog` reports `DONE` and BASIC comes up —
verified with the earlier 2× core at a 10 MHz Z80 rate: banner,
arithmetic, RUN loop at ~770 lines/s, Ctrl-C BREAK. The current
single-clock sbc/chip builds have not yet been run on hardware.

Negative-edge flops: yosys's GW5A mapping implements `z80_top`'s
falling-edge samplers and pin-former half as positive-edge DFFs on an
inverted copy of the clock (a LUT1), so both builds show a second clock
`core_nmi_n_DFFSE_D_CLK` in nextpnr's report. Transfers between the two
are half-period paths (125 ns at 4 MHz), so the ~1 ns skew of that net is
harmless. (Alternative:
the open-source [bl616_dirtyjtag](https://github.com/pepijndevos/bl616_dirtyjtag)
firmware, which openFPGALoader supports natively.)

## Variants

    make sbc ROM_HEX=../../tests/basic/tinybasic_1k.hex   # 1K Tiny BASIC

The Makefile write-protects the ROM image rounded up to 1 KiB
(`ROM_PROTECT_TOP`, from `hex2mem.py --top`; override it on the command
line), so Tiny BASIC's variables and stack at `0x0400`–`0x07FF` are RAM,
and a different `ROM_HEX` rebuilds the image and the bitstreams. Pasting
a long program can overrun the 32-byte RX FIFO (basic1K needs ~430 Z80
clocks per input character, more than one takes at 230400 baud): give
the terminal a per-character delay (1 ms is plenty).
