# Stage 2 of the mp32 processor: decode.
#   make test             run the test benches
#   make test-decode      run one of them: regfile, sequencer, decode (the whole
#                         pipeline, fetch to writeback, on random machine code) or
#                         lisp (the LISP opcodes in a real program, lisp.s)
#   make size             what decode takes on the chip
#   make clean            throw away what the build made
BUILD ?= build

# The building blocks of this stage. Test benches pick what they need.
# wildcard keeps only the files that are already there, so you can build as you go.
BLOCKS = $(wildcard regfile.v sequencer.v decode.v)

# The sequencer is tested with the real fetch stage, decode with the whole pipeline.
OTHERS = ../stage1/fetch.v ../stage1/pc.v ../stage1/irq_sequence.v \
         ../stage3/execute.v ../stage3/forward.v ../stage3/alu.v ../stage3/mul.v \
         ../stage3/flags.v ../stage3/cond.v ../stage3/stackregs.v \
         ../stage3/scratch.v ../stage3/tmplh.v \
         ../stage4/memaccess.v ../stage5/writeback.v

test: test-regfile test-sequencer test-decode test-lisp

# Simulation: iverilog compiles a test bench, vvp runs it. MP32_SIM: mul.v uses its
# simulation model instead of the chip's multiplier.
$(BUILD)/%_tb.vvp: %_tb.v $(BLOCKS) $(OTHERS)
	mkdir -p $(BUILD)
	iverilog -g2005 -DMP32_SIM -s $*_tb -o $@ $^

test-%: $(BUILD)/%_tb.vvp
	cd $(BUILD) && vvp $*_tb.vvp

size: decode.v regfile.v sequencer.v
	yosys -p "read_verilog $^; synth_gowin -top decode -nowidelut; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test size clean
.PRECIOUS: $(BUILD)/%_tb.vvp
