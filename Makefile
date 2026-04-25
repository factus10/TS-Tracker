# =============================================================================
# TS Tracker — z88dk build
#
# Targets:
#   make smoketest    Build the AY sanity-test tape
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

CFLAGS   = $(TARGET) $(COMPILER) $(CLIB) $(OPT) -DTS2068 -Isrc

BUILDDIR = build
SRCDIR   = src

AY_SRCS  = $(SRCDIR)/ay_ts2068.c

# Pick which .pt3 to bundle into pt3-mvp. Override on the command line:
#   make pt3-mvp SONG="songs/3BIT - Kenotron - KENO50 (Paradox version).pt3"
SONG ?= songs/3BIT - Debugger - SPRLZ4Ev2004.pt3

# pt3-player bundles all PT3 files in songs/ into a tape with a picker UI.
SONGS_DIR ?= songs
SONGS     := $(sort $(wildcard $(SONGS_DIR)/*.pt3))

PT3_SRCS = $(SRCDIR)/PT3player.c $(AY_SRCS)

.PHONY: all smoketest pt3-mvp pt3-player clean

all: smoketest pt3-player

# ---- smoketest ---------------------------------------------------------------
smoketest: $(BUILDDIR)/smoketest.tap

$(BUILDDIR)/smoketest.tap: $(SRCDIR)/smoketest.c $(AY_SRCS) $(SRCDIR)/ay_ts2068.h | $(BUILDDIR)
	$(ZCC) $(CFLAGS) \
	    $(SRCDIR)/smoketest.c $(AY_SRCS) \
	    -o $(BUILDDIR)/smoketest \
	    -create-app

# ---- pt3-mvp -----------------------------------------------------------------
pt3-mvp: $(BUILDDIR)/pt3-mvp.tap

# Stage the chosen .pt3 to a path without spaces so make's dep tracking works.
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

# ---- pt3-player (multi-song picker) -----------------------------------------
pt3-player: $(BUILDDIR)/pt3-player.tap

# Bundle every .pt3 in songs/ into one C source. Stage to no-space names
# in build/songs_staged/ first so the build never has to deal with shell
# quoting around filenames. The stamp re-runs whenever any source .pt3
# changes (modification times propagate through the staging step).
$(BUILDDIR)/songs.stamp: $(MAKEFILE_LIST) tools/build_song_bundle.py | $(BUILDDIR)
	@rm -rf $(BUILDDIR)/songs_staged && mkdir -p $(BUILDDIR)/songs_staged
	@i=0; for f in $(SONGS_DIR)/*.pt3; do \
	    cp "$$f" "$(BUILDDIR)/songs_staged/song_$$(printf '%02d' $$i).pt3"; \
	    i=$$((i+1)); \
	done
	python3 tools/build_song_bundle.py $(BUILDDIR)/song_bundle.c $(BUILDDIR)/songs_staged/*.pt3
	@touch $@

$(BUILDDIR)/song_bundle.c: $(BUILDDIR)/songs.stamp ;

$(BUILDDIR)/pt3-player.tap: $(SRCDIR)/pt3_player.c $(PT3_SRCS) $(BUILDDIR)/song_bundle.c \
                            $(SRCDIR)/ay_ts2068.h $(SRCDIR)/PT3player.h \
                            $(SRCDIR)/PT3player_NoteTable1.h | $(BUILDDIR)
	$(ZCC) $(CFLAGS) \
	    $(SRCDIR)/pt3_player.c $(PT3_SRCS) $(BUILDDIR)/song_bundle.c \
	    -o $(BUILDDIR)/pt3-player \
	    -create-app

# ---- housekeeping ------------------------------------------------------------
$(BUILDDIR):
	mkdir -p $(BUILDDIR)

clean:
	rm -rf $(BUILDDIR)
