# HoverDict — convenience targets (CLT-only, no full Xcode needed).

APP := build/HoverDict.app
# Where `make run` / `make install` put the app. Login Items point here, so launching
# from build/ instead would leave a stale copy that comes back after a reboot.
INSTALLED_APP := /Applications/HoverDict.app

.PHONY: build test app install run stop dmg clean rebuild

# Compile the SwiftPM executable only (fast iteration / type-check).
build:
	swift build

# Unit tests for the pure logic (filter rules, hit testing, sense picking). No .app,
# dictionary or Screen Recording permission needed.
test:
	swift test

# Build the signed .app bundle.
app:
	./Scripts/build_app.sh

# Build, then replace the installed copy (quits any running instance first).
install: app stop
	rm -rf "$(INSTALLED_APP)"
	ditto "$(APP)" "$(INSTALLED_APP)"

# Build, install, then launch the installed copy. IMPORTANT: kill any running instance
# first (install does) — `open` will NOT relaunch an app that's already running (it just
# activates the stale process), so without this your code changes wouldn't take effect.
run: install
	open "$(INSTALLED_APP)"

# Quit any running instance, and wait (up to 5s) until it has exited: `open` right after
# killall can fail while the old process is still on its way out.
stop:
	-killall HoverDict 2>/dev/null || true
	@for i in $$(seq 50); do pgrep -x HoverDict >/dev/null || break; sleep 0.1; done

# Build a distributable .dmg (free / self-signed; recipients bypass Gatekeeper once).
dmg:
	./Scripts/make_dmg.sh

# Force a clean rebuild of the .app.
rebuild: clean app

clean:
	swift package clean
	rm -rf build/HoverDict.app
