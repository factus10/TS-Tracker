# Deep optimization review — give TS Tracker songs more RAM

> **How to use this file:** paste the whole thing as the opening prompt for a
> fresh, top-tier Opus session run *inside this repository*
> (`/Users/david/Documents/github/TS Tracker`). It is self-contained: it tells
> the reviewer the goal, the facts, the hazards, and the exact deliverable.

---

## Your role

You are a senior Z80 / embedded-systems engineer doing a **deep, thorough
optimization review** of the TS Tracker codebase. This is an *analysis and
planning* exercise, not a "make one quick fix" task. Be exhaustive. Read the
actual code and the actual build output — do not assume.

## The one objective

**Maximize the RAM available to the user's music.** Concretely, increase both:

1. **`SONG_BUDGET`** — the song slot the compiled PT3 lives in (today **5632 B**,
   `$E500..$FB00`), and
2. **`MAX_PATTERNS`** / pattern-model capacity — the in-RAM decoded working set
   (today **8064 B**, `$6000..$7F80`, `MAX_PATTERNS = 14`).

Everything else — the C code image, the PTxPlay replay binary, libc/CRT
overhead, fixed buffers — is *overhead to be minimized* so that budget can grow.
A byte you remove from the C image or PTxPlay is, after the memory map is
shifted down accordingly, **roughly a byte the song slot can gain.**

Optimize for **size first** (it's the whole point); only consider speed where it
doesn't cost bytes, or where a speed win enables a size win (e.g. replacing a
fat C routine with smaller, faster asm).

## Why this is the lever (current memory map — verified)

```
$4000–$5AFF  display file                      (fixed by hardware)
$5B00–$5FFF  scratch / debug-trap area
$6000–$7F80  decoded pattern MODEL   8064 B     (MAX_PATTERNS=14; lever #3)
$7F80–$8000  small gap
$8000–$DA8D  TRACKER C IMAGE        23181 B     (lever #1 — by far the biggest)
$DA8D–$DAC0  headroom               only 51 B   (Makefile aborts the build past $DAC0)
$DAC0–$E4FE  PTxPlay replay (asm)    2622 B     (lever #2; vendored, position-dependent)
$E4FE–$E500  gap                     only 2 B
$E500–$FB00  SONG SLOT (SONG_BUDGET) 5632 B     ← grow this
$FB00–$FFFF  stack + system          (ceiling; risky to move)
```

The song slot is boxed in: its **floor** is PTxPlay's end, its **ceiling** is the
stack at `$FB00`. To enlarge it you must do one or more of:

- **Lever #1 — shrink the C image.** Code runs `$8000` upward; PTxPlay sits just
  above it at `PTX_ORIGIN` (`$DAC0`). Every byte trimmed from the image lets
  `PTX_ORIGIN_HEX` drop, which lets `TAPE_SONG_BASE_HEX` drop, which grows
  `SONG_BUDGET = $FB00 - TAPE_SONG_BASE`. **Highest ceiling — the image is 23 KB.**
- **Lever #2 — shrink PTxPlay.** It is conditional-assembly asm (`vendor/PTxPlay/
  PTxPlay.asm`, rewritten by `tools/build_ptxplay_asm.py`). Unused features /
  format support / assembly switches may be removable. Independent of lever #1.
- **Lever #3 — shrink or relocate the model.** The 8064 B model at `$6000` sits
  *below* the code. If it shrank (or packed tighter), the code origin could
  potentially move below `$8000`, shifting the *entire* upper stack (code →
  PTxPlay → slot) downward and growing the slot — **and/or** a smaller model
  frees RAM that could be re-budgeted. Evaluate both `MAX_PATTERNS` capacity and
  the per-cell packing (`cell_t`).
- **Lever #4 — the `$FB00` ceiling.** Can the stack/system area be tightened to
  raise the slot's top? Treat as high-risk; quantify before recommending.

Quantify each recommendation **in song-slot bytes gained** (or model bytes /
extra patterns), and note which lever it pulls.

## Toolchain & build (read `Makefile` for specifics)

- C: **z88dk** `zcc +zx -clib=sdcc_iy` (SDCC backend, NOT sccz80). Current opt
  flags: `-SO3 -O3 --max-allocs-per-node200000`, `-DTS2068`. Target is `+zx`
  (not `+ts2068`) deliberately — see README.
- ASM: **sjasmplus** assembles PTxPlay to a flat, **position-dependent /
  self-modifying** `.bin` loaded at a fixed origin. The origin is injected at
  build time; each app builds its own PTxPlay at its own origin (player into
  `build/player/`). You **cannot** just move PTxPlay without rebuilding it at
  the new origin (the pipeline already supports this via `PTX_ORIGIN_HEX`).
- The tracker tape = C image CODE block + PTxPlay CODE block + song slot. The
  Makefile rule `build/tracker.tap` runs an **overlap check** that aborts if the
  C image passes `PTX_ORIGIN`. Respect it.
- **Generate a size map.** z88dk/SDCC can emit a map/symbol file; build with the
  appropriate flag (e.g. add `-m`, and/or inspect the `.map`/`.sym` z88dk
  produces) so you can attribute the 23 KB **per function and per section**
  (_CODE vs _DATA vs _BSS, and the libc/CRT pull-ins). This map is the backbone
  of the review — do not estimate where the bytes are; measure.

## What is actually in the tracker image (don't review the wrong files)

Tracker translation units: **`src/tracker.c`** (~2629 lines — the bulk),
`src/ay_ts2068.c`, `src/pt_engine.c`, `src/ts_io.c`, plus the asm `PTxPlay.bin`.
The player (`src/pt3_player.c`) shares `pt_engine`/`ts_io`/`ay_ts2068`.
**`src/PT3player.c` + `src/PT3player.h` (~1440 lines) are the legacy mvac7
C-only player used ONLY by the `pt3_mvp` demo target — confirm they are NOT
linked into the tracker, then ignore them** (or flag them for deletion if truly
dead). Don't spend effort optimizing code the tracker doesn't contain.

Orientation docs worth reading first: `docs/architecture.md` (decoded-model
design, rebuild-on-demand, memory map, instrument editor), `TODO.md`
(known issues, backlog), `README.md` (toolchain rationale).

## Areas to examine (be systematic; this is not exhaustive — think beyond it)

**A. Compiler / linker (often the cheapest big wins)**
- Are the SDCC optimization settings right for *size*? Investigate
  `--opt-code-size`, `--max-allocs-per-node` tuning, `--peep-asm`/peephole files,
  `-SO3` vs alternatives, function-section gc / dead-code elimination, and any
  z88dk pragma (`#pragma` / `zpragma`) that drops unused CRT/runtime pieces.
- **libc / CRT footprint:** what does `sdcc_iy` pull in? Is `printf`/formatted
  I/O, float, `malloc`/heap, or div/mod runtime linked unnecessarily? The code
  uses fastcall asm thunks for I/O — quantify what library code is dead weight
  and how to exclude it (custom crt0, lighter pragmas, avoiding the constructs
  that drag in runtime helpers like 16-bit divide).
- Section placement / alignment waste.

**B. C code structure (`tracker.c` especially)**
- Dead code, unreachable branches, duplicated logic, over-general helpers that
  could specialize, repeated string literals (note: **SDCC does not pool
  identical string literals** — already confirmed this session), and the large
  body of UI/help text. Could string/table data be compressed or shared?
- Fat patterns: 16-bit math where 8-bit suffices, struct layouts with padding,
  redundant recomputation, anything that bloats generated code.

**C. RAM / data structures (levers #3)**
- The decoded model: is 8064 B the right size? Is `cell_t` (3 bytes, bitfield-
  packed) optimal? Could patterns be stored more compactly, paged, or the model
  overlap a region only used at a different time? Could the model and song slot
  share/relocate to free contiguous space for songs?
- Stack depth, static buffers, scratch arrays — anything oversized.

**D. Hand-written Z80 assembly (targeted)**
- Identify the **fattest C functions** from the size map (likely the pattern
  renderer, the PT3 decoder, `rebuild_song`/`encode_channel`, screen helpers).
  For each, judge whether a hand-coded Z80 version would be materially smaller
  (and the effort/risk). Recommend specific functions, with rough byte estimates
  — don't propose rewriting everything in asm; propose the high-ROI ones.
- Note the existing calling conventions to match: `__z88dk_fastcall`, `__naked`
  (see `ts_io.c`, `pt_engine.c`).

**E. PTxPlay (lever #2)**
- It's built from `vendor/PTxPlay/PTxPlay.asm` via `tools/build_ptxplay_asm.py`
  with conditional-assembly switches (`TS2068`, `CurPosCounter`, `LoopChecker`,
  `ACBBAC`, `Id`, `Release`, etc.). Which switches/features does the tracker
  actually need? Does it need **PT2** support, or only PT3? Are there optional
  effects/tables that can be compiled out? Estimate bytes saved per switch.
  Caution: it's self-modifying and the C side reads exported symbols
  (`ptxplay_addrs.h`) — changing it must keep those intact.

**F. The memory map itself**
- Given all the above, propose the **optimal map**: lowest safe `PTX_ORIGIN` /
  `TAPE_SONG_BASE`, model size/placement, and whether the code origin can drop
  below `$8000`. Show the resulting `SONG_BUDGET` and pattern capacity.

## Method

1. Read `docs/architecture.md`, `Makefile`, `tracker.c`, the support `.c`/`.h`,
   and `vendor/PTxPlay/PTxPlay.asm`. Build the project; produce and study a
   **size map** attributing the 23 KB image per function/section.
2. Attribute every kilobyte. Form hypotheses, then **verify each** by actually
   building the change (or a minimal probe) and reading the new size + the
   overlap check — measure, don't guess. Confirm the apps still boot/play in
   ZEsarUX where a change could affect runtime (harness notes in
   `docs/zesarux-screenshots.md`: absolute `--tape`, dismiss the OSD with
   `send-keys-ascii 200 13`, focus the window).
3. Rank opportunities by **bytes saved ÷ (effort × risk)**.

## Hard constraints — do not break these

- **Correctness first.** A PT3 the tracker saves must still play correctly
  (player and tracker share modules — both must keep working). The song slot
  must still hold the largest real song (`songs/` includes one at **5464 B**).
- PTxPlay is **position-dependent and self-modifying**; only relocate it through
  the existing build pipeline (rebuild at the new origin), and keep the symbols
  in `ptxplay_addrs.h` valid.
- Respect the **calling conventions** (`__z88dk_fastcall`, `__naked`) and the
  Makefile **overlap guard**.
- **Lower-screen gotcha:** `PRINT AT` to screen rows 22–23 via the ROM `RST $10`
  channel corrupts/resets the machine — all prints must stay on rows ≤ 21 (a
  bug found and fixed this session).
- Don't optimize the unused legacy `PT3player.c` into the tracker.

## Deliverable

A written report (Markdown), structured as:

1. **Executive summary** — total realistic savings expressed as **song-slot
   bytes gained** and **extra patterns**, with the recommended new memory map
   (new `PTX_ORIGIN` / `TAPE_SONG_BASE` / `SONG_BUDGET` / `MAX_PATTERNS`).
2. **Where the bytes are** — the size-map breakdown (per section, and the top
   ~20 functions / data items by size), so the numbers are grounded.
3. **Ranked opportunity table** — columns: *opportunity · lever · mechanism ·
   est. bytes saved · effort · risk · files touched*. Sorted by ROI.
4. **Detailed findings** per area (A–F above), each with the evidence (measured
   sizes), the proposed change, the expected saving, and the risk.
5. **Recommended phased plan** — what to do first (safe, high-ROI), what needs
   care, what to leave alone. For the **top 2–3 safest wins**, optionally include
   a concrete diff or asm sketch — but clearly marked as illustrative; **do not
   apply changes wholesale**, since the user wants the review first.

Be concrete and quantitative throughout. "Could save some space" is useless;
"compiling out PT2 support removes ~N bytes from PTxPlay, letting
`TAPE_SONG_BASE` drop to `$XXXX` for +N song-slot bytes" is the bar.
