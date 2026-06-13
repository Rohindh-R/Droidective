.PHONY: generate build test run clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project Droidective.xcodeproj -scheme App -configuration Debug -derivedDataPath DerivedData build

test:
	cd ADBKit && swift test

run: build
	open "DerivedData/Build/Products/Debug/Droidective.app"

clean:
	rm -rf DerivedData ADBKit/.build *.xcodeproj
