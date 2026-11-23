# The mp32 computer on the Tang Nano 20K.
#   make test       the boot program, then the whole computer in simulation
#                   (computer_tb.v, with the model of the SDRAM)
#   make boot       only the boot program: build/boot.hex (and boot.lst, boot.map)
#   make board      synthesize, place and route, pack: build/top.fs
#   make flash      send it to the board (into its SRAM: gone after power-off)
#   make burn       write it into the board's flash (stays)
#   make clean      throw away what the build made
#
# The assembler and linker come from ../toolchain/bin: build the toolchain first
# (see ../toolchain/README.md). Everything is built in build/, where the memory files
# (boot.hex, fonts.hex, palette.hex) are put next to what reads them.

BUILD   ?= build
DEVICE   = GW2AR-LV18QN88C8/I7
FAMILY   = GW2A-18C
FREQ     = 42
TOOLS   ?= ../toolchain/bin
AS       = $(TOOLS)/mp32as
LD       = $(TOOLS)/mp32ld

CPU = ../cpu/cpu.v \
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
      ../sdcard/sdcard.v ../audio/audio.v ../display2/video.v raster.v tmds.v
COMPUTER = computer.v $(CPU) $(MEM) $(DEV)
BOARD    = top.v pll.v serializer.v $(COMPUTER)
DATA     = $(BUILD)/boot.hex $(BUILD)/fonts.hex $(BUILD)/palette.hex

all: test

# ---------------------------------------------------------------- the boot program
boot: $(BUILD)/boot.hex

$(BUILD)/boot.o: boot.s
	mkdir -p $(BUILD)
	$(AS) -o $@ -l $(BUILD)/boot.lst $<

$(BUILD)/boot.hex: $(BUILD)/boot.o boot.cfg
	$(LD) -C boot.cfg -o $@ -m $(BUILD)/boot.map $(BUILD)/boot.o

$(BUILD)/%.hex: ../display2/%.hex
	mkdir -p $(BUILD)
	cp $< $@

# ---------------------------------------------------------------- simulation
test: $(BUILD)/computer_tb.vvp $(DATA)
	cd $(BUILD) && vvp computer_tb.vvp

$(BUILD)/computer_tb.vvp: computer_tb.v $(COMPUTER) ../cache/sdram_model.v
	mkdir -p $(BUILD)
	iverilog -g2005 -DMP32_SIM -s computer_tb -o $@ $^

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
	gowin_pack -d $(FAMILY) -o $@ $<

flash: $(BUILD)/top.fs
	openFPGALoader -b tangnano20k $<

burn: $(BUILD)/top.fs
	openFPGALoader -b tangnano20k -f $<

clean:
	rm -rf $(BUILD)

.PHONY: all boot test board flash burn clean
.PRECIOUS: $(BUILD)/%.json $(BUILD)/boot.o
