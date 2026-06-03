# HoverDict — convenience targets (CLT-only, no full Xcode needed).

APP := build/HoverDict.app

.PHONY: build app run clean rebuild

# Compile the SwiftPM executable only (fast iteration / type-check).
build:
	swift build

# Build the signed .app bundle.
app:
	./Scripts/build_app.sh

# Build then launch the .app. IMPORTANT: kill any running instance first — `open` will
# NOT relaunch an app that's already running (it just activates the stale process), so
# without this your code changes wouldn't take effect.
run: app stop
	open "$(APP)"

# Quit any running instance.
stop:
	-killall HoverDict 2>/dev/null || true

# Build a distributable .dmg (free / self-signed; recipients bypass Gatekeeper once).
dmg:
	./Scripts/make_dmg.sh

# Force a clean rebuild of the .app.
rebuild: clean app

clean:
	swift package clean
	rm -rf build/HoverDict.app
