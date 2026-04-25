#!/usr/bin/env python3
"""Append a CODE block to a Spectrum .tap and patch the BASIC loader.

Usage: append_code_block.py <in.tap> <bin_to_append> <load_addr_decimal> \
                            <code_block_name> <out.tap>

Reads the input .tap (BASIC header + body + CODE header + body), inserts
a `LOAD "" CODE` clause into the BASIC loader before its first non-LOAD
statement, and appends a fresh CODE header + body for the supplied .bin.

The TS2068's tape ROM honors the load address in the CODE header, so the
second block lands at the assembled origin without any extra logic on
the C side.
"""
import sys, struct, pathlib

def parse_tap(buf):
    blocks = []
    pos = 0
    while pos < len(buf):
        n = struct.unpack('<H', buf[pos:pos+2])[0]; pos += 2
        blocks.append(buf[pos:pos+n]); pos += n
    return blocks

def emit_tap(blocks):
    out = bytearray()
    for b in blocks:
        out += struct.pack('<H', len(b)) + b
    return bytes(out)

def checksum(b):
    x = 0
    for c in b: x ^= c
    return x

def make_header(ftype, name, length, p1, p2):
    name = (name.encode('ascii') + b' ' * 10)[:10]
    body = bytes([0]) + bytes([ftype]) + name + struct.pack('<HHH', length, p1, p2)
    return body + bytes([checksum(body)])

def make_code(load_addr, data):
    body = bytes([0xFF]) + data
    return body + bytes([checksum(body)])

def patch_basic(body):
    """The BASIC body is one line (line 10) of:
         CLEAR VAL "X" : LOAD "" CODE : RANDOMIZE USR VAL "Y"
       We splice an extra `: LOAD "" CODE` after the existing one. The
       byte sequence to insert is: 3A EF 22 22 AF (5 bytes)."""
    insert = bytes([0x3A, 0xEF, 0x22, 0x22, 0xAF])
    line_no  = struct.unpack('>H', body[0:2])[0]
    line_len = struct.unpack('<H', body[2:4])[0]
    line     = body[4:4+line_len]
    # Find the LAST CODE token so successive append calls nest correctly:
    # each new LOAD ""CODE clause goes after the most recently added one.
    af = line.rfind(0xAF)
    if af < 0:
        sys.exit("could not find existing 'CODE' token in BASIC loader")
    new_line = line[:af+1] + insert + line[af+1:]
    new_body = struct.pack('>H', line_no) + struct.pack('<H', len(new_line)) + new_line
    return new_body

def patch_basic_header(hdr, new_basic_len):
    """The BASIC header's length field (offset 12) records body size including
    the trailing 0x0D, but we have to rewrite it to match the patched body."""
    hdr = bytearray(hdr)
    # body[0] = flag 0x00, [1] = type 0 (BASIC), [2..11] = name,
    # [12..13] = length, [14..15] = p1 (autostart line), [16..17] = p2 (size).
    hdr[12:14] = struct.pack('<H', new_basic_len)
    hdr[16:18] = struct.pack('<H', new_basic_len)   # variables area = no vars
    hdr[-1]    = checksum(bytes(hdr[:-1]))
    return bytes(hdr)

def main():
    if len(sys.argv) != 6:
        print(__doc__); sys.exit(1)
    in_tap_path  = pathlib.Path(sys.argv[1])
    bin_path     = pathlib.Path(sys.argv[2])
    load_addr    = int(sys.argv[3])
    code_name    = sys.argv[4]
    out_tap_path = pathlib.Path(sys.argv[5])

    blocks = parse_tap(in_tap_path.read_bytes())
    if len(blocks) < 4 or len(blocks) % 2 != 0:
        sys.exit(f"expected even >=4 blocks (BASIC + N CODE pairs); got {len(blocks)}")

    bas_hdr, bas_body = blocks[0], blocks[1]
    existing_code_blocks = blocks[2:]   # any number of CODE hdr/body pairs

    # Patch BASIC body: each block is flag (0xFF) + line bytes + 1-byte xor.
    flag = bas_body[0]
    line_bytes = bas_body[1:-1]
    new_line_bytes = patch_basic(line_bytes)
    new_bas_body = bytes([flag]) + new_line_bytes
    new_bas_body += bytes([checksum(new_bas_body)])

    # Patch BASIC header to reflect new line size.
    flag_h = bas_hdr[0]
    hdr_payload = bytearray(bas_hdr[1:-1])     # 17 bytes
    new_prog_len = len(new_line_bytes)
    hdr_payload[11:13] = struct.pack('<H', new_prog_len)   # length
    hdr_payload[15:17] = struct.pack('<H', new_prog_len)   # vars area = same
    new_bas_hdr_payload = bytes([flag_h]) + bytes(hdr_payload)
    new_bas_hdr = new_bas_hdr_payload + bytes([checksum(new_bas_hdr_payload)])

    # Build new CODE header + body for the appended block.
    new_code_payload = bin_path.read_bytes()
    name = (code_name.encode('ascii') + b' ' * 10)[:10]
    hdr_inner = bytes([0, 3]) + name + struct.pack('<HHH', len(new_code_payload), load_addr, 32768)
    new_code_hdr  = hdr_inner + bytes([checksum(hdr_inner)])
    body_inner = bytes([0xFF]) + new_code_payload
    new_code_body = body_inner + bytes([checksum(body_inner)])

    out_blocks = [new_bas_hdr, new_bas_body, *existing_code_blocks,
                  new_code_hdr, new_code_body]
    out_tap_path.write_bytes(emit_tap(out_blocks))
    print(f'wrote {out_tap_path}: {len(out_blocks)} blocks, '
          f'total {sum(len(b) for b in out_blocks) + 2*len(out_blocks)} bytes')

if __name__ == '__main__':
    main()
