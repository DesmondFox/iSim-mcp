PREFIX ?= $(HOME)/.local
BINARY := isim-mcp

.PHONY: build release install uninstall test test-app test-app-device clean

build:
	swift build

release:
	swift build -c release

# The UI agent's Xcode project goes along: the server builds it for each team that signs it.
install: release
	install -d "$(PREFIX)/bin" "$(PREFIX)/share/isim-mcp"
	install -m 755 .build/release/$(BINARY) "$(PREFIX)/bin/$(BINARY)"
	rm -rf "$(PREFIX)/share/isim-mcp/Agent"
	rsync -a --exclude xcuserdata Agent/ "$(PREFIX)/share/isim-mcp/Agent/"
	@echo "Installed $(PREFIX)/bin/$(BINARY) and $(PREFIX)/share/isim-mcp/Agent"

uninstall:
	rm -f "$(PREFIX)/bin/$(BINARY)"
	rm -rf "$(PREFIX)/share/isim-mcp"

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

# The same app for an iPhone, signed by TEAM: make test-app-device TEAM=AB12CD34EF DEVICE=<udid>
test-app-device:
	@test -n "$(TEAM)" || (echo "Pass TEAM=<development team id>" && exit 1)
	xcodebuild build -project Tests/Fixtures/TestApp/ISimTestApp.xcodeproj -scheme ISimTestApp \
		-destination $(if $(DEVICE),id=$(DEVICE),generic/platform=iOS) -derivedDataPath .build/TestApp-device \
		-allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM) -quiet
	@echo "Built .build/TestApp-device/Build/Products/Debug-iphoneos/ISimTestApp.app (bundle id dev.isimmcp.testapp.$(TEAM))"

clean:
	swift package clean
