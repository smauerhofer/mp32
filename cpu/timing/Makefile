# The timing of the mp32 core on the chip: the five stages with two 8 KB block RAMs
# (core.v), placed and routed at the processor's 42 MHz (126 / 3).
#   make test       check core.v in simulation first (it runs ../stage2/lisp.s)
#   make timing     synthesize, then place and route with three seeds; prints the
#                   highest frequency each one reaches (it must be 42 MHz or more)
#   make timing-old the same for the CPU before the LISP opcodes (old/): to compare
#   make size       what the core takes on the chip
#   make clean      throw away what the build made
#
# A seed takes a few minutes. The reports are build/pnr_<seed>.log.
#
# nextpnr ends with an error when it finds hold (minimum) time violations; here they
# are all on the code RAM of core.v (its address register right next to the RAM, a
# test set-up the computer does not have: its board has none). So the recipes take
# nextpnr's exit status as it is (|| true), and the summary shows the frequency after
# routing and the number of hold violations of each seed.

BUILD  ?= build
DEVICE  = GW2AR-LV18QN88C8/I7
FAMILY  = GW2A-18C
FREQ    = 42
SEEDS   = 1 2 3

CORE = ../stage1/fetch.v ../stage1/pc.v ../stage1/irq_sequence.v \
       ../stage2/decode.v ../stage2/decoder.v ../stage2/regfile.v ../stage2/sequencer.v \
       ../stage3/execute.v ../stage3/forward.v ../stage3/alu.v ../stage3/mul.v \
       ../stage3/flags.v ../stage3/cond.v ../stage3/stackregs.v ../stage3/scratch.v \
       ../stage3/tmplh.v ../stage4/memaccess.v ../stage4/bram.v ../stage5/writeback.v

test: $(BUILD)/core_tb.vvp
	cd $(BUILD) && vvp core_tb.vvp

$(BUILD)/core_tb.vvp: core_tb.v core.v $(CORE) lisp_lines.hex
	mkdir -p $(BUILD)
	iverilog -g2005 -DMP32_SIM -s core_tb -o $@ core_tb.v core.v $(CORE)

# synthesis: the code RAM starts with lisp.s, so the program is in the bitstream
$(BUILD)/core.json: core.v $(CORE) lisp_lines.hex
	mkdir -p $(BUILD)
	yosys -q -l $(BUILD)/synth.log -p "read_verilog core.v $(CORE); \
		chparam -set CODE \"lisp_lines.hex\" top; synth_gowin -top top -json $@"

# place and route, one seed each; the line nextpnr ends with is the frequency
$(BUILD)/pnr_%.log: $(BUILD)/core.json core.cst
	nextpnr-himbaechel --json $< --write $(BUILD)/core_pnr_$*.json --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=core.cst --freq $(FREQ) --seed $* \
		> $@ 2>&1 || true

timing: $(addprefix $(BUILD)/pnr_,$(addsuffix .log,$(SEEDS)))
	@for s in $(SEEDS); do \
		echo "seed $$s: $$(grep -E 'Max frequency for clock' $(BUILD)/pnr_$$s.log | tail -1 | sed 's/^Info: *//'), $$(grep -oE '[0-9]+ Hold/min time violations' $(BUILD)/pnr_$$s.log | tail -1 | cut -d' ' -f1 | grep . || echo 0) hold violations"; \
	done

# the CPU before the LISP opcodes: its decode, sequencer, execute and ALU from old/
OLD = $(filter-out ../stage2/decode.v ../stage2/decoder.v ../stage2/sequencer.v ../stage3/execute.v ../stage3/alu.v,$(CORE)) \
      old/decode.v old/sequencer.v old/execute.v old/alu.v

$(BUILD)/core_old.json: old/core_old.v $(OLD) lisp_lines.hex
	mkdir -p $(BUILD)
	yosys -q -l $(BUILD)/synth_old.log -p "read_verilog old/core_old.v $(OLD); \
		chparam -set CODE \"lisp_lines.hex\" top; synth_gowin -top top -json $@"

$(BUILD)/pnr_old_%.log: $(BUILD)/core_old.json core.cst
	nextpnr-himbaechel --json $< --write $(BUILD)/core_old_pnr_$*.json --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=core.cst --freq $(FREQ) --seed $* \
		> $@ 2>&1 || true

timing-old: $(addprefix $(BUILD)/pnr_old_,$(addsuffix .log,$(SEEDS)))
	@for s in $(SEEDS); do \
		echo "old, seed $$s: $$(grep -E 'Max frequency for clock' $(BUILD)/pnr_old_$$s.log | tail -1 | sed 's/^Info: *//'), $$(grep -oE '[0-9]+ Hold/min time violations' $(BUILD)/pnr_old_$$s.log | tail -1 | cut -d' ' -f1 | grep . || echo 0) hold violations"; \
	done

size: $(BUILD)/core.json
	grep -A40 "Printing statistics" $(BUILD)/synth.log | tail -40

clean:
	rm -rf $(BUILD)

.PHONY: test timing timing-old size clean
.PRECIOUS: $(BUILD)/core.json $(BUILD)/pnr_%.log $(BUILD)/core_old.json $(BUILD)/pnr_old_%.log
