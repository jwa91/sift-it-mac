# The app is a thin client of sift-it's engine: build it, run it, check it, release it.

.PHONY: build run install check icon release snapshot clean

VERSION_IN_PLIST := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

build:
	scripts/bundle.sh

run: build
	-pkill -x SiftIt
	open "build/Sift It.app"

install: build
	-pkill -x SiftIt
	rm -rf "/Applications/Sift It.app"
	cp -R "build/Sift It.app" /Applications/
	open "/Applications/Sift It.app"

check:
	swift format lint --strict --recursive Package.swift Sources Tests
	swift build -Xswiftc -warnings-as-errors
	swift test

icon:
	swift scripts/make-icon.swift

# A release, from this Mac: checked, built, signed and notarized with its keychain (scripts/codesign.sh says what it
# needs), published as a GitHub release, and the cask committed to jwa91/tap, both with your gh login.
# Requires Resources/Info.plist at $(VERSION) and the v$(VERSION) tag at HEAD, pushed. Nothing is built or published
# until every check passes.
release:
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=X.Y.Z" && exit 2)
	@test "$(VERSION)" = "$(VERSION_IN_PLIST)" || (echo "Resources/Info.plist says $(VERSION_IN_PLIST), not $(VERSION)" && exit 2)
	@gh auth status >/dev/null 2>&1 || (echo "gh not authenticated: gh auth login" && exit 1)
	@scripts/codesign.sh --check
	@existing=$$(git rev-parse -q --verify "v$(VERSION)^{commit}" 2>/dev/null); \
	head=$$(git rev-parse HEAD); \
	test -n "$$existing" && test "$$existing" = "$$head" || \
	  (echo "v$(VERSION) must exist and point at HEAD before release"; exit 3)
	$(MAKE) check
	scripts/release.sh $(VERSION)

# What a release would make, in dist/, signed ad hoc and unpublished (CI runs this too).
snapshot:
	scripts/release.sh --snapshot

clean:
	rm -rf .build build dist
