# RZ80 on the Tang Primer 25K — BASIC over UART

Deploys the rz80 core to a [Sipeed Tang Primer 25K](https://wiki.sipeed.com/hardware/en/tang/tang-primer-25k/primer-25k.html)
(Gowin **GW5A-LV25MG121NES**, Arora-V, 50 MHz crystal) running
**NASCOM BASIC 4.7** (RC2014 build) with the console on the dock's BL616
USB-UART at **115200 8N1**.

> Naming: Sipeed's 25K-LUT Tang board is the *Primer* 25K — the Nano
> line tops out at 20K. openFPGALoader knows it as `tangprimer25k`.

    make venv     # once: python venv + pip toolchain (see below)
    make          # bitstream -> build/top.fs
    make prog     # load to FPGA SRAM   (openFPGALoader, volatile)
    make flash    # write to SPI flash  (persistent)

Then connect a terminal to the dock's USB serial port:

    screen /dev/cu.usbserial-* 115200      # macOS; Ctrl-A K to quit

Press Enter at the `Memory top?` cold-start prompt and you're at
`Z80 BASIC Ver 4.7c` / `Ok`. The **H10 push-button** (key[0]) resets the
Z80 — RAM survives, so you get the ROM's warm-start `C|W` prompt.

## Differences from the IcePi Zero port

Same SoC (it shares `uart.v` and `hex2mem.py` with
[`../icepi-zero`](../icepi-zero/README.md); see that README for the
memory map, ACIA shim, and 68B50 RIE/TIE interrupt semantics). Board
deltas only:

| | IcePi Zero | Tang Primer 25K |
|---|---|---|
| FPGA | Lattice ECP5 LFE5U-25F | Gowin GW5A-LV25MG121NES |
| Clock | 50 MHz on M1 | 50 MHz on E2 (same /4 → Z80 at 6.25 MHz) |
| UART pins | K15/K16 (FT231X) | C3 (TX) / B3 (RX) to the BL616 |
| Buttons | active **low** (pull-ups) | active **high** (pull-downs), H10 = reset |
| LEDs | 5 user LEDs | none on the dock (no led port) |
| P&R | nextpnr-ecp5 + ecppack | nextpnr-himbaechel + apycula `gowin_pack` |
| Bitstream | `top.bit`, `-b icepi-zero` | `top.fs`, `-b tangprimer25k` |

## Toolchain — venv, no system packages

`make venv` pip-installs the whole open Gowin flow into `.venv/`:
`yowasp-yosys` (`synth_gowin -family gw5a`),
`yowasp-nextpnr-himbaechel-gowin` (WASM place & route), and
[`apycula`](https://github.com/YosysHQ/apicula) (Project Apicula's
`gowin_pack` bitstream writer — GW5A/Arora-V support incl. BSRAM landed
in 2024-2025). Flashing is the one native tool: `openFPGALoader`
(`brew install openfpgaloader`).

Like the ECP5 port, synthesis runs `proc; async2sync` first (FF
init-value vs async-reset conflict) and sources are staged into
`build/` for the YoWASP sandbox.

## Simulation

    make sim        # Verilator, fast serial (~seconds)
    make sim_real   # true 115200 pacing — exercises the ROM's
                    # interrupt-driven TX (TIE) path

Script: answer `Memory top?`, `PRINT 123+456` → `579`, press key[0]
with a bouncy release, expect the warm-start `C|W` prompt, answer `W`,
expect `Ok`.

## Known issue: stock BL616 debugger firmware vs openFPGALoader

On this dock the JTAG probe is a BL616 MCU *emulating* an FT2232, and
Sipeed's stock emulation firmware corrupts long JTAG shifts: IDCODE
reads fine, but every SRAM configuration ends `FAIL` with status
`CRC Error + ID Verify Failed` — even loading Sipeed's own prebuilt
bitstreams ([openFPGALoader #539](https://github.com/trabucayre/openFPGALoader/issues/539)
is the same signature). JTAG frequency, openFPGALoader master, and the
GW5A footer-checksum PR make no difference; the corruption is
deterministic.

Fix: update the dock's debugger firmware —
[Sipeed's update procedure](https://wiki.sipeed.com/hardware/en/tang/common-doc/update_debugger.html)
(short the two test points on the underside while plugging USB, then
flash with BouffaloLab DevCube; works on macOS) — or flash the
open-source [bl616_dirtyjtag](https://github.com/pepijndevos/bl616_dirtyjtag)
firmware, which openFPGALoader supports natively.

## Variants

    make ROM_HEX=../../tests/basic/tinybasic_1k.hex   # 1K Tiny BASIC
