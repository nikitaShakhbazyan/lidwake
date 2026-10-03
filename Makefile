# Builds with a Swift 6.2+ toolchain: Xcode 26, or the swift.org toolchain (works with just the
# Command Line Tools, e.g. on macOS 14), found automatically in the usual places.
SWIFT ?= $(or $(lastword $(wildcard $(HOME)/Library/Developer/Toolchains/swift-6.*.xctoolchain/usr/bin/swift /Library/Developer/Toolchains/swift-6.*.xctoolchain/usr/bin/swift)),swift)

.PHONY: build test install uninstall clean

build:
	$(SWIFT) build -c release

test:
	$(SWIFT) test

install: build
	scripts/install.sh

uninstall:
	scripts/install.sh --uninstall

clean:
	rm -rf .build
