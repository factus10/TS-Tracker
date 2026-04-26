#!/usr/bin/env python3
"""Bundle one or more .pt3/.pt2 files into a single .tap with one CODE
block per song. Pair this with the player's `L` key, which reads the next
CODE block off tape and plays it.

The CODE header gets the file's stem (uppercased, padded to 10 chars) as
its filename so the player's now-playing screen has something to display.

Usage: songs_to_tape.py <out.tap> <input1.pt3> [input2.pt3 ...]
"""
import sys, struct, pathlib

LOAD_ADDR = 0xCB00   # matches TAPE_SONG_BASE in src/pt3_player.c

def checksum(b):
    x = 0
    for c in b: x ^= c
    return x

def emit_block(payload):
    return struct.pack('<H', len(payload)) + payload

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)

    out = pathlib.Path(sys.argv[1])
    inputs = sys.argv[2:]
    out_tap = bytearray()

    for path in inputs:
        p = pathlib.Path(path)
        data = p.read_bytes()

        name = p.stem.upper()
        # strip non-printable / problematic chars; clamp to 10 ASCII bytes
        clean = ''.join(ch if 0x20 <= ord(ch) <= 0x7E else '?' for ch in name)
        name_bytes = (clean.encode('ascii', 'replace') + b' ' * 10)[:10]

        # Header: flag (0) + type (3=CODE) + name (10) + length + p1 + p2 + xor
        hdr_payload = bytes([0, 3]) + name_bytes + struct.pack('<HHH',
                                len(data), LOAD_ADDR, 0x8000)
        header = hdr_payload + bytes([checksum(hdr_payload)])

        # Body: flag (0xFF) + data + xor
        body_payload = bytes([0xFF]) + data
        body = body_payload + bytes([checksum(body_payload)])

        out_tap += emit_block(header) + emit_block(body)
        print(f'  added {p.name:<60s}  {len(data):>5d} bytes  '
              f'(name="{clean[:10]}")')

    out.write_bytes(out_tap)
    print(f'wrote {out}: {len(inputs)} songs, {len(out_tap)} bytes total')

if __name__ == '__main__':
    main()
