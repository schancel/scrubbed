CC ?= cc
AR ?= ar
OUT ?= ../../.dub/zstd

# Portability (issue #353): this pinned build is generic C compiled with
# the toolchain's own $(CC)/$(AR); no macOS-specific flags or assembly are
# used here, so it is expected to build unmodified on Linux. This ticket
# adds Linux CI (ubuntu-24.04/-arm, see
# .github/workflows/sha256-native-backends.yml) to generate the real
# evidence for that; treat as unverified until that CI run is green. Gate
# stays a real allowlist (not simply removed) so an unverified platform
# still fails closed with a clear error, per dub.json's own top-level
# preBuildCommand gate.
PLATFORM := $(shell uname -s)-$(shell uname -m)
ifeq (,$(filter $(PLATFORM),Darwin-arm64 Linux-x86_64 Linux-aarch64))
$(error This pinned native build is only verified for macOS arm64 and Linux x86_64/aarch64 (got $(PLATFORM)); see issue #353)
endif

# v1.5.7's common and decompression translation units, without compressors,
# dictionary builder, legacy decoder, assembly, or shared-library target.
DECOMPRESS_SOURCES = common/debug.c common/entropy_common.c common/error_private.c \
	common/fse_decompress.c common/xxhash.c common/zstd_common.c \
	decompress/huf_decompress.c decompress/zstd_ddict.c \
	decompress/zstd_decompress.c decompress/zstd_decompress_block.c
DECOMPRESS_OBJECTS = $(patsubst %.c,$(OUT)/%.o,$(DECOMPRESS_SOURCES))

# v1.5.7's compression translation units, without the legacy decoder,
# dictionary builder, multithreading (`compress/zstdmt_compress.c`; every
# `ZSTDMT_*` reference in `zstd_compress.c` is compiled out behind `#ifdef
# ZSTD_MULTITHREAD`, which this build never defines, matching upstream's own
# default single-threaded static-library configuration), or x86 assembly.
# `compress/zstd_preSplit.c` is required unconditionally
# (`zstd_compress_internal.h` includes its header outside any threading
# guard). This archive deliberately omits `common/*.c`: those five
# translation units (debug, entropy_common, error_private, xxhash,
# zstd_common) are already compiled into `libzstd_decompress.a` above with
# identical flags, and `dub.json` always links both archives together, so
# the compression objects resolve their shared common symbols (error
# strings, XXH64, version info) from that archive rather than duplicating
# it. `libzstd_compress.a` is not usable standalone without
# `libzstd_decompress.a` linked alongside it.
COMPRESS_SOURCES = compress/fse_compress.c compress/hist.c compress/huf_compress.c \
	compress/zstd_compress.c compress/zstd_compress_literals.c \
	compress/zstd_compress_sequences.c compress/zstd_compress_superblock.c \
	compress/zstd_double_fast.c compress/zstd_fast.c compress/zstd_lazy.c \
	compress/zstd_ldm.c compress/zstd_opt.c compress/zstd_preSplit.c
COMPRESS_OBJECTS = $(patsubst %.c,$(OUT)/%.o,$(COMPRESS_SOURCES))

HEADERS = $(wildcard common/*.h compress/*.h decompress/*.h zstd.h zstd_errors.h)

.PHONY: all clean
all: $(OUT)/libzstd_decompress.a $(OUT)/libzstd_compress.a

$(OUT)/libzstd_decompress.a: $(DECOMPRESS_OBJECTS)
	$(AR) rcs $@ $(DECOMPRESS_OBJECTS)

$(OUT)/libzstd_compress.a: $(COMPRESS_OBJECTS)
	$(AR) rcs $@ $(COMPRESS_OBJECTS)

$(OUT)/%.o: %.c $(HEADERS)
	mkdir -p $(dir $@)
	$(CC) -O2 -DXXH_NAMESPACE=ZSTD_ -DZSTD_DISABLE_ASM -DDEBUGLEVEL=0 -I. -c $< -o $@

clean:
	rm -f $(DECOMPRESS_OBJECTS) $(COMPRESS_OBJECTS) $(OUT)/libzstd_decompress.a $(OUT)/libzstd_compress.a
