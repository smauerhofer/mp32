# The video unit, with its screen in the SDRAM: test it, and see what the chip makes
# of it.
#   make test          run the test bench, at 100 MHz (writes mixed.bmp, text.bmp,
#                      graphics.bmp, shape.bmp and scrolled.bmp into build/)
#   make test-clocks   run it at 54 and 100 MHz
#   make size          synthesize the video unit alone and count what it takes
#   make data          make palette.hex, fonts.hex, text.hex, pixels.hex and
#                      modes.hex again
#   make clean
#
# The test bench needs the cache, the SDRAM controller and the SDRAM model from
# ../cache.

BUILD ?= build
CACHE  = ../cache

BLOCKS = video.v $(CACHE)/cache.v $(CACHE)/sdram.v
MODELS = $(CACHE)/sdram_model.v
DATA   = $(BUILD)/fonts.hex $(BUILD)/palette.hex $(BUILD)/text.hex $(BUILD)/pixels.hex \
         $(BUILD)/modes.hex

test: test-video

$(BUILD)/%.hex: %.hex
	mkdir -p $(BUILD)
	cp $< $@

$(BUILD)/video_tb.vvp: video_tb.v $(BLOCKS) $(MODELS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s video_tb -o $@ $^

test-video: $(BUILD)/video_tb.vvp $(DATA)
	cd $(BUILD) && vvp video_tb.vvp

CLOCKS = 54 100

$(BUILD)/video_tb_%mhz.vvp: video_tb.v $(BLOCKS) $(MODELS)
	mkdir -p $(BUILD)
	iverilog -g2005 -s video_tb -Pvideo_tb.CLK_MHZ=$* -o $@ $^

test-clocks: $(foreach f,$(CLOCKS),$(BUILD)/video_tb_$(f)mhz.vvp) $(DATA)
	cd $(BUILD) && for f in $(CLOCKS); do echo "--- $$f MHz"; vvp video_tb_$${f}mhz.vvp; done

palette.hex: tools/make_palette.py
	python3 tools/make_palette.py $@

fonts.hex: font.hex tools/make_fonts.py
	python3 tools/make_fonts.py font.hex $@

text.hex pixels.hex modes.hex: tools/make_demo.py
	python3 tools/make_demo.py text.hex pixels.hex modes.hex

data: palette.hex fonts.hex text.hex pixels.hex modes.hex

size: video.v
	yosys -p "read_verilog $^; synth_gowin -top video; stat"

clean:
	rm -rf $(BUILD)

.PHONY: test test-video test-clocks size data clean
.PRECIOUS: $(BUILD)/video_tb.vvp $(BUILD)/video_tb_%mhz.vvp
