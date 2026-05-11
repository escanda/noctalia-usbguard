// Settings page rendered inside noctalia's settings UI.
//
// Anything written via pluginApi.pluginSettings is persisted to
// ~/.config/noctalia/plugins/usbguard/settings.json after saveSettings().

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Widgets

ColumnLayout {
    id: root
    spacing: Style.marginM

    property var pluginApi: null

    function save() { if (pluginApi) pluginApi.saveSettings(); }

    // --- Notifications ------------------------------------------------------
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        CheckBox {
            checked: pluginApi && pluginApi.pluginSettings
                     ? !!pluginApi.pluginSettings.notifyOnInsert : true
            onToggled: {
                if (!pluginApi) return;
                pluginApi.pluginSettings.notifyOnInsert = checked;
                root.save();
            }
        }
        NText {
            text: "Notify when a USB device is blocked on insert"
            Layout.fillWidth: true
        }
    }

    // --- Default permanence -------------------------------------------------
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        CheckBox {
            checked: pluginApi && pluginApi.pluginSettings
                     ? !!pluginApi.pluginSettings.defaultAllowPermanent : false
            onToggled: {
                if (!pluginApi) return;
                pluginApi.pluginSettings.defaultAllowPermanent = checked;
                root.save();
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            NText { text: "Default to permanent decisions" }
            NText {
                text: "When on, the panel's 'permanent' toggle starts checked."
                pointSize: Style.fontSizeS
                color: Color.mOnSurfaceVariant
            }
        }
    }

    // --- Badge --------------------------------------------------------------
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        CheckBox {
            checked: pluginApi && pluginApi.pluginSettings
                     ? !!pluginApi.pluginSettings.showCountBadge : true
            onToggled: {
                if (!pluginApi) return;
                pluginApi.pluginSettings.showCountBadge = checked;
                root.save();
            }
        }
        NText { text: "Show device count badge in the bar"; Layout.fillWidth: true }
    }

    // --- Hide when empty ----------------------------------------------------
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        CheckBox {
            checked: pluginApi && pluginApi.pluginSettings
                     ? !!pluginApi.pluginSettings.hideWhenEmpty : false
            onToggled: {
                if (!pluginApi) return;
                pluginApi.pluginSettings.hideWhenEmpty = checked;
                root.save();
            }
        }
        NText {
            text: "Hide the bar widget when no devices are tracked"
            Layout.fillWidth: true
        }
    }

    // --- Command override ---------------------------------------------------
    ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.marginM
        spacing: Style.marginXS

        NText { text: "usbguard command" }
        NText {
            text: "Override if you need a wrapper (e.g. 'pkexec usbguard'). Default: 'usbguard'."
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeS
        }

        TextField {
            Layout.fillWidth: true
            text: pluginApi && pluginApi.pluginSettings
                  ? (pluginApi.pluginSettings.usbguardCommand || "usbguard")
                  : "usbguard"
            onEditingFinished: {
                if (!pluginApi) return;
                pluginApi.pluginSettings.usbguardCommand = text.trim() || "usbguard";
                root.save();
            }
        }
    }
}
