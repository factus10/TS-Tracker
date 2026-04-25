#!/usr/bin/env python3
"""Bundle a list of .pt3 files into a single C source.

Generates per-song byte arrays plus a song_table[] of {data, title, author}
records and a song_count. Titles and authors are pulled from the PT3 header.

Usage: build_song_bundle.py <output.c> <input1.pt3> [input2.pt3 ...]
"""
import sys, pathlib, re

def clean(s):
    """Trim a 32-byte fixed PT3 string field to a printable C literal."""
    s = s.split(b'\x00', 1)[0].rstrip(b' ').decode('latin1', 'replace')
    out = []
    for ch in s:
        c = ord(ch)
        if 0x20 <= c <= 0x7E and ch not in '"\\':
            out.append(ch)
        else:
            out.append('?')
    return ''.join(out).strip()

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    out_path = pathlib.Path(sys.argv[1])
    inputs   = sys.argv[2:]

    parts = ['/* Auto-generated. Do not edit. */',
             '',
             'struct song_entry {',
             '    const unsigned char *data;',
             '    const char          *title;',
             '    const char          *author;',
             '};',
             '']

    table_rows = []
    total = 0
    for idx, path in enumerate(inputs):
        data = pathlib.Path(path).read_bytes()
        if len(data) < 105:
            print(f'  skip (too small): {path}', file=sys.stderr); continue
        title  = clean(data[30:62])
        author = clean(data[66:98])
        sym    = f'song_{idx}_data'
        rows = []
        for i in range(0, len(data), 16):
            rows.append('    ' + ', '.join(f'0x{b:02X}' for b in data[i:i+16]) + ',')
        parts += [
            f'/* [{idx}] {title} -- {author} ({len(data)} bytes) */',
            f'static const unsigned char {sym}[{len(data)}] = {{',
            *rows,
            '};',
            f'static const char song_{idx}_title[]  = "{title}";',
            f'static const char song_{idx}_author[] = "{author}";',
            '',
        ]
        table_rows.append(f'    {{ {sym}, song_{idx}_title, song_{idx}_author }},')
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
