# The app is a thin client of sift-it's engine: build it, run it, check it.

.PHONY: build run install check icon clean

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

clean:
	rm -rf .build build
