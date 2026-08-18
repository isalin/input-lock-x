/* Minibook X Input Toggle
 *
 * Adds a panel button and a Ctrl+Esc shortcut that lock the internal keyboard
 * and touchpad. The actual locking is done by minibookx-hid-lock.service, a
 * root daemon that takes an exclusive EVIOCGRAB on those devices; this
 * extension only starts and stops that unit over systemd's D-Bus API.
 *
 * The daemon's state file is the single source of truth for the UI. We never
 * assume we know the state -- the daemon can release itself when it sees
 * Ctrl+Esc in its own grabbed stream, and the scripts can be used over SSH.
 * Watching the file keeps the icon honest no matter who made the change.
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

const UNIT = 'minibookx-hid-lock.service';
const STATE_PATH = '/run/minibookx-hid-lock.state';
const KEYBINDING = 'toggle-hid';

// The file monitor is the primary signal; this is a cheap backstop in case an
// inotify event is ever missed and the icon is left showing the wrong state.
const POLL_INTERVAL_SECONDS = 10;

// After asking systemd to start or stop the unit, how long to wait for the
// state file to agree before calling it a failure. The daemon can spend up to
// two seconds waiting for held modifiers to come up before it grabs.
const SETTLE_INTERVAL_MS = 300;
const SETTLE_ATTEMPTS = 20;

const ICON_UNLOCKED = 'input-keyboard-symbolic';
const ICON_LOCKED = 'changes-prevent-symbolic';

const HidToggleButton = GObject.registerClass(
class HidToggleButton extends PanelMenu.Button {
    _init(onActivate) {
        // dontCreateMenu: this is a plain toggle, a menu would just add a step
        // between a fingertip and the thing it wants to do.
        super._init(0.0, 'Minibook X Input Toggle', true);

        this._onActivate = onActivate;

        this._icon = new St.Icon({
            icon_name: ICON_UNLOCKED,
            style_class: 'system-status-icon',
        });
        this.add_child(this._icon);
        this.add_style_class_name('minibookx-hid-toggle');
    }

    // Handle touch as well as pointer: in tablet mode the touchscreen is the
    // only working input device, and it is the way back from a locked state.
    vfunc_event(event) {
        const type = event.type();
        if (type === Clutter.EventType.BUTTON_PRESS ||
            type === Clutter.EventType.TOUCH_BEGIN) {
            this._onActivate();
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }

    setLocked(locked) {
        this._icon.icon_name = locked ? ICON_LOCKED : ICON_UNLOCKED;
        if (locked)
            this.add_style_class_name('hid-locked');
        else
            this.remove_style_class_name('hid-locked');

        this.accessible_name = locked
            ? 'Keyboard and touchpad disabled'
            : 'Keyboard and touchpad enabled';
    }
});

export default class MinibookXInputToggleExtension extends Extension {
    enable() {
        this._locked = this._readState();
        this._pending = false;
        this._pendingId = 0;
        this._cancellable = new Gio.Cancellable();

        this._button = new HidToggleButton(() => this._toggle());
        this._button.setLocked(this._locked);
        Main.panel.addToStatusArea(this.uuid, this._button, 0, 'right');

        this._settings = this.getSettings();
        Main.wm.addKeybinding(
            KEYBINDING,
            this._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
            () => this._toggle());

        this._monitor = Gio.File.new_for_path(STATE_PATH)
            .monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
        this._monitorId = this._monitor.connect('changed',
            () => this._refresh());

        this._pollId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT_IDLE, POLL_INTERVAL_SECONDS, () => {
                this._refresh();
                return GLib.SOURCE_CONTINUE;
            });
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

        Main.wm.removeKeybinding(KEYBINDING);
        this._settings = null;

        this._button?.destroy();
        this._button = null;
    }

    _readState() {
        return Gio.File.new_for_path(STATE_PATH).query_exists(null);
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
        Main.notify(locked ? 'HID Disabled' : 'HID Enabled');
    }

    _toggle() {
        if (this._pending)
            return;
        this._pending = true;

        const wantLocked = !this._locked;
        const method = wantLocked ? 'StartUnit' : 'StopUnit';

        Gio.DBus.system.call(
            'org.freedesktop.systemd1',
            '/org/freedesktop/systemd1',
            'org.freedesktop.systemd1.Manager',
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
                    console.error(`[minibookx-input-toggle] ${method} failed: ${e.message}`);
                    // Surface it: a silent no-op here looks identical to a
                    // broken polkit rule or a missing unit.
                    Main.notify('HID toggle failed', e.message);
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
                    console.error(`[minibookx-input-toggle] ${UNIT} did not ${verb}`);
                    Main.notify('HID toggle failed',
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
