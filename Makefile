UUID := input-lock-x@isalin.github.io
EXT_DIR := $(HOME)/.local/share/gnome-shell/extensions/$(UUID)
BUILD := build

.PHONY: help install install-daemon uninstall reinstall schemas status logs unlock check test pack clean

help:
	@echo "make install         install extension + daemon + scripts (uses sudo)"
	@echo "make install-daemon  daemon + scripts only, leaving the extension alone"
	@echo "make uninstall       remove everything, releasing any lock first"
	@echo "make reinstall       uninstall then install"
	@echo "make schemas         recompile the GSettings schema only"
	@echo "make status          show current lock state and matched devices"
	@echo "make logs            follow the daemon journal"
	@echo "make unlock          emergency release"
	@echo "make check           syntax-check the daemon, scripts and extension"
	@echo "make test            run the classifier against this machine, no root needed"
	@echo "make pack            build the extensions.gnome.org zip"

install:
	@./install.sh

# For a machine whose extension came from extensions.gnome.org: installs the
# daemon and never touches ~/.local/share/gnome-shell/extensions.
install-daemon:
	@./install.sh --daemon-only

uninstall:
	@./uninstall.sh

reinstall: uninstall install

schemas:
	glib-compile-schemas extension/schemas/

status:
	@input-lock-x status

logs:
	@journalctl -u input-lock-x.service -f

unlock:
	@input-lock-x-emergency-unlock

check:
	@python3 -m py_compile daemon/input-lock-x-daemon.py && echo "daemon: ok"
	@python3 -m py_compile tests/classify-from-proc.py && echo "tests: ok"
	@sh -n scripts/input-lock-x && echo "input-lock-x: ok"
	@sh -n scripts/input-lock-x-emergency-unlock && echo "input-lock-x-emergency-unlock: ok"
	@bash -n install.sh && echo "install.sh: ok"
	@bash -n uninstall.sh && echo "uninstall.sh: ok"
	@bash -n lib/output.sh && echo "lib/output.sh: ok"
	@bash -n lib/paths.sh && echo "lib/paths.sh: ok"
	@bash -n lib/legacy-paths.sh && echo "lib/legacy-paths.sh: ok"
	@bash -n lib/release-lock.sh && echo "lib/release-lock.sh: ok"
	@# Optional: shellcheck catches the set -e and quoting traps `sh -n` cannot.
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning install.sh uninstall.sh \
			lib/output.sh lib/paths.sh lib/legacy-paths.sh lib/release-lock.sh \
			scripts/input-lock-x scripts/input-lock-x-emergency-unlock \
			&& echo "shellcheck: ok"; \
	else \
		echo "shellcheck: not installed, skipped"; \
	fi
	@# node only parses; the gi:// and resource:// imports resolve inside
	@# gnome-shell. mktemp, not a fixed /tmp name: a predictable path is a
	@# symlink someone else can plant, and two concurrent runs would collide.
	@# Optional like shellcheck: node is a syntax checker here, not a runtime
	@# dependency, and `make pack` runs this target -- so a machine without
	@# node must still be able to build the zip.
	@if command -v node >/dev/null 2>&1; then \
		for f in extension/extension.js extension/prefs.js extension/common.js; do \
			t=$$(mktemp --suffix=.mjs) && cp "$$f" "$$t" && \
			node --check "$$t"; rc=$$?; rm -f "$$t"; \
			[ $$rc -eq 0 ] || exit $$rc; \
			echo "$$(basename $$f): ok"; \
		done; \
	else \
		echo "node: not installed, JS syntax check skipped"; \
	fi
	@python3 -c "import json,sys; json.load(open('extension/metadata.json'))" && echo "metadata.json: ok"
	@glib-compile-schemas --dry-run extension/schemas/ && echo "schema: ok"

# Reads /proc/bus/input/devices instead of opening evdev nodes, so this runs as
# a normal user -- the point being to check what auto mode would grab on a new
# machine before handing it the keyboard.
test:
	@python3 tests/classify-from-proc.py

# Built from a staging copy so gschemas.compiled -- which a local `make schemas`
# leaves in the tree, and which extensions.gnome.org rejects -- cannot end up in
# the zip. The uuid in metadata.json names the output.
pack: check
	@rm -rf $(BUILD)
	@mkdir -p $(BUILD)
	@cp -r extension $(BUILD)/src
	@rm -f $(BUILD)/src/schemas/gschemas.compiled
	@cp LICENSE $(BUILD)/src/LICENSE
	@gnome-extensions pack --force -o $(BUILD) --extra-source=LICENSE --extra-source=common.js $(BUILD)/src
	@rm -rf $(BUILD)/src
	@echo
	@echo "$(BUILD)/$(UUID).shell-extension.zip"

# Only the build directory. gschemas.compiled is deliberately left alone:
# install.sh symlinks this repo's extension/ into ~/.local/share/gnome-shell,
# so the compiled schema in the tree IS the one the running shell loads.
# Deleting it makes getSettings() throw on the next login and the panel icon
# and shortcut both vanish. `make schemas` rebuilds it if it is ever lost.
clean:
	@rm -rf $(BUILD)
	@echo "cleaned"
