APP := build/Guachiman.app
BIN := $(APP)/Contents/MacOS/Guachiman
ICONS := icon/AppIcon.icns icon/MenuBarIcon.png icon/MenuBarIcon@2x.png
ICONSET := build/AppIcon.iconset

.PHONY: all run check test notify-test icon clean

all: $(BIN)

$(BIN): guachiman.swift Info.plist $(ICONS)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O -target $$(uname -m)-apple-macos13.0 guachiman.swift -o $(BIN)
	cp Info.plist $(APP)/Contents/Info.plist
	cp $(ICONS) $(APP)/Contents/Resources/
	codesign -s - --force $(APP)

# Regenera los íconos desde icon/*.svg. No forma parte del build normal.
icon:
	rm -rf $(ICONSET) && mkdir -p $(ICONSET)
	for s in 16 32 128 256 512; do \
		swift icon/render.swift icon/app.svg $(ICONSET)/icon_$${s}x$${s}.png $$s; \
		swift icon/render.swift icon/app.svg $(ICONSET)/icon_$${s}x$${s}@2x.png $$((s * 2)); \
	done
	iconutil -c icns $(ICONSET) -o icon/AppIcon.icns
	swift icon/render.swift icon/menubar.svg icon/MenuBarIcon.png 20 18
	swift icon/render.swift icon/menubar.svg icon/MenuBarIcon@2x.png 40 36

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
