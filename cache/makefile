# The cache and the SDRAM controller: test them, and see what the chip makes of them.
#   make test          run the test bench, at 27 MHz
#   make test-clocks   run it again at 27, 42 (the processor's clock), 54 and 100 MHz
#   make size          synthesize the cache alone and count what it takes
#   make clean
#
# There is no circuit for the board here: the cache goes there inside the computer.

BUILD ?= build

# The building blocks of the cache. Circuits and test benches pick what they need.
BLOCKS = cache.v sdram.v

# Only the test benches need the model of the SDRAM.
MODELS = sdram_model.v

test: test-cache

# Simulation: iverilog compiles a test bench, vvp runs it.
$(BUILD)/%_tb.vvp: %_tb.v $(BLOCKS) $(MODELS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s $*_tb -o $@ $^

test-%: $(BUILD)/%_tb.vvp
	cd $(BUILD) && vvp $*_tb.vvp

# The same test bench at other clocks. -P sets its parameter CLK_MHZ, which
# it hands down to the cache, so each clock is a test bench of its own.
CLOCKS = 27 42 54 100

$(BUILD)/cache_tb_%mhz.vvp: cache_tb.v $(BLOCKS) $(MODELS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s cache_tb -Pcache_tb.CLK_MHZ=$* -o $@ $^

test-clocks: $(foreach f,$(CLOCKS),$(BUILD)/cache_tb_$(f)mhz.vvp)
	cd $(BUILD) && for f in $(CLOCKS); do echo "--- $$f MHz"; vvp cache_tb_$${f}mhz.vvp; done

# What the chip makes of it: the cache on its own, as if its ports were pins.
size: $(BLOCKS)
	yosys -p "read_verilog $^; synth_gowin -top cache; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test test-clocks size clean
.PRECIOUS: $(BUILD)/%_tb.vvp $(BUILD)/cache_tb_%mhz.vvp
