APP := build/Guachiman.app
BIN := $(APP)/Contents/MacOS/Guachiman
ICONS := icon/AppIcon.icns icon/MenuBarIcon.png icon/MenuBarIcon@2x.png
ICONSET := build/AppIcon.iconset

.PHONY: all run check test notify-test icon release clean relay-install relay-uninstall

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

# Publica una versión: make release VERSION=x.y.z (DRY_RUN=1 para ensayar).
release:
	@[ -n "$(VERSION)" ] || { echo "Uso: make release VERSION=x.y.z [DRY_RUN=1]" >&2; exit 1; }
	@scripts/release.sh "$(VERSION)"

RELAY_DIR := $(HOME)/Library/Application Support/Guachiman/relay
RELAY_PLIST := $(HOME)/Library/LaunchAgents/io.github.guachiman.relay.plist

# Relay de alertas (sesión de Claude Code en segundo plano). Ver relay/README.md.
relay-install:
	mkdir -p $(HOME)/Library/LaunchAgents "$(RELAY_DIR)"
	/bin/cp relay/start.sh relay/brief.md "$(RELAY_DIR)/"
	sed -e 's|@START@|$(RELAY_DIR)/start.sh|g' -e 's|@CWD@|$(CURDIR)|g' -e 's|@HOME@|$(HOME)|g' relay/io.github.guachiman.relay.plist > $(RELAY_PLIST)
	-launchctl bootout gui/$$(id -u) $(RELAY_PLIST) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(RELAY_PLIST)

relay-uninstall:
	-launchctl bootout gui/$$(id -u) $(RELAY_PLIST) 2>/dev/null
	rm -f $(RELAY_PLIST)
	rm -rf "$(RELAY_DIR)"
	-for f in $(HOME)/.claude/sessions/*.json; do grep -q '"name":"guachiman-relay"' $$f && $(HOME)/.local/bin/claude stop $$(sed -n 's/.*"jobId":"\([^"]*\)".*/\1/p' $$f); done; true

clean:
	rm -rf build
