UUID := minibookx-input-toggle@isalin.github.com
EXT_DIR := $(HOME)/.local/share/gnome-shell/extensions/$(UUID)

.PHONY: help install uninstall reinstall schemas status logs unlock check

help:
	@echo "make install    install extension + daemon + scripts (uses sudo)"
	@echo "make uninstall  remove everything, releasing any lock first"
	@echo "make reinstall  uninstall then install"
	@echo "make schemas    recompile the GSettings schema only"
	@echo "make status     show current lock state and matched devices"
	@echo "make logs       follow the daemon journal"
	@echo "make unlock     emergency release"
	@echo "make check      syntax-check the daemon, scripts and extension"

install:
	@./install.sh

uninstall:
	@./uninstall.sh

reinstall: uninstall install

schemas:
	glib-compile-schemas extension/schemas/

status:
	@hid-toggle status

logs:
	@journalctl -u minibookx-hid-lock.service -f

unlock:
	@hid-emergency-unlock

check:
	@python3 -m py_compile daemon/hid-lock-daemon.py && echo "daemon: ok"
	@sh -n scripts/hid-toggle && echo "hid-toggle: ok"
	@sh -n scripts/hid-emergency-unlock && echo "hid-emergency-unlock: ok"
	@bash -n install.sh && echo "install.sh: ok"
	@bash -n uninstall.sh && echo "uninstall.sh: ok"
	@# node only parses; the gi:// and resource:// imports resolve inside gnome-shell.
	@cp extension/extension.js /tmp/minibookx-check.mjs && \
		node --check /tmp/minibookx-check.mjs && rm -f /tmp/minibookx-check.mjs && \
		echo "extension.js: ok"
	@python3 -c "import json,sys; json.load(open('extension/metadata.json'))" && echo "metadata.json: ok"
	@glib-compile-schemas --dry-run extension/schemas/ && echo "schema: ok"
