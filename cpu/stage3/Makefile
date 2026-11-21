# Stage 3 of the mp32 processor: execute.
#   make test           run the test benches
#   make test-alu       run one of them: stackregs, forward, alu, mul, tmplh, cond
#                       or execute (the whole stage, with stages 2, 4 and 5)
#   make size           what the ALU takes on the chip (and that MUL uses the
#                       on-chip multiplier)
#   make size-execute   what the whole stage takes
#   make clean          throw away what the build made
BUILD ?= build

# The building blocks of this stage. Test benches pick what they need.
# wildcard keeps only the files that are already there, so you can build as you go.
BLOCKS = $(wildcard stackregs.v forward.v scratch.v alu.v mul.v flags.v tmplh.v cond.v execute.v)

# The forwarding test runs a small pipeline: it needs the other stages too.
OTHERS = ../stage2/regfile.v ../stage4/memaccess.v ../stage5/writeback.v

test: test-stackregs test-forward test-alu test-mul test-tmplh test-cond test-execute

# Simulation: iverilog compiles a test bench, vvp runs it. MP32_SIM: mul.v uses its
# simulation model instead of the chip's multiplier.
$(BUILD)/%_tb.vvp: %_tb.v $(BLOCKS) $(OTHERS)
	mkdir -p $(BUILD)
	iverilog -g2005 -DMP32_SIM -s $*_tb -o $@ $^

test-%: $(BUILD)/%_tb.vvp
	cd $(BUILD) && vvp $*_tb.vvp

# What the chip makes of the ALU (without wide muxes: a fair count of LUTs). yosys
# knows the Gowin cells (MULT36X36 too) by itself: no extra cell library is read.
size: alu.v mul.v
	yosys -p "read_verilog $^; synth_gowin -top alu -nowidelut; stat"

size-execute: execute.v forward.v alu.v mul.v flags.v cond.v stackregs.v scratch.v tmplh.v
	yosys -p "read_verilog $^; synth_gowin -top execute -nowidelut; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test size size-execute clean
.PRECIOUS: $(BUILD)/%_tb.vvp
