# The mp32 processor: one folder for each stage of the pipeline, each with its own
# Makefile. This one runs them all.
#   make test           run the test benches of every stage
#   make test-stage1    run those of one stage
#   make clean          throw away what the builds made
STAGES = $(sort $(wildcard stage*))

test: $(addprefix test-,$(STAGES))

test-%:
	$(MAKE) -C $* test

clean-%:
	$(MAKE) -C $* clean

clean: $(addprefix clean-,$(STAGES))

.PHONY: test clean
