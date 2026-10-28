APP := build/Guachiman.app
BIN := $(APP)/Contents/MacOS/Guachiman

.PHONY: all run check test notify-test clean

all: $(BIN)

$(BIN): guachiman.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	swiftc -O -target $$(uname -m)-apple-macos13.0 guachiman.swift -o $(BIN)
	cp Info.plist $(APP)/Contents/Info.plist
	codesign -s - --force $(APP)

run: all
	open $(APP)

check: all
	$(BIN) --once

test: all
	$(BIN) --selftest

notify-test: all
	open $(APP) --args --notify-test

clean:
	rm -rf build
