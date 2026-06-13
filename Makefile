.PHONY: generate build test run dmg clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project Droidective.xcodeproj -scheme App -configuration Debug -derivedDataPath DerivedData build

test:
	cd ADBKit && swift test

run: build
	open "DerivedData/Build/Products/Debug/Droidective.app"

dmg: generate
	xcodebuild -project Droidective.xcodeproj -scheme App -configuration Release -derivedDataPath DerivedData build
	./scripts/package-dmg.sh $(VERSION)

clean:
	rm -rf DerivedData ADBKit/.build *.xcodeproj
