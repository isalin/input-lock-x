/* Input Lock X
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Adds a panel button and a Ctrl+Esc shortcut that lock the internal keyboard
 * and touchpad. The actual locking is done by input-lock-x.service, a root
 * daemon that takes an exclusive EVIOCGRAB on those devices; this extension
 * only starts and stops that unit over systemd's D-Bus API.
 *
 * The daemon's state file is the single source of truth for the UI. We never
 * assume we know the state -- the daemon can release itself when it sees
 * Ctrl+Esc in its own grabbed stream, and the scripts can be used over SSH.
 * Watching the file keeps the icon honest no matter who made the change.
 *
 * The daemon is not part of this extension and cannot be: it needs root. So
 * everything here has to behave sensibly when it is absent, which is exactly
 * what a fresh install from extensions.gnome.org looks like.
 */

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {
    UNIT, STATE_PATH, KEYBINDING, REPO_URL,
    SYSTEMD_NAME, SYSTEMD_PATH, SYSTEMD_MANAGER,
    probeUnit, isAuthDenied, AUTH_DENIED_HINT,
} from './common.js';

// The file monitor is the primary signal; this is a cheap backstop in case an
// inotify event is ever missed and the icon is left showing the wrong state.
const POLL_INTERVAL_SECONDS = 10;

// Probing for the unit is a system-bus round trip, and unlike the state file
// the answer only changes when someone installs or removes the daemon -- which
// runs daemon-reload, which we hear about on the Reloading signal. So the poll
// probes a tenth as often, as a backstop for a unit file dropped in by hand.
const PROBE_EVERY_N_POLLS = 6;

// After asking systemd to start or stop the unit, how long to wait for the
// state file to agree before calling it a failure. The daemon can spend up to
// two seconds waiting for held modifiers to come up before it grabs.
const SETTLE_INTERVAL_MS = 300;
const SETTLE_ATTEMPTS = 20;

const ICON_UNLOCKED = 'input-keyboard-symbolic';
const ICON_LOCKED = 'changes-prevent-symbolic';
const ICON_MISSING = 'dialog-warning-symbolic';

const InputLockButton = GObject.registerClass(
class InputLockButton extends PanelMenu.Button {
    _init(onActivate) {
        // dontCreateMenu: this is a plain toggle, a menu would just add a step
        // between a fingertip and the thing it wants to do.
        super._init(0.0, 'Input Lock X', true);

        this._onActivate = onActivate;
        this._locked = false;
        this._installed = true;

        this._icon = new St.Icon({
            icon_name: ICON_UNLOCKED,
            style_class: 'system-status-icon',
        });
        this.add_child(this._icon);
        this.add_style_class_name('input-lock-x-toggle');
    }

    /* Handle touch as well as pointer: in tablet mode the touchscreen is the
     * only working input device, and it is the way back from a locked state.
     * Touch is unconditional -- it has no button to check.
     *
     * Pointer presses are restricted to the primary button. PanelMenu.Button
     * toggles on any button, but that opens a menu; this disables the keyboard
     * and touchpad, so a stray right- or middle-click should not do it. Nothing
     * else would absorb them either: the button is built with dontCreateMenu,
     * which leaves the base gesture disabled and this.menu a PopupDummyMenu. */
    vfunc_event(event) {
        const type = event.type();
        if (type === Clutter.EventType.TOUCH_BEGIN ||
            (type === Clutter.EventType.BUTTON_PRESS &&
             event.get_button() === Clutter.BUTTON_PRIMARY)) {
            this._onActivate();
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }

    setLocked(locked) {
        this._locked = locked;
        this._update();
    }

    setInstalled(installed) {
        this._installed = installed;
        this._update();
    }

    /* One place that turns (locked, installed) into what the panel shows.
     * "Not installed" outranks the lock state: without the daemon nothing can
     * be locked, so showing a normal keyboard icon would be a lie that only
     * comes apart when the user taps it. */
    _update() {
        if (!this._installed) {
            this._icon.icon_name = ICON_MISSING;
            this.remove_style_class_name('input-lock-x-locked');
            this.add_style_class_name('input-lock-x-missing');
            this.accessible_name = 'Input Lock X: daemon not installed';
            return;
        }

        this.remove_style_class_name('input-lock-x-missing');
        this._icon.icon_name = this._locked ? ICON_LOCKED : ICON_UNLOCKED;
        if (this._locked)
            this.add_style_class_name('input-lock-x-locked');
        else
            this.remove_style_class_name('input-lock-x-locked');

        this.accessible_name = this._locked
            ? 'Keyboard and touchpad disabled'
            : 'Keyboard and touchpad enabled';
    }
});

export default class InputLockXExtension extends Extension {
    /* The shell does not call disable() when enable() throws -- it only
     * unloads the stylesheet and logs -- so everything registered before the
     * throw leaks. The panel button is the one that bites: the shell tracks it
     * by role, and a leaked one makes the next reload die on "Extension point
     * conflict" instead of the original error, which is a far harder thing to
     * diagnose. Tear our own state down, then re-raise so the shell still
     * records the real cause. disable() is null-safe at every step, so it
     * copes with however far setup got.
     *
     * getSettings() is the realistic thrower: schemas/gschemas.compiled is
     * gitignored and install.sh symlinks this repo into the extensions dir,
     * so a tree that never ran `make schemas` has no compiled schema. */
    enable() {
        try {
            this._setUp();
        } catch (e) {
            this.disable();
            throw e;
        }
    }

    _setUp() {
        this._locked = this._readState();
        // Assume installed until the probe says otherwise, so a slow bus does
        // not flash a warning icon on every login.
        this._installed = true;
        this._pending = false;
        this._pendingId = 0;
        this._keybindingWanted = false;
        this._keybindingAdded = false;
        this._pollTick = 0;
        this._reloadId = 0;
        this._cancellable = new Gio.Cancellable();

        this._settings = this.getSettings();
        // _installed is still optimistically true here, so a normal install
        // binds immediately; the probe below unbinds within milliseconds if
        // the daemon turns out to be missing.
        this._syncKeybinding();

        this._monitor = Gio.File.new_for_path(STATE_PATH)
            .monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
        this._monitorId = this._monitor.connect('changed',
            () => this._refresh());

        // Both install.sh and uninstall.sh end in daemon-reload, and that is
        // the only way the unit can appear or disappear underneath a running
        // shell. Reloading(false) means that reload has finished, so it is the
        // moment to look again. Not UnitFilesChanged: that only tracks the
        // enabled and masked lists, and this unit is deliberately static.
        this._reloadId = Gio.DBus.system.signal_subscribe(
            SYSTEMD_NAME, SYSTEMD_MANAGER, 'Reloading', SYSTEMD_PATH,
            null, Gio.DBusSignalFlags.NONE,
            (_conn, _sender, _path, _iface, _signal, params) => {
                const [active] = params.deepUnpack();
                if (!active)
                    this._probeInstall();
            });

        this._pollId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT_IDLE, POLL_INTERVAL_SECONDS, () => {
                this._refresh();
                // Installing the daemon after the extension is the documented
                // path, and it does not restart the shell. The Reloading
                // subscription catches that within a second; this is only the
                // backstop for a unit file that appeared without a reload.
                // Only while missing, so the normal case costs no bus traffic.
                if (!this._installed && ++this._pollTick >= PROBE_EVERY_N_POLLS) {
                    this._pollTick = 0;
                    this._probeInstall();
                }
                return GLib.SOURCE_CONTINUE;
            });

        // Registered last, on purpose: this is the only thing the shell holds a
        // reference to by name, so nothing above can strand it. _refresh() and
        // _probeInstall() both reach for this._button through `?.`, so the
        // callbacks wired up above are safe until it exists.
        this._button = new InputLockButton(() => this._toggle());
        this._button.setLocked(this._locked);
        Main.panel.addToStatusArea(this.uuid, this._button, 0, 'right');

        this._probeInstall();
    }

    disable() {
        // Deliberately does not stop the daemon. A lock that survives a shell
        // restart is a feature: the grab is still releasable with Ctrl+Esc, and
        // stopping it here would silently re-enable input on every lock screen.

        // The shell disables us on the lock screen, so an in-flight call or a
        // pending timeout would otherwise come back to a torn-down extension
        // and try to raise a notification from it.
        this._cancellable?.cancel();
        this._cancellable = null;

        if (this._reloadId) {
            Gio.DBus.system.signal_unsubscribe(this._reloadId);
            this._reloadId = 0;
        }

        this._clearPendingTimeout();

        if (this._pollId) {
            GLib.Source.remove(this._pollId);
            this._pollId = null;
        }

        if (this._monitor) {
            this._monitor.disconnect(this._monitorId);
            this._monitor.cancel();
            this._monitor = null;
            this._monitorId = null;
        }

        if (this._keybindingAdded) {
            Main.wm.removeKeybinding(KEYBINDING);
            this._keybindingAdded = false;
        }
        this._settings = null;

        this._button?.destroy();
        this._button = null;
    }

    _readState() {
        return Gio.File.new_for_path(STATE_PATH).query_exists(null);
    }

    /* Hold the shortcut only while there is a daemon to answer it. Ctrl+Esc is
     * a chord real applications use -- editors, IDEs, VM and RDP windows -- and
     * mutter's grab is system-wide, so binding it when the daemon is absent
     * takes the key away from everything else in exchange for a notification
     * saying we cannot help.
     *
     * Two flags, not one. _keybindingWanted is the state we last acted on, and
     * it makes this idempotent: this runs on every probe, and neither call is
     * free -- mutter warns on a duplicate add ("Trying to re-add keybinding")
     * and on a remove of a name it does not hold ("Trying to remove
     * non-existent keybinding"). _keybindingAdded is whether mutter actually
     * holds the chord, which differs from wanted when the add is refused, and
     * is what disable() needs so it does not retract a binding it never got. */
    _syncKeybinding() {
        if (!this._settings || this._installed === this._keybindingWanted)
            return;
        this._keybindingWanted = this._installed;

        if (!this._installed) {
            if (this._keybindingAdded) {
                Main.wm.removeKeybinding(KEYBINDING);
                this._keybindingAdded = false;
            }
            return;
        }

        const action = Main.wm.addKeybinding(
            KEYBINDING,
            this._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
            () => this._toggle());
        // Not a contended accelerator: mutter refuses on a duplicate *name*,
        // and is happy to let two bindings want the same keys. So this means
        // our own bookkeeping slipped, or a second copy of the extension is
        // loaded. Worth a line, because the symptom is a shortcut that
        // silently does nothing while the panel button keeps working.
        if (action === Meta.KeyBindingAction.NONE) {
            console.warn(`[input-lock-x] ${KEYBINDING} is already registered; the shortcut will not work`);
            return;
        }
        this._keybindingAdded = true;
    }

    /* Nothing this extension does works without the daemon, and installing
     * only the extension from extensions.gnome.org is a completely ordinary
     * way to arrive here. Say so on the icon rather than letting the first tap
     * fail with a D-Bus error nobody outside this project can read. */
    _probeInstall() {
        probeUnit(this._cancellable, (state, error) => {
            // disable() ran while the call was in flight.
            if (!this._cancellable)
                return;

            if (error) {
                // Not a diagnosis -- leave the button usable so the real
                // failure surfaces on tap instead of a confident wrong answer.
                console.warn(`[input-lock-x] could not probe ${UNIT}: ${error.message}`);
                return;
            }

            // Only on the edge into missing. This runs on a timer, and a
            // warning repeated every minute for the life of the session is
            // noise in someone else's journal, not a diagnostic.
            const wasInstalled = this._installed;
            this._installed = state !== null;
            if (!this._installed && wasInstalled)
                console.warn(`[input-lock-x] ${UNIT} is not installed`);

            this._button?.setInstalled(this._installed);
            this._syncKeybinding();
        });
    }

    /* Re-read the state file and reconcile the UI with it. Notifies only on an
     * actual transition, which also debounces the burst of events a file
     * monitor emits for a single create or delete. */
    _refresh() {
        const locked = this._readState();
        if (locked === this._locked)
            return;

        this._locked = locked;
        this._pending = false;
        this._button?.setLocked(locked);
        Main.notify(locked ? 'Input Disabled' : 'Input Enabled');
    }

    _toggle() {
        // The daemon is a separate, root-owned install step. Saying so is far
        // more useful than letting StartUnit fail with a D-Bus error nobody
        // outside this project can interpret.
        if (!this._installed) {
            Main.notify('Input Lock X is not set up',
                `${UNIT} is not installed. The extension needs its companion ` +
                `daemon, which is installed separately: ${REPO_URL}`);
            return;
        }

        if (this._pending)
            return;
        this._pending = true;

        const wantLocked = !this._locked;
        const method = wantLocked ? 'StartUnit' : 'StopUnit';

        Gio.DBus.system.call(
            SYSTEMD_NAME, SYSTEMD_PATH, SYSTEMD_MANAGER,
            method,
            new GLib.Variant('(ss)', [UNIT, 'replace']),
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            this._cancellable,
            (connection, result) => {
                // A reply already in flight when disable() ran still lands
                // here; cancelling cannot recall it. Without this the success
                // path below would arm a timeout nothing will ever remove.
                if (!this._cancellable)
                    return;

                try {
                    connection.call_finish(result);
                } catch (e) {
                    if (e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        return;
                    this._pending = false;
                    console.error(`[input-lock-x] ${method} failed: ${e.message}`);
                    Main.notify(...this._failureMessage(e));
                    return;
                }

                // StartUnit/StopUnit return once the job is *enqueued*, not
                // once it has run -- so this success says nothing about
                // whether the daemon grabbed anything. A unit that fails to
                // start still replies successfully here. The state file is
                // the only thing that actually answers the question.
                this._awaitState(wantLocked, 0);
            });
    }

    /* Turn a D-Bus error into something a user can act on. */
    _failureMessage(e) {
        if (isAuthDenied(e))
            return ['Not allowed to toggle the input lock', AUTH_DENIED_HINT];
        return ['Input lock toggle failed', e.message];
    }

    /* Poll until the state file agrees with what we asked for, or give up and
     * say so. Complements the file monitor: the monitor keeps the icon honest,
     * this turns a lock that never engaged into a visible failure rather than
     * a tap that silently did nothing. */
    _awaitState(wantLocked, attempt) {
        this._clearPendingTimeout();
        this._pendingId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, SETTLE_INTERVAL_MS, () => {
                this._pendingId = 0;
                this._refresh();

                if (this._locked === wantLocked) {
                    this._pending = false;
                    return GLib.SOURCE_REMOVE;
                }

                if (attempt + 1 >= SETTLE_ATTEMPTS) {
                    this._pending = false;
                    const verb = wantLocked ? 'engage' : 'release';
                    console.error(`[input-lock-x] ${UNIT} did not ${verb}`);
                    Main.notify('Input lock toggle failed',
                        `${UNIT} did not ${verb} — check journalctl -u ${UNIT}`);
                    return GLib.SOURCE_REMOVE;
                }

                this._awaitState(wantLocked, attempt + 1);
                return GLib.SOURCE_REMOVE;
            });
    }

    _clearPendingTimeout() {
        if (this._pendingId) {
            GLib.Source.remove(this._pendingId);
            this._pendingId = 0;
        }
    }
}
