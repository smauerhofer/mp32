# The sound of the mp32 computer: test it.
#   make test          run the test bench (audio.v at 42 MHz, with a model of the chip)
#   make size          synthesize the sound alone and count what it takes
#   make clean         throw away what the build made
#
# In the computer, audio.v goes behind the I/O decoder (at $FFFF_0300), with the pins
# in ../computer/top.cst.

BUILD  ?= build

BLOCKS = audio.v

test: $(BUILD)/audio_tb.vvp
	cd $(BUILD) && vvp audio_tb.vvp

# Simulation: iverilog compiles the test bench, vvp runs it.
$(BUILD)/audio_tb.vvp: audio_tb.v $(BLOCKS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s audio_tb -o $@ $^

# What the chip makes of it, as if its ports were pins.
size: $(BLOCKS)
	yosys -p "read_verilog $^; synth_gowin -top audio; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test size clean
.PRECIOUS: $(BUILD)/audio_tb.vvp
