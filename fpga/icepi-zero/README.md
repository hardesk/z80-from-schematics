# RZ80 on the IcePi Zero — BASIC over UART

Deploys the rz80 core to an [IcePi Zero](https://github.com/cheyao/icepi-zero)
(Lattice ECP5 **LFE5U-25F**, CABGA256, 50 MHz MEMS oscillator) running
**NASCOM BASIC 4.7** (RC2014 build) with the console on the board's FTDI
USB-UART at **115200 8N1**.

    make venv     # once: python venv + pip-installed YoWASP FPGA toolchain
    make          # bitstream -> build/top.bit
    make prog     # load to FPGA SRAM   (openFPGALoader, volatile)
    make flash    # write to SPI flash  (persists across power cycles)

Then connect a terminal to the board's USB serial port:

    screen /dev/cu.usbserial-* 115200      # macOS; Ctrl-A K to quit

Press Enter at the `Memory top?` cold-start prompt and you're at
`Z80 BASIC Ver 4.7c` / `Ok`. **Button 0** resets the Z80 (RAM survives,
so you get the ROM's warm-start `C|W` prompt).

Terminal notes: BASIC wants CR line endings (screen sends CR — good),
and Ctrl-C is BREAK just like `make basic`.

## What's in the SoC (`top.v`)

| Piece | Detail |
|---|---|
| Clock | 50 MHz ÷ 4 → 12.5 MHz core clk. The core's `clk` runs at 2× the Z80 clock (one edge per phase), so the **Z80 runs at 6.25 MHz** |
| Memory | one 64 KiB block RAM, preloaded with the ROM image at configuration; writes below `0x2000` dropped (ROM protection) |
| Console | `uart.v` (8N1 TX/RX) + 32-byte RX FIFO behind a 68B50-ACIA shim: `IN (0x80)`=status RDRF/TDRE, `OUT (0x80)`=control, `IN/OUT (0x81)`=data — the same map as `scripts/basicrunner.c`. Tiny BASIC's ports `0x00/0x01` are decoded too |
| Interrupts | real 68B50 IRQ semantics: `/INT` = (RIE & RX-byte-pending) \| (TIE & TX-idle), with RIE/TIE decoded from control-register writes (IM 1; INTA gets `0xFF` = RST 38h). TIE matters: the ROM's z88dk ACIA driver uses an interrupt-driven TX ring buffer, and a status-only shim deadlocks it at real baud (fast-baud sims never enter that path — hence `make sim_real`) |
| Reset | power-on counter + button 0, synchronized; `wait/nmi/busreq` tied idle |
| LEDs | 0 heartbeat · 1 TX activity · 2 RX activity · 3 RX FIFO non-empty · 4 HALT |

The BRAM's 1-cycle read latency needs no wait states: the Z80 holds the
address stable for a whole M-cycle and samples read data several core
clocks after asserting `RD`.

## Toolchain — venv, no system packages

`make venv` creates `.venv/` and pip-installs the
[YoWASP](https://yowasp.org/) WebAssembly builds of the open ECP5 flow:
`yowasp-yosys`, `yowasp-nextpnr-ecp5` (which ships `yowasp-ecppack`).
Sources are staged into `build/` and the tools run from there because the
YoWASP sandbox only sees the current directory tree.

Flashing is the one native tool: `openFPGALoader` (`brew install
openfpgaloader`), which knows the board as `-b icepi-zero`.

Constraints: `icepi-zero.lpf` is vendored from the board repo (v1.3,
zlib-style licence) plus a `FREQUENCY NET "clk_cpu" 12.5 MHZ` constraint
for the divided core clock.

## Simulation

    make sim            # Verilator, ~seconds  (needs verilator in PATH)
    make sim_iverilog   # same script through iverilog, much slower

Both boot the *real* ROM through the *real* top-level — clock divider,
POR, BRAM, UART bits on the pins, interrupt-driven RX — and script a
session: answer `Memory top?`, wait for `Ok`, type `PRINT 123+456`,
expect `579`. The UART is sped up to 16 core clocks per bit
(`-GBAUD=781250`) so serial framing doesn't dominate sim time.

Verilator result on this branch:

    Memory top?
    Z80 BASIC Ver 4.7c
    Copyright (C) 1978 by Microsoft
    31948 Bytes free
    Ok
    PRINT 123+456
     579
    [sim_top] PASS: BASIC booted over UART, 123+456=579

## Variants

Tiny BASIC instead of NASCOM:

    make ROM_HEX=../../tests/basic/tinybasic_1k.hex

(Port map already decoded; Tiny BASIC needs no `/INT`.)
