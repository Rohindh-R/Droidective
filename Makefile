.PHONY: generate build test run dmg clean

# Optional telemetry keys for local builds. Create .env.telemetry (gitignored)
# with SENTRY_DSN=... and POSTHOG_KEY=... to enable crash/analytics locally.
# Without it both stay empty, so neither SDK starts — fine for development.
-include .env.telemetry
TELEMETRY := SENTRY_DSN="$(SENTRY_DSN)" POSTHOG_KEY="$(POSTHOG_KEY)"

generate:
	xcodegen generate

build: generate
	xcodebuild -project Droidective.xcodeproj -scheme App -configuration Debug -derivedDataPath DerivedData build $(TELEMETRY)

test:
	cd ADBKit && swift test

run: build
	-pkill -x Droidective
	@sleep 0.3
	open "DerivedData/Build/Products/Debug/Droidective.app"

dmg: generate
	xcodebuild -project Droidective.xcodeproj -scheme App -configuration Release -derivedDataPath DerivedData build $(TELEMETRY)
	./scripts/package-dmg.sh $(VERSION)

clean:
	rm -rf DerivedData ADBKit/.build *.xcodeproj
