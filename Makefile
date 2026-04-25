# =============================================================================
# TS Tracker -- z88dk build
#
# Targets:
#   make pt3-player   Universal PT2/PT3 picker tape (primary build)
#   make smoketest    AY-3-8912 sanity-check tape
#   make pt3-mvp      Single-song MVP (legacy, mvac7 PT3 player)
#   make clean        Remove build outputs
# =============================================================================

Z88DK_HOME ?= $(HOME)/z88dk/z88dk
export ZCCCFG = $(Z88DK_HOME)/lib/config
export PATH := $(Z88DK_HOME)/bin:$(PATH)

# We target +zx (not +ts2068): the +ts2068 clibs are sccz80-only, but the
# upstream PT3 player uses SDCC inline asm. The TS2068 loads Spectrum tapes
# fine, and our AY library targets ports $F5/$F6 directly so the +zx clib's
# Spectrum-128 AY assumptions don't matter.
ZCC      ?= zcc
TARGET   ?= +zx
COMPILER ?= -compiler=sdcc
CLIB     ?= -clib=sdcc_iy
OPT      ?= -SO3 -O3 --max-allocs-per-node200000

CFLAGS   = $(TARGET) $(COMPILER) $(CLIB) $(OPT) -DTS2068 -Isrc -Ibuild

BUILDDIR = build
SRCDIR   = src

AY_SRCS    = $(SRCDIR)/ay_ts2068.c

# Single-song MVP still uses mvac7's C-only PT3 player.
PT3_SRCS   = $(SRCDIR)/PT3player.c $(AY_SRCS)

# Picker bundles every .pt2 / .pt3 in songs/. Songs are split between two
# memory regions at runtime:
#   * "low" group:  embedded as const arrays in the C binary (lives below $C000)
#   * "high" group: separate flat tape block, loaded at $CA14 (just above PTxPlay)
# The split is greedy by file order; whatever doesn't fit in either cap is
# dropped with a warning at build time.
SONGS_DIR    ?= songs
SONGS        := $(sort $(wildcard $(SONGS_DIR)/*.pt2) $(wildcard $(SONGS_DIR)/*.pt3))
LOW_SONG_CAP ?= 12288         # 12 KB embedded in main C binary
HIGH_SONG_CAP?= 13312         # 13 KB above PTxPlay ($CA14..~$FE13)
HIGH_SONG_BASE?= CA14         # hex; matches the LOAD address of the high block

# Pick which .pt3 to bundle into pt3-mvp.
SONG ?= songs/3BIT - Debugger - SPRLZ4Ev2004.pt3

.PHONY: all smoketest pt3-mvp pt3-player clean

all: smoketest pt3-player

# ---- smoketest ---------------------------------------------------------------
smoketest: $(BUILDDIR)/smoketest.tap

$(BUILDDIR)/smoketest.tap: $(SRCDIR)/smoketest.c $(AY_SRCS) $(SRCDIR)/ay_ts2068.h | $(BUILDDIR)
	$(ZCC) $(CFLAGS) \
	    $(SRCDIR)/smoketest.c $(AY_SRCS) \
	    -o $(BUILDDIR)/smoketest \
	    -create-app

# ---- pt3-mvp (legacy, single-song mvac7 PT3 player) -------------------------
pt3-mvp: $(BUILDDIR)/pt3-mvp.tap

$(BUILDDIR)/song.pt3: | $(BUILDDIR)
	cp "$(SONG)" $(BUILDDIR)/song.pt3

$(BUILDDIR)/song.c: $(BUILDDIR)/song.pt3 tools/pt3_to_c.py
	python3 tools/pt3_to_c.py $(BUILDDIR)/song.pt3 $(BUILDDIR)/song.c song

$(BUILDDIR)/pt3-mvp.tap: $(SRCDIR)/pt3_mvp.c $(PT3_SRCS) $(BUILDDIR)/song.c \
                        $(SRCDIR)/ay_ts2068.h $(SRCDIR)/PT3player.h \
                        $(SRCDIR)/PT3player_NoteTable1.h | $(BUILDDIR)
	$(ZCC) $(CFLAGS) \
	    $(SRCDIR)/pt3_mvp.c $(PT3_SRCS) $(BUILDDIR)/song.c \
	    -o $(BUILDDIR)/pt3-mvp \
	    -create-app

# ---- PTxPlay pipeline (universal PT1/PT2/PT3 driver by S.V. Bulba) -----------
# Transform vendor source -> sjasmplus -> flat .bin -> embedded C blob.
$(BUILDDIR)/PTxPlay.asm: vendor/PTxPlay/PTxPlay.asm tools/build_ptxplay_asm.py | $(BUILDDIR)
	python3 tools/build_ptxplay_asm.py

$(BUILDDIR)/ptxplay.bin $(BUILDDIR)/ptxplay.sym: $(BUILDDIR)/PTxPlay.asm
	cd $(BUILDDIR) && sjasmplus PTxPlay.asm --raw=ptxplay.bin --sym=ptxplay.sym

$(BUILDDIR)/ptxplay_addrs.h: $(BUILDDIR)/ptxplay.sym tools/bin_to_c.py
	python3 tools/bin_to_c.py $(BUILDDIR)/ptxplay.sym \
	    $(BUILDDIR)/ptxplay_addrs.h START SETUP MUTE INIT PLAY VARSEND

# ---- pt3-player (universal PT2/PT3 picker) ----------------------------------
pt3-player: $(BUILDDIR)/pt3-player.tap

# Stage every song to no-space filenames so the build never has to quote.
# Stamp re-runs whenever any source song or the bundle tool changes.
$(BUILDDIR)/songs.stamp: $(MAKEFILE_LIST) tools/build_song_bundle.py | $(BUILDDIR)
	@rm -rf $(BUILDDIR)/songs_staged && mkdir -p $(BUILDDIR)/songs_staged
	@i=0; for f in $(SONGS_DIR)/*.pt2 $(SONGS_DIR)/*.pt3; do \
	    [ -f "$$f" ] || continue; \
	    ext=$${f##*.}; \
	    cp "$$f" "$(BUILDDIR)/songs_staged/song_$$(printf '%02d' $$i).$$ext"; \
	    i=$$((i+1)); \
	done
	python3 tools/build_song_bundle.py \
	    $(BUILDDIR)/song_bundle.c $(BUILDDIR)/songs_high.bin \
	    $(HIGH_SONG_BASE) $(LOW_SONG_CAP) $(HIGH_SONG_CAP) \
	    $(BUILDDIR)/songs_staged/*
	@touch $@

$(BUILDDIR)/song_bundle.c $(BUILDDIR)/songs_high.bin: $(BUILDDIR)/songs.stamp ;

$(BUILDDIR)/pt3-player-base.tap: $(SRCDIR)/pt3_player.c $(AY_SRCS) \
                                  $(BUILDDIR)/song_bundle.c \
                                  $(BUILDDIR)/ptxplay_addrs.h \
                                  $(SRCDIR)/ay_ts2068.h | $(BUILDDIR)
	$(ZCC) $(CFLAGS) \
	    $(SRCDIR)/pt3_player.c $(AY_SRCS) $(BUILDDIR)/song_bundle.c \
	    -o $(BUILDDIR)/pt3-player-base \
	    -create-app
	mv $(BUILDDIR)/pt3-player-base.tap $(BUILDDIR)/pt3-player-base.tap.tmp || true
	@if [ -f $(BUILDDIR)/pt3-player-base ]; then \
	    mv $(BUILDDIR)/pt3-player-base $(BUILDDIR)/pt3-player-base.bin || true; \
	fi
	@if [ -f $(BUILDDIR)/pt3-player-base.tap.tmp ]; then \
	    mv $(BUILDDIR)/pt3-player-base.tap.tmp $(BUILDDIR)/pt3-player-base.tap; \
	fi

# Append two extra CODE blocks: PTxPlay (loads at $C000) and the high song
# bundle (loads at $CA14). Each call to append_code_block.py adds one block
# and inserts a matching `LOAD ""CODE` clause into the BASIC loader, so the
# final tape has three LOAD ""CODE statements running in sequence.
$(BUILDDIR)/pt3-player-stage1.tap: $(BUILDDIR)/pt3-player-base.tap $(BUILDDIR)/ptxplay.bin tools/append_code_block.py
	python3 tools/append_code_block.py \
	    $(BUILDDIR)/pt3-player-base.tap \
	    $(BUILDDIR)/ptxplay.bin \
	    49152 ptxplay \
	    $(BUILDDIR)/pt3-player-stage1.tap

$(BUILDDIR)/pt3-player.tap: $(BUILDDIR)/pt3-player-stage1.tap $(BUILDDIR)/songs_high.bin tools/append_code_block.py
	@if [ -s $(BUILDDIR)/songs_high.bin ]; then \
	    python3 tools/append_code_block.py \
	        $(BUILDDIR)/pt3-player-stage1.tap \
	        $(BUILDDIR)/songs_high.bin \
	        51732 songs \
	        $(BUILDDIR)/pt3-player.tap; \
	else \
	    cp $(BUILDDIR)/pt3-player-stage1.tap $(BUILDDIR)/pt3-player.tap; \
	    echo "  (high song bundle empty -- no third CODE block)"; \
	fi

# ---- housekeeping ------------------------------------------------------------
$(BUILDDIR):
	mkdir -p $(BUILDDIR)

clean:
	rm -rf $(BUILDDIR)
