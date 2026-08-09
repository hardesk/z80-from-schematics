#!/usr/bin/env python3
"""Intel HEX -> $readmemh image (65536 lines, one byte per line).

Usage: hex2mem.py <rom.hex> <out.mem>

Same record subset as scripts/basicrunner.c's loader: type 00 data
records honoured, type 01 ends the file, everything else skipped.
Unused addresses are zero-filled (BRAM powers up zeroed anyway; this
keeps the image explicit and simulation X-free).
"""
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <rom.hex> <out.mem>")
    mem = bytearray(65536)
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line.startswith(":"):
                continue
            length = int(line[1:3], 16)
            addr = int(line[3:7], 16)
            rtype = int(line[7:9], 16)
            if rtype == 1:
                break
            if rtype != 0:
                continue
            for i in range(length):
                mem[(addr + i) & 0xFFFF] = int(line[9 + i * 2 : 11 + i * 2], 16)
    with open(sys.argv[2], "w") as f:
        f.write("\n".join(f"{b:02x}" for b in mem) + "\n")
    print(f"[hex2mem] {sys.argv[1]} -> {sys.argv[2]} (64 KiB image)")


if __name__ == "__main__":
    main()
