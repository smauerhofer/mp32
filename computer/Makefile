# The mp32 computer on the Tang Nano 20K.
#   make test       the boot loader and the operating system, then the whole computer
#                   in simulation (computer_tb.v, with models of the SDRAM, the SPI
#                   flash and the microSD card): it boots from each of the three
#   make test-iodec the I/O decoder's board registers and the buttons (iodec_tb.v)
#   make boot       only the boot loader: build/boot.hex (and boot.lst, boot.map)
#   make os         only the operating system: build/os.img (and os.lst, os.map)
#   make board      synthesize, place and route, pack: build/top.fs
#   make flash      send it to the board (into its SRAM: gone after power-off)
#   make burn       write it into the board's flash (stays)
#   make os-burn    write build/os.img into the board's flash at $400000, where the
#                   boot loader looks first (the bitstream at 0 stays)
#   make os-send PORT=COM4
#                   send build/os.img over the serial port, to a boot loader that
#                   found nothing in the flash and on the card
#   make boot-serial PORT=COM4
#                   start the board again and boot build/os.img over the serial port:
#                   loads the bitstream into the board (as make flash: that resets
#                   it), waits until the boot loader asks for the image, sends it,
#                   then shows what the board says (Ctrl-C to stop). For it the flash
#                   must hold no image at $400000 and the card slot be empty
#
# The serial port goes through boot_serial.py (pyserial: python -m pip install
# pyserial): on Windows, stty cannot put the board's port into raw mode. PORT takes
# COM4 or /dev/ttyS3 (COMn is /dev/ttyS(n-1)); no terminal may have it open.
#   make fonts-sd   build/fonts.bin: the four old fonts (../display2/fonts.hex: normal,
#                   bold, italic, underlined), raw, 8 KB, for the SD card at FONT_LBA
#                   (see README.md, the fonts); build/startfonts.bin, the 4 fonts the
#                   computer starts with (Latin-1, PETSCII, PETSCII text, the book's)
#   make clean      throw away what the build made
#
# The assembler, the linker and mp32img come from ../toolchain/bin: build the
# toolchain first (see ../toolchain/README.md). Everything is built in build/, where
# the memory files (boot.hex, startfonts.hex, palette.hex, os.img) are put next to what
# reads them.

BUILD   ?= build
DEVICE   = GW2AR-LV18QN88C8/I7
FAMILY   = GW2A-18C
FREQ     = 42
TOOLS   ?= ../toolchain/bin
AS       = $(TOOLS)/mp32as
LD       = $(TOOLS)/mp32ld
IMG      = $(TOOLS)/mp32img
# where the image goes in the flash: FLASH_IMAGE in boot.s
OS_FLASH = 0x400000
PORT    ?= COM4
PYTHON  ?= python
# boot-serial: how long to wait for the boot loader to ask for the image (s)
WAIT    ?= 30

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
DEV = iodec.v ../uart/uart.v ../uart/uart_rx.v ../uart/uart_tx.v ../uart/fifo.v \
      ../sdcard/sdcard.v ../audio/audio.v ../keyboard/keyboard.v ../timer/timer.v \
      ../display2/video.v raster.v tmds.v
COMPUTER = computer.v $(CPU) $(MEM) $(DEV)
BOARD    = top.v pll.v serializer.v $(COMPUTER)
DATA     = $(BUILD)/boot.hex $(BUILD)/startfonts.hex $(BUILD)/palette.hex
MODELS   = ../cache/sdram_model.v flash_model.v ../sdcard/sd_model.v

all: test

# ---------------------------------------------------------------- the boot loader
boot: $(BUILD)/boot.hex

$(BUILD)/boot.o: boot.s
	mkdir -p $(BUILD)
	$(AS) -o $@ -l $(BUILD)/boot.lst $<

$(BUILD)/boot.hex: $(BUILD)/boot.o boot.cfg
	$(LD) -C boot.cfg -o $@ -m $(BUILD)/boot.map $(BUILD)/boot.o

# ---------------------------------------------------------------- the operating system
os: $(BUILD)/os.img

$(BUILD)/os.o: os.s
	mkdir -p $(BUILD)
	$(AS) -o $@ -l $(BUILD)/os.lst $<

$(BUILD)/os.bin: $(BUILD)/os.o os.cfg
	$(LD) -C os.cfg -o $@ -m $(BUILD)/os.map $(BUILD)/os.o

$(BUILD)/os.img: $(BUILD)/os.bin
	$(IMG) -o $@ $<
	$(IMG) --info $@

$(BUILD)/%.hex: ../display2/%.hex
	mkdir -p $(BUILD)
	cp $< $@

# ---------------------------------------------------------------- fonts for the SD card
fonts-sd: $(BUILD)/fonts.bin $(BUILD)/startfonts.bin

$(BUILD)/%.bin: ../display2/%.hex ../display2/tools/font_bin.py
	mkdir -p $(BUILD)
	$(PYTHON) ../display2/tools/font_bin.py $< $@

# ---------------------------------------------------------------- simulation
test: $(BUILD)/computer_tb.vvp $(DATA) $(BUILD)/os.img
	cd $(BUILD) && vvp computer_tb.vvp

$(BUILD)/computer_tb.vvp: computer_tb.v $(COMPUTER) $(MODELS)
	mkdir -p $(BUILD)
	iverilog -g2005 -DMP32_SIM -s computer_tb -o $@ $^

# the I/O decoder alone: LEDS, BUTTONS, TICKS, CTRL and the buttons' interrupt
test-iodec: $(BUILD)/iodec_tb.vvp
	cd $(BUILD) && vvp iodec_tb.vvp

$(BUILD)/iodec_tb.vvp: iodec_tb.v iodec.v ../cpu/irqc.v
	mkdir -p $(BUILD)
	iverilog -g2005 -s iodec_tb -o $@ $^

# ---------------------------------------------------------------- the board
board: $(BUILD)/top.fs

$(BUILD)/top.json: $(BOARD) $(DATA)
	cd $(BUILD) && yosys -q -l synth.log -p "read_verilog $(addprefix ../,$(BOARD)); \
		synth_gowin -top top -json top.json"

$(BUILD)/top_pnr.json: $(BUILD)/top.json top.cst
	nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=top.cst --freq $(FREQ) \
		2>&1 | tee $(BUILD)/pnr.log | grep -E "Max frequency|ERROR|Device utilisation" -A0

$(BUILD)/top.fs: $(BUILD)/top_pnr.json
	gowin_pack -d $(FAMILY) --mspi_as_gpio -o $@ $<

flash: $(BUILD)/top.fs
	openFPGALoader -b tangnano20k $<

burn: $(BUILD)/top.fs
	openFPGALoader -b tangnano20k -f $<

os-burn: $(BUILD)/os.img
	openFPGALoader -b tangnano20k --external-flash -o $(OS_FLASH) --file-type bin $<

os-send: $(BUILD)/os.img
	$(PYTHON) boot_serial.py --port $(PORT) --image $< --send-only

# The port is opened before the bitstream goes in, so nothing the board says is
# missed; the loader's lines are shown until it asks for the image, then the image
# goes out and the rest is shown.
boot-serial: $(BUILD)/top.fs $(BUILD)/os.img
	$(PYTHON) boot_serial.py --port $(PORT) --bitstream $(BUILD)/top.fs \
		--image $(BUILD)/os.img --wait $(WAIT)

clean:
	rm -rf $(BUILD)

.PHONY: all boot os test test-iodec board flash burn os-burn os-send boot-serial fonts-sd clean
.PRECIOUS: $(BUILD)/%.json $(BUILD)/boot.o $(BUILD)/os.o $(BUILD)/os.bin
