# The FORTH kernel of the mp32 computer (rename to Makefile).
#   make            build/forth.img: the kernel as an image for the boot loader
#                   (and build/forth.lst, forth.map)
#   make test       the whole computer in simulation (forth_tb.v): it boots the kernel
#                   from the flash's model, and the test bench talks to it over the
#                   serial port and the keyboard (about half an hour)
#   make test-quick only the boot and the screen (a few minutes)
#   make heads      fill in the headers' links and lengths in forth.s (tools/heads.py;
#                   make checks them before every build)
#   make boot-serial PORT=COM4
#                   start the board again (the bitstream of ../computer, as there) and
#                   boot build/forth.img over the serial port, then a terminal: what
#                   you type goes to FORTH (Ctrl-] to stop)
#   make send PORT=COM4
#                   only send build/forth.img, to a loader that waits for it
#   make term PORT=COM4 [SEND=file]
#                   only the terminal (SEND: the file sent whenever the board asks
#                   for an image: the loader, RECEIVE, INSTALL)
#   make install PORT=COM4
#                   the terminal; type INSTALL: build/forth.img goes onto the card
#                   (the range BOOT), which then boots it
#   make fonts PORT=COM4
#                   the terminal; type 256 RECEIVE: ../computer/build/fonts.bin goes
#                   onto the card (the range FONTS)
#   make burn       write build/forth.img into the board's flash at $400000, where the
#                   boot loader looks first (the bitstream at 0 stays)
#   make clean
#
# The terminal is ../computer/boot_serial.py (pyserial: python -m pip install pyserial).
# In the MinGW shell (mintty) start it through winpty so it gets every key at once:
# make boot-serial PYTHON="winpty python". Without winpty it works a line at a time.
#
# The assembler, the linker and mp32img come from ../toolchain/bin; the computer's
# Verilog, the boot loader and the fonts from ../computer (make there first builds
# them: make -C ../computer boot).

BUILD   ?= build
TOOLS   ?= ../toolchain/bin
AS       = $(TOOLS)/mp32as
LD       = $(TOOLS)/mp32ld
IMG      = $(TOOLS)/mp32img
PYTHON  ?= python
PORT    ?= COM4
WAIT    ?= 30
COMP     = ../computer
OS_FLASH = 0x400000

CPU = ../cpu/cpu.v ../cpu/irqc.v \
      ../cpu/stage1/fetch.v ../cpu/stage1/pc.v ../cpu/stage1/irq_sequence.v \
      ../cpu/stage2/decode.v ../cpu/stage2/decoder.v ../cpu/stage2/regfile.v \
      ../cpu/stage2/sequencer.v \
      ../cpu/stage3/execute.v ../cpu/stage3/forward.v ../cpu/stage3/alu.v \
      ../cpu/stage3/mul.v ../cpu/stage3/flags.v ../cpu/stage3/cond.v \
      ../cpu/stage3/stackregs.v ../cpu/stage3/scratch.v ../cpu/stage3/tmplh.v \
      ../cpu/stage4/memaccess.v ../cpu/stage5/writeback.v
MEM = ../cpu/stage4/memsys.v ../cpu/stage4/membus.v ../cpu/stage4/bram.v \
      ../cache/cache.v ../cache/sdram.v
DEV = $(COMP)/iodec.v ../uart/uart.v ../uart/uart_rx.v ../uart/uart_tx.v ../uart/fifo.v \
      ../sdcard/sdcard.v ../audio/audio.v ../keyboard/keyboard.v ../timer/timer.v \
      ../display2/video.v $(COMP)/raster.v $(COMP)/tmds.v
COMPUTER = $(COMP)/computer.v $(CPU) $(MEM) $(DEV)
MODELS   = ../cache/sdram_model.v $(COMP)/flash_model.v ../sdcard/sd_model.v \
           ../keyboard/ch9350.v

all: $(BUILD)/forth.img

# ---------------------------------------------------------------- the kernel
heads:
	$(PYTHON) tools/heads.py --fix forth.s

$(BUILD)/forth.o: forth.s memmap.inc tools/heads.py
	mkdir -p $(BUILD)
	$(PYTHON) tools/heads.py forth.s
	$(AS) -o $@ -l $(BUILD)/forth.lst $<

$(BUILD)/forth.bin: $(BUILD)/forth.o forth.cfg
	$(LD) -C forth.cfg -o $@ -m $(BUILD)/forth.map $<

$(BUILD)/forth.img: $(BUILD)/forth.bin
	$(IMG) -o $@ $<
	$(IMG) --info $@

# ---------------------------------------------------------------- simulation
DATA = $(BUILD)/boot.hex $(BUILD)/petscii.hex $(BUILD)/palette.hex

test: $(BUILD)/forth_tb.vvp $(DATA) $(BUILD)/forth.img
	cd $(BUILD) && vvp forth_tb.vvp

$(BUILD)/forth_tb.vvp: forth_tb.v $(COMPUTER) $(MODELS)
	mkdir -p $(BUILD)
	iverilog -g2005 -DMP32_SIM -s forth_tb -o $@ $^

test-quick: $(BUILD)/forth_quick.vvp $(DATA) $(BUILD)/forth.img
	cd $(BUILD) && vvp forth_quick.vvp

$(BUILD)/forth_quick.vvp: forth_tb.v $(COMPUTER) $(MODELS)
	mkdir -p $(BUILD)
	iverilog -g2005 -DMP32_SIM -DSCREEN_ONLY -s forth_tb -o $@ $^

$(BUILD)/boot.hex: $(COMP)/boot.s $(COMP)/boot.cfg
	mkdir -p $(BUILD)
	$(AS) -o $(BUILD)/boot.o -l $(BUILD)/boot.lst $(COMP)/boot.s
	$(LD) -C $(COMP)/boot.cfg -o $@ -m $(BUILD)/boot.map $(BUILD)/boot.o

$(BUILD)/%.hex: ../display2/%.hex
	mkdir -p $(BUILD)
	cp $< $@

# ---------------------------------------------------------------- the board
boot-serial: $(BUILD)/forth.img
	$(PYTHON) $(COMP)/boot_serial.py --port $(PORT) --bitstream $(COMP)/build/top.fs \
		--image $(BUILD)/forth.img --wait $(WAIT) --terminal

send: $(BUILD)/forth.img
	$(PYTHON) $(COMP)/boot_serial.py --port $(PORT) --image $(BUILD)/forth.img --send-only

term:
	$(PYTHON) $(COMP)/boot_serial.py --port $(PORT) --terminal-only $(if $(SEND),--send $(SEND))

install: $(BUILD)/forth.img
	$(PYTHON) $(COMP)/boot_serial.py --port $(PORT) --terminal-only --send $(BUILD)/forth.img

fonts:
	$(PYTHON) $(COMP)/boot_serial.py --port $(PORT) --terminal-only --send $(COMP)/build/fonts.bin

burn: $(BUILD)/forth.img
	openFPGALoader -b tangnano20k --external-flash -o $(OS_FLASH) --file-type bin $<

clean:
	rm -rf $(BUILD)

.PHONY: all heads test test-quick boot-serial send term install fonts burn clean
.PRECIOUS: $(BUILD)/forth.o $(BUILD)/forth.bin
