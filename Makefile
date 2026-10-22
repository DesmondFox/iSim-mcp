PREFIX ?= $(HOME)/.local
BINARY := isim-mcp

.PHONY: build release install uninstall test test-app clean

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

# SwiftUI app for trying the UI tools on a simulator: login → list → detail, typing, system alerts.
TEST_APP := .build/TestApp/ISimTestApp.app

test-app:
	install -d $(TEST_APP)
	xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -parse-as-library \
		Tests/Fixtures/TestApp/ISimTestApp.swift -o $(TEST_APP)/ISimTestApp
	cp Tests/Fixtures/TestApp/Info.plist $(TEST_APP)/Info.plist
	codesign --force --sign - $(TEST_APP)
	@echo "Built $(TEST_APP) (bundle id dev.isimmcp.testapp)"

clean:
	swift package clean
