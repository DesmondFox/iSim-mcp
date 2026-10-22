PREFIX ?= $(HOME)/.local
BINARY := isim-mcp

.PHONY: build release install uninstall test clean

build:
	swift build

release:
	swift build -c release

install: release
	install -d "$(PREFIX)/bin"
	install -m 755 .build/release/$(BINARY) "$(PREFIX)/bin/$(BINARY)"
	@echo "Installed $(PREFIX)/bin/$(BINARY)"

uninstall:
	rm -f "$(PREFIX)/bin/$(BINARY)"

test:
	swift test

clean:
	swift package clean
