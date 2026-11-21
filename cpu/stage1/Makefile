# Stage 1 of the mp32 processor: the fetch stage.
#   make test           run the test benches
#   make test-fetch     run one of them: pc, fetch
#   make clean          throw away what the build made
BUILD ?= build

# The building blocks of this stage. Test benches pick what they need.
# wildcard keeps only the files that are already there, so you can build as you go.
BLOCKS = $(wildcard pc.v irq_sequence.v fetch.v)

test: test-pc test-fetch

# Simulation: iverilog compiles a test bench, vvp runs it.
$(BUILD)/%_tb.vvp: %_tb.v $(BLOCKS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s $*_tb -o $@ $^

test-%: $(BUILD)/%_tb.vvp
	cd $(BUILD) && vvp $*_tb.vvp

clean:
	rm -rf $(BUILD)

.PHONY: test clean
.PRECIOUS: $(BUILD)/%_tb.vvp
