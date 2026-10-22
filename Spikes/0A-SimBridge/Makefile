BUILD := .build
BIN := $(BUILD)/simbridge-spike

$(BIN): SimBridgeSpike.m
	@mkdir -p $(BUILD)
	clang -fobjc-arc -Wall -O0 -g -framework Foundation -framework AppKit $< -o $@

clean:
	rm -rf $(BUILD)

.PHONY: clean
