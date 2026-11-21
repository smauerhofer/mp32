# Builds the example: the library math.lib from udiv.s and umul.s, then the
# block RAM image build/boot.hex for BRAM_INIT.
#
# The tools come from ../../bin: run "make publish" in the toolchain folder first.

TOOLS ?= ../../bin
AS = $(TOOLS)/mp32as
AR = $(TOOLS)/mp32ar
LD = $(TOOLS)/mp32ld

LIBSRC = udiv.s umul.s

all: build/boot.hex

build:
	mkdir -p build

build/%.o: %.s | build
	$(AS) -o $@ -l build/$*.lst $<

build/math.lib: $(LIBSRC:%.s=build/%.o)
	rm -f $@
	$(AR) a $@ $^

build/boot.hex: build/main.o build/math.lib mp32.cfg
	$(LD) -C mp32.cfg -o $@ -m build/boot.map build/main.o build/math.lib

clean:
	rm -rf build

.PHONY: all clean
