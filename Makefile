# Moorbox developer commands. Requirements: Xcode 16+, XcodeGen; SwiftLint/SwiftFormat for lint;
# create-dmg for `make dmg` (`brew install xcodegen swiftlint swiftformat create-dmg`).

VERSION := $(shell cat VERSION)
BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
DERIVED := .build/xcode
XCODEBUILD := xcodebuild -project Moorbox.xcodeproj -scheme Moorbox -derivedDataPath $(DERIVED)

.PHONY: project build run test test-core test-ui test-integration lint format app dmg clean

project: ## Generate Moorbox.xcodeproj from project.yml
	MOORBOX_VERSION=$(VERSION) MOORBOX_BUILD=$(BUILD) xcodegen generate --quiet

build: project ## Debug build
	$(XCODEBUILD) -configuration Debug build

run: build ## Build and open the debug app
	open $(DERIVED)/Build/Products/Debug/Moorbox.app

test: test-core test-ui ## Unit tests + UI tests

test-core: ## Core unit tests (no network, SDK or emulator needed)
	swift test

test-ui: project ## XCUITest UI tests (fake SDK; no network or emulator needed)
	$(XCODEBUILD) -only-testing:MoorboxUITests test

test-integration: ## Real network, Google tools and emulator (see Tests/.../IntegrationTests.swift)
	scripts/build-test-apk.sh
	MOORBOX_INTEGRATION=1 swift test --filter IntegrationTests

lint: ## SwiftFormat (check only) + SwiftLint (warnings fail)
	swiftformat --lint .
	swiftlint lint --strict --quiet

format: ## Apply SwiftFormat
	swiftformat .

app: project ## Universal Release build → dist/Moorbox.app
	scripts/package-app.sh

dmg: app ## dist/Moorbox-<version>.dmg (needs create-dmg)
	scripts/make-dmg.sh

clean:
	rm -rf .build dist Moorbox.xcodeproj App/Info.plist
