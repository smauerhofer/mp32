# Stage 4 of the mp32 processor: memory access.
#   make test           run the test benches
#   make test-memaccess run one of them: memaccess or membus
#   make clean          throw away what the build made
BUILD ?= build

# The building blocks of this stage. Test benches pick what they need.
# wildcard keeps only the files that are already there, so you can build as you go.
BLOCKS = $(wildcard memaccess.v membus.v bram.v)

test: test-memaccess test-membus

# Simulation: iverilog compiles a test bench, vvp runs it.
$(BUILD)/%_tb.vvp: %_tb.v $(BLOCKS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s $*_tb -o $@ $^

test-%: $(BUILD)/%_tb.vvp
	cd $(BUILD) && vvp $*_tb.vvp

# What the chip makes of the bus and its block RAM
size: membus.v bram.v
	yosys -p "read_verilog $^; synth_gowin -top membus; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test size clean
.PRECIOUS: $(BUILD)/%_tb.vvp
