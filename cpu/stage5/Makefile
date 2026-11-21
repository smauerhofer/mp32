# Stage 5 of the mp32 processor: writeback.
#   make test             run the test benches
#   make test-writeback   run one of them: writeback
#   make clean            throw away what the build made
BUILD ?= build

# The building blocks of this stage. Test benches pick what they need.
# wildcard keeps only the files that are already there, so you can build as you go.
BLOCKS = $(wildcard writeback.v)

# Stage 5 writes into the register file of stage 2: the test bench needs it too.
OTHERS = ../stage2/regfile.v

test: test-writeback

# Simulation: iverilog compiles a test bench, vvp runs it.
$(BUILD)/%_tb.vvp: %_tb.v $(BLOCKS) $(OTHERS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s $*_tb -o $@ $^

test-%: $(BUILD)/%_tb.vvp
	cd $(BUILD) && vvp $*_tb.vvp

clean:
	rm -rf $(BUILD)

.PHONY: test clean
.PRECIOUS: $(BUILD)/%_tb.vvp
