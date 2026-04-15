# MiSTer Music Player -- Makefile
# 13 libraries, 27 systems, 1 binary. FPGA audio.
#
# HAVE_* defines + link libraries are set conditionally on which
# static archives are actually present in $(ML)/lib/. This lets the
# build degrade gracefully when individual libraries fail: the backends
# for the missing libs are #ifdef'd out of music_player.cpp and their
# archives aren't added to the link line.

GME_DIR         = game-music-emu/gme
SDL_PREFIX     ?= /opt/sdl12
MUSICLIBS_PREFIX ?= /opt/musiclibs

SDL_CFLAGS  = $(shell $(SDL_PREFIX)/bin/sdl-config --cflags 2>/dev/null || echo "-I$(SDL_PREFIX)/include/SDL")
SDL_LIBS    = $(shell $(SDL_PREFIX)/bin/sdl-config --static-libs 2>/dev/null || echo "-L$(SDL_PREFIX)/lib -lSDL -lpthread")
ML          = $(MUSICLIBS_PREFIX)

CXX      = g++
CC       = gcc

BASE_CXXFLAGS = -mcpu=cortex-a9 -mtune=cortex-a9 -mfloat-abi=hard -mfpu=neon \
                -Ofast -I$(GME_DIR) -Igame-music-emu $(SDL_CFLAGS) \
                -I$(ML)/include \
                -DBLARGG_LITTLE_ENDIAN=1 -DVGM_YM2612_NUKED \
                -ffunction-sections -fdata-sections -Wno-unused-result

BASE_LDFLAGS  = -static-libstdc++ -static-libgcc -L$(ML)/lib

# -- Per-library feature detection --------------------------------------
# Each block: if the archive exists, add the HAVE_* define + link libs.

ifneq (,$(wildcard $(ML)/lib/libsidplayfp.a))
BASE_CXXFLAGS += -DHAVE_SIDPLAYFP
BASE_LDFLAGS  += -lsidplayfp -lresid-builder -lstilview
endif

ifneq (,$(wildcard $(ML)/lib/libopenmpt.a))
BASE_CXXFLAGS += -DHAVE_OPENMPT
BASE_LDFLAGS  += -lopenmpt
endif

ifneq (,$(wildcard $(ML)/lib/libsc68.a))
BASE_CXXFLAGS += -DHAVE_SC68
BASE_LDFLAGS  += -lsc68
ifneq (,$(wildcard $(ML)/lib/libfile68.a))
BASE_LDFLAGS  += -lfile68
endif
endif

ifneq (,$(wildcard $(ML)/lib/libpsflib.a))
BASE_CXXFLAGS += -DHAVE_PSFLIB
BASE_LDFLAGS  += -lpsflib
endif

ifneq (,$(wildcard $(ML)/lib/libhe.a))
BASE_CXXFLAGS += -DHAVE_HE
BASE_LDFLAGS  += -lhe
endif

ifneq (,$(wildcard $(ML)/lib/libht.a))
BASE_CXXFLAGS += -DHAVE_HT
BASE_LDFLAGS  += -lht
endif

ifneq (,$(wildcard $(ML)/lib/liblazyusf.a))
BASE_CXXFLAGS += -DHAVE_LAZYUSF
BASE_LDFLAGS  += -llazyusf
endif

ifneq (,$(wildcard $(ML)/lib/liblazygsf.a))
BASE_CXXFLAGS += -DHAVE_LAZYGSF
BASE_LDFLAGS  += -llazygsf
endif

ifneq (,$(wildcard $(ML)/lib/libadplug.a))
BASE_CXXFLAGS += -DHAVE_ADPLUG
BASE_LDFLAGS  += -ladplug
ifneq (,$(wildcard $(ML)/lib/libbinio.a))
BASE_LDFLAGS  += -lbinio
endif
endif

ifneq (,$(wildcard $(ML)/lib/libvgm-player.a))
BASE_CXXFLAGS += -DHAVE_LIBVGM
BASE_LDFLAGS  += -lvgm-player -lvgm-emu -lvgm-audio -lvgm-utils
endif

ifneq (,$(wildcard $(ML)/lib/libmdxmini.a))
BASE_CXXFLAGS += -DHAVE_MDXMINI
BASE_LDFLAGS  += -lmdxmini
endif

ifneq (,$(wildcard $(ML)/lib/libwswan.a))
BASE_CXXFLAGS += -DHAVE_WSWAN
BASE_LDFLAGS  += -lwswan
endif

CXXFLAGS = $(BASE_CXXFLAGS)
CFLAGS   = $(CXXFLAGS)
LDFLAGS  = $(BASE_LDFLAGS) $(SDL_LIBS) -lm -lpthread -lrt -lz \
           -Wl,--gc-sections -Wl,--as-needed

GME_SRC = $(wildcard $(GME_DIR)/*.cpp) $(GME_DIR)/ext/emu2413.c
GME_OBJ = $(patsubst %.cpp,%.o,$(patsubst %.c,%.o,$(GME_SRC)))

PLAYER_SRC = music_player.cpp
PLAYER_OBJ = $(PLAYER_SRC:.cpp=.o)
BIN = Music_Player

all: $(BIN)
	@echo ""
	@echo "=== Build config ==="
	@echo "  Backends enabled:"
	@echo "$(BASE_CXXFLAGS)" | tr ' ' '\n' | grep '^-DHAVE_' | sed 's/^/    /'

$(BIN): $(GME_OBJ) $(PLAYER_OBJ)
	$(CXX) $^ -o $@ $(LDFLAGS)
	strip $@
	@echo "Built: $(BIN)"
	@ls -lh $(BIN)

%.o: %.cpp
	$(CXX) -c $(CXXFLAGS) $< -o $@
%.o: %.c
	$(CC) -c $(CFLAGS) $< -o $@

clean:
	rm -f $(GME_OBJ) $(PLAYER_OBJ) $(BIN)

.PHONY: all clean
