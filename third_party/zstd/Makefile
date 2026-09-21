CC ?= cc
AR ?= ar
OUT ?= ../../.dub/zstd

ifneq ($(shell uname -s)-$(shell uname -m),Darwin-arm64)
$(error This pinned native build is supported only on macOS arm64)
endif

# v1.5.7's common and decompression translation units, without compressors,
# dictionary builder, legacy decoder, assembly, or shared-library target.
SOURCES = common/debug.c common/entropy_common.c common/error_private.c \
	common/fse_decompress.c common/xxhash.c common/zstd_common.c \
	decompress/huf_decompress.c decompress/zstd_ddict.c \
	decompress/zstd_decompress.c decompress/zstd_decompress_block.c
OBJECTS = $(patsubst %.c,$(OUT)/%.o,$(SOURCES))
HEADERS = $(wildcard common/*.h decompress/*.h zstd.h zstd_errors.h)

.PHONY: all clean
all: $(OUT)/libzstd_decompress.a

$(OUT)/libzstd_decompress.a: $(OBJECTS)
	$(AR) rcs $@ $(OBJECTS)

$(OUT)/%.o: %.c $(HEADERS)
	mkdir -p $(dir $@)
	$(CC) -O2 -DXXH_NAMESPACE=ZSTD_ -DZSTD_DISABLE_ASM -DDEBUGLEVEL=0 -I. -c $< -o $@

clean:
	rm -f $(OBJECTS) $(OUT)/libzstd_decompress.a
