# The address decoder: test it with the cache, the SDRAM model and the video unit.
#   make test          run the test bench, at 100 MHz
#   make size          synthesize the decoder alone and count what it takes
#   make clean

BUILD ?= build
CACHE  = ../cache
VIDEO  = ../display2

BLOCKS = decode.v $(CACHE)/cache.v $(CACHE)/sdram.v $(VIDEO)/video.v
MODELS = $(CACHE)/sdram_model.v

test: test-decode

$(BUILD)/decode_tb.vvp: decode_tb.v $(BLOCKS) $(MODELS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s decode_tb -o $@ $^

test-decode: $(BUILD)/decode_tb.vvp
	cd $(BUILD) && vvp decode_tb.vvp

size: decode.v
	yosys -p "read_verilog $^; synth_gowin -top decode; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test test-decode size clean
.PRECIOUS: $(BUILD)/decode_tb.vvp
