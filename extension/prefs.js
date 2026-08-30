/* Input Lock X -- preferences
 * Copyright (C) 2026 Isak Lindgren
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Two things a user cannot discover from the panel button: what the shortcut
 * is bound to, and whether the root daemon this extension drives is actually
 * installed. Both live here.
 *
 * libadwaita 1.4 only. metadata.json claims GNOME 45, which ships 1.4, so
 * Adw.Dialog / Adw.AlertDialog / Adw.PreferencesDialog (all 1.5) are off the
 * table -- the capture window below is a plain Adw.Window for that reason.
 */

import Adw from 'gi://Adw';
import Gdk from 'gi://Gdk';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {UNIT, KEYBINDING, REPO_URL, probeUnit} from './common.js';

/* Keysyms that are only ever half of a chord. Pressing Ctrl arrives here as a
 * key press in its own right, and treating it as a candidate binding would
 * scold the user for the first key of every combination they try. */
const BARE_MODIFIERS = [
    Gdk.KEY_Control_L, Gdk.KEY_Control_R,
    Gdk.KEY_Shift_L, Gdk.KEY_Shift_R,
    Gdk.KEY_Alt_L, Gdk.KEY_Alt_R,
    Gdk.KEY_Meta_L, Gdk.KEY_Meta_R,
    Gdk.KEY_Super_L, Gdk.KEY_Super_R,
    Gdk.KEY_Hyper_L, Gdk.KEY_Hyper_R,
    Gdk.KEY_ISO_Level3_Shift, Gdk.KEY_ISO_Level5_Shift,
    Gdk.KEY_Caps_Lock, Gdk.KEY_Num_Lock,
];

/* Is this combination safe to bind globally? A bare letter would be swallowed
 * system-wide, so require a modifier -- except for the function keys, which
 * are what people actually reach for when they want a bare shortcut. */
function isValidBinding(mask, keyval) {
    if (mask === 0)
        return keyval >= Gdk.KEY_F1 && keyval <= Gdk.KEY_F12;

    // Shift alone just types a capital letter; it is not a modifier for this
    // purpose unless it is combined with a real one.
    if (mask === Gdk.ModifierType.SHIFT_MASK) {
        return (keyval >= Gdk.KEY_F1 && keyval <= Gdk.KEY_F12) ||
            keyval === Gdk.KEY_Tab;
    }

    return true;
}

export default class InputLockXPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();

        // The probe outlives nothing else, but the window can be closed while
        // the system bus is still thinking about it.
        const cancellable = new Gio.Cancellable();
        window.connect('close-request', () => {
            cancellable.cancel();
            return false;
        });

        const page = new Adw.PreferencesPage({
            title: 'Input Lock X',
            icon_name: 'input-keyboard-symbolic',
        });
        window.add(page);

        page.add(this._shortcutGroup(window, settings));
        page.add(this._daemonGroup(window, cancellable));
    }

    _shortcutGroup(window, settings) {
        const group = new Adw.PreferencesGroup({
            title: 'Shortcut',
            description: 'Engages the lock. While the lock is on the daemon ' +
                'holds the internal keyboard exclusively, so this shortcut ' +
                'only reaches the shell again from a device it did not grab.',
        });

        const label = new Gtk.ShortcutLabel({
            disabled_text: 'Disabled',
            valign: Gtk.Align.CENTER,
        });

        const sync = () => {
            const [accel] = settings.get_strv(KEYBINDING);
            label.accelerator = accel ?? '';
        };
        sync();
        const changedId = settings.connect(`changed::${KEYBINDING}`, sync);
        // The settings object is owned by this prefs window; disconnect anyway
        // so a reopened window does not stack handlers on a cached instance.
        window.connect('close-request', () => {
            settings.disconnect(changedId);
            return false;
        });

        const row = new Adw.ActionRow({
            title: 'Toggle the input lock',
            activatable: true,
        });
        row.add_suffix(label);

        const reset = new Gtk.Button({
            icon_name: 'edit-clear-symbolic',
            tooltip_text: 'Restore the default (Ctrl+Esc)',
            valign: Gtk.Align.CENTER,
            css_classes: ['flat'],
        });
        reset.connect('clicked', () => settings.reset(KEYBINDING));
        row.add_suffix(reset);

        row.connect('activated', () => this._captureShortcut(window, settings));
        group.add(row);

        // Stated here rather than only in the README, because this screen is
        // where someone rebinds -- and the moment just after is exactly when
        // believing the new keys also release would leave them holding a dead
        // keyboard, looking for a combination nothing has told them about.
        group.add(new Adw.ActionRow({
            title: 'Release is always Ctrl+Esc',
            subtitle: 'Fixed in the daemon and unaffected by the shortcut ' +
                'above. It is watched for inside the grab, so it releases the ' +
                'lock from the locked keyboard itself — and on the lock ' +
                'screen, where extensions are disabled.',
        }));

        return group;
    }

    /* A modal window that exists only to receive one key press. Deliberately
     * not an Adw.AlertDialog -- that is libadwaita 1.5, and this extension
     * claims GNOME 45. */
    _captureShortcut(window, settings) {
        const content = new Adw.StatusPage({
            title: 'Press the new shortcut',
            description: 'Backspace clears it, Esc keeps the current one.',
            icon_name: 'input-keyboard-symbolic',
            vexpand: true,
        });

        // A Cancel button, not just the Esc key. This tool is for a convertible
        // folded into tablet mode, where the touchscreen may be the only input
        // that works -- a modal window whose every exit is a key press would
        // trap exactly the user it was written for.
        const cancel = new Gtk.Button({label: 'Cancel'});
        const header = new Adw.HeaderBar({
            title_widget: new Adw.WindowTitle({title: 'Set shortcut'}),
        });
        header.pack_start(cancel);

        const box = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL});
        box.append(header);
        box.append(content);

        const capture = new Adw.Window({
            transient_for: window,
            modal: true,
            resizable: false,
            default_width: 440,
            default_height: 300,
            content: box,
        });
        cancel.connect('clicked', () => capture.destroy());

        const controller = new Gtk.EventControllerKey();
        // CAPTURE, so the key never reaches a default handler that might treat
        // it as navigation before we see it.
        controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        capture.add_controller(controller);

        controller.connect('key-pressed', (_controller, keyval, keycode, state) => {
            // Already excludes CapsLock and NumLock -- the default mod mask
            // is Shift|Ctrl|Alt|Super|Hyper|Meta and nothing else.
            const mask = state & Gtk.accelerator_get_default_mod_mask();

            // Still assembling the chord -- wait for the key it ends on.
            if (keyval === 0 || BARE_MODIFIERS.includes(keyval))
                return Gdk.EVENT_STOP;

            if (mask === 0 && keyval === Gdk.KEY_Escape) {
                capture.destroy();
                return Gdk.EVENT_STOP;
            }

            if (mask === 0 && keyval === Gdk.KEY_BackSpace) {
                settings.set_strv(KEYBINDING, []);
                capture.destroy();
                return Gdk.EVENT_STOP;
            }

            if (!isValidBinding(mask, keyval) ||
                !Gtk.accelerator_valid(keyval, mask)) {
                content.description = 'That combination cannot be used as a ' +
                    'global shortcut. Try adding Ctrl, Alt or Super.';
                return Gdk.EVENT_STOP;
            }

            // with_keycode, so layouts where the keyval depends on a modifier
            // still round-trip to something the shell can match.
            const accel = Gtk.accelerator_name_with_keycode(
                null, keyval, keycode, mask);
            settings.set_strv(KEYBINDING, [accel]);
            capture.destroy();
            return Gdk.EVENT_STOP;
        });

        capture.present();
    }

    _daemonGroup(window, cancellable) {
        const group = new Adw.PreferencesGroup({
            title: 'Daemon',
            description: 'The lock itself is done by a small root service. A ' +
                'GNOME extension cannot open /dev/input, so it is installed ' +
                'separately; this extension only starts and stops it.',
        });

        const status = new Adw.ActionRow({
            title: UNIT,
            subtitle: 'Checking…',
        });
        const icon = new Gtk.Image({
            icon_name: 'content-loading-symbolic',
            valign: Gtk.Align.CENTER,
        });
        status.add_suffix(icon);
        group.add(status);

        probeUnit(cancellable, (state, error) => {
            if (error) {
                status.subtitle = `Could not check: ${error.message}`;
                icon.icon_name = 'dialog-warning-symbolic';
                return;
            }
            if (state === null) {
                status.subtitle = 'Not installed — the panel button cannot ' +
                    'lock anything until it is.';
                icon.icon_name = 'dialog-warning-symbolic';
                return;
            }
            // Enabled or not does not matter: the extension starts the unit on
            // demand, so "exists" is the whole question.
            status.subtitle = `Installed (${state})`;
            icon.icon_name = 'object-select-symbolic';
        });

        const help = new Adw.ActionRow({
            title: 'Installation instructions',
            subtitle: REPO_URL,
            activatable: true,
        });
        help.add_suffix(new Gtk.Image({
            icon_name: 'go-next-symbolic',
            valign: Gtk.Align.CENTER,
        }));
        help.connect('activated', () => {
            Gtk.show_uri(window, REPO_URL, Gdk.CURRENT_TIME);
        });
        group.add(help);

        return group;
    }
}
