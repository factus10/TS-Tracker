#!/usr/bin/env python3
"""Bundle .pt2 / .pt3 files into a C source + an optional raw "high" binary.

Two memory regions for songs at runtime:

  * LOW group: embedded as const arrays in the C binary, placed by the linker
    somewhere in $8000..$BFFF (below where PTxPlay loads at $C000).
  * HIGH group: concatenated into a separate flat binary that the BASIC
    loader places at $CA14 (just above PTxPlay). Pointers in song_table
    are computed from the runtime base + offset.

The split is greedy: songs are visited in alphabetical order; if the next
song still fits in the low cap it goes to the low group, otherwise to the
high group. If the high group also overflows its cap, the song is dropped
with a warning.

Usage: build_song_bundle.py <out_bundle.c> <out_high.bin> <high_base_hex>
                            <low_cap> <high_cap> <input1> [input2 ...]

PT3 header (100 bytes):
  $00..$1D  "ProTracker 3.x compilation of "
  $1E..$3D  title (32 bytes, padded with spaces)
  $42..$61  author (32 bytes)
  $63       tone-table number; $64 speed; ...

PT2 has no fixed text; we scan the first 256 bytes for the longest run of
printable ASCII as a best-effort title.
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
    return clean(data[0x1E:0x3E]), clean(data[0x42:0x62]), 0   # fmt=0 (PT3)

def parse_pt2(data: bytes):
    runs = re.findall(rb'[\x20-\x7E]{8,}', data[:256])
    title = clean(max(runs, key=len)) if runs else ''
    return (title or 'PT2 song'), '', 1   # fmt=1 (PT2)

def main():
    if len(sys.argv) < 7:
        print(__doc__); sys.exit(1)
    out_c     = pathlib.Path(sys.argv[1])
    out_high  = pathlib.Path(sys.argv[2])
    high_base = int(sys.argv[3], 16)
    low_cap   = int(sys.argv[4])
    high_cap  = int(sys.argv[5])
    inputs    = sorted(sys.argv[6:])

    parsed = []
    for path in inputs:
        p = pathlib.Path(path)
        data = p.read_bytes()
        if data.startswith(PT3_MAGIC):
            title, author, fmt = parse_pt3(data)
        elif p.suffix.lower() == '.pt2':
            title, author, fmt = parse_pt2(data)
        else:
            print(f'  skip (unknown format): {path}', file=sys.stderr); continue
        parsed.append({'data': data, 'title': title, 'author': author,
                        'fmt': fmt, 'name': p.name})

    # Greedy split: prefer LOW until it would overflow, then HIGH.
    low, high = [], []
    low_used, high_used = 0, 0
    for s in parsed:
        n = len(s['data'])
        if low_used + n <= low_cap:
            low.append(s); low_used += n
        elif high_used + n <= high_cap:
            high.append(s); high_used += n
        else:
            print(f"  WARNING dropping {s['name']} ({n} bytes) - both bins full",
                  file=sys.stderr)
    print(f'  low group:  {len(low)} songs, {low_used} bytes (cap {low_cap})')
    print(f'  high group: {len(high)} songs, {high_used} bytes (cap {high_cap})')

    parts = ['/* Auto-generated. Do not edit. */',
             '',
             'struct song_entry {',
             '    const unsigned char *data;',
             '    const char          *title;',
             '    const char          *author;',
             '    unsigned char        fmt;     /* 0 = PT3, 1 = PT2 */',
             '};',
             '']

    # Emit low-group song-data arrays.
    for idx, s in enumerate(low):
        rows = []
        for i in range(0, len(s['data']), 16):
            rows.append('    ' + ', '.join(f'0x{b:02X}' for b in s['data'][i:i+16]) + ',')
        kind = 'PT3' if s['fmt'] == 0 else 'PT2'
        parts += [
            f"/* low[{idx}] ({kind}) {s['title']} -- {s['author']} ({len(s['data'])} bytes) */",
            f'static const unsigned char song_low_{idx}_data[{len(s["data"])}] = {{',
            *rows,
            '};',
        ]

    # Emit title/author strings for everything (low + high).
    parts.append('')
    all_songs = low + high
    for i, s in enumerate(all_songs):
        parts.append(f'static const char song_{i}_title[]  = "{s["title"]}";')
        parts.append(f'static const char song_{i}_author[] = "{s["author"]}";')
    parts.append('')

    # High-group song-data pointers, computed from runtime base + offset.
    if high:
        parts.append(f'/* high-group songs are loaded by tape at ${high_base:04X}+ */')
        offset = 0
        for j, s in enumerate(high):
            parts.append(
                f'#define song_high_{j}_data '
                f'((const unsigned char *)0x{high_base + offset:04X})'
            )
            offset += len(s['data'])
        parts.append('')

    # song_table[] preserves the original alphabetical order; we tag each row
    # with whichever data symbol it landed on.
    parts.append(f'const struct song_entry song_table[{len(all_songs)}] = {{')
    low_count = len(low)
    for i, s in enumerate(all_songs):
        if i < low_count:
            data_sym = f'song_low_{i}_data'
        else:
            data_sym = f'song_high_{i - low_count}_data'
        parts.append(
            f'    {{ {data_sym}, song_{i}_title, song_{i}_author, {s["fmt"]} }},'
        )
    parts += [
        '};',
        f'const unsigned char song_count = {len(all_songs)};',
        '',
    ]

    out_c.write_text('\n'.join(parts) + '\n', encoding='ascii')

    # Concatenate high group into a flat binary.
    with out_high.open('wb') as f:
        for s in high:
            f.write(s['data'])

    print(f'  wrote {out_c}: {len(all_songs)} songs in song_table[]')
    print(f'  wrote {out_high}: {high_used} bytes')

if __name__ == '__main__':
    main()
