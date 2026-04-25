#!/usr/bin/env python3
"""Bundle .pt2 and .pt3 files into a single C source.

Generates per-song byte arrays and a song_table[] of {data, title, author,
fmt} records. fmt = 0 for PT3, 1 for PT2 (matches PTxPlay's SETUP-byte
bit 1 convention).

PT3 header (100 bytes):
  $00..$1D  "ProTracker 3.x compilation of "
  $1E..$3D  title (32 bytes, padded with spaces)
  $3E..$41  " by "
  $42..$61  author (32 bytes)
  $63       tone table number
  $64       speed
  ...

PT2 header has no fixed text; the title sits near the start of the file
itself. PTxPlay's PT2 init reads pointers starting at offset 0. There is
no formal author field, so we leave it blank.

Usage: build_song_bundle.py <output.c> <input1> [input2 ...]
"""
import sys, pathlib, re

PT3_MAGIC = b"ProTracker 3"

def clean(s: bytes) -> str:
    s = s.split(b'\x00', 1)[0].rstrip(b' ').decode('latin1', 'replace')
    out = []
    for ch in s:
        c = ord(ch)
        if 0x20 <= c <= 0x7E and ch not in '"\\':
            out.append(ch)
        else:
            out.append('?')
    return ''.join(out).strip()

def parse_pt3(data: bytes):
    title  = clean(data[0x1E:0x3E])
    author = clean(data[0x42:0x62])
    return title, author, 0   # fmt=0 (PT3)

def parse_pt2(data: bytes):
    """PT2 has no header text. Most files have a printable title somewhere
    near the start; we scan the first 200 bytes for the longest run of
    printable ASCII >=8 chars and use that as a best-effort title."""
    head = data[:256]
    runs = re.findall(rb'[\x20-\x7E]{8,}', head)
    title = ''
    if runs:
        title = clean(max(runs, key=len))
    return (title or 'PT2 song'), '', 1  # fmt=1 (PT2)

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    out_path = pathlib.Path(sys.argv[1])
    inputs   = sorted(sys.argv[2:])

    parts = ['/* Auto-generated. Do not edit. */',
             '',
             'struct song_entry {',
             '    const unsigned char *data;',
             '    const char          *title;',
             '    const char          *author;',
             '    unsigned char        fmt;     /* 0 = PT3, 1 = PT2 */',
             '};',
             '']

    table_rows = []
    total = 0
    for idx, path in enumerate(inputs):
        p = pathlib.Path(path)
        data = p.read_bytes()
        if data.startswith(PT3_MAGIC):
            title, author, fmt = parse_pt3(data)
        elif p.suffix.lower() == '.pt2':
            title, author, fmt = parse_pt2(data)
        else:
            print(f'  skip (unknown format): {path}', file=sys.stderr); continue

        sym = f'song_{idx}_data'
        rows = []
        for i in range(0, len(data), 16):
            rows.append('    ' + ', '.join(f'0x{b:02X}' for b in data[i:i+16]) + ',')
        kind = 'PT3' if fmt == 0 else 'PT2'
        parts += [
            f'/* [{idx}] ({kind}) {title} -- {author} ({len(data)} bytes) */',
            f'static const unsigned char {sym}[{len(data)}] = {{',
            *rows,
            '};',
            f'static const char song_{idx}_title[]  = "{title}";',
            f'static const char song_{idx}_author[] = "{author}";',
            '',
        ]
        table_rows.append(f'    {{ {sym}, song_{idx}_title, song_{idx}_author, {fmt} }},')
        total += len(data)

    parts += [
        f'const struct song_entry song_table[{len(table_rows)}] = {{',
        *table_rows,
        '};',
        f'const unsigned char song_count = {len(table_rows)};',
        '',
    ]
    out_path.write_text('\n'.join(parts) + '\n', encoding='ascii')
    print(f'wrote {out_path}: {len(table_rows)} songs, {total} bytes of song data')

if __name__ == '__main__':
    main()
