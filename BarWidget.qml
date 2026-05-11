// Compact bar widget: USB icon + optional count badge.
//
// Color states:
//   - blocked devices present -> mError (red-ish accent)
//   - any devices present     -> mPrimary
//   - nothing                 -> mOnSurfaceVariant (muted)
//
// Click: toggles the plugin panel.
// Right-click: forces a refresh from `usbguard list-devices`.

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

Rectangle {
    id: root

    // Standard noctalia plugin contract.
    property var pluginApi: null
    property ShellScreen screen
    property string widgetId: ""
    property string section: ""
    property int sectionWidgetIndex: -1
    property int sectionWidgetsCount: 0

    // Convenience: pull the singleton Main.qml instance.
    readonly property var main: pluginApi ? pluginApi.mainInstance : null
    readonly property int deviceCount:  main ? main.devices.count : 0
    readonly property int blockedCount: main ? main.blockedCount  : 0

    readonly property bool hideMe:
        pluginApi && pluginApi.pluginSettings
            && pluginApi.pluginSettings.hideWhenEmpty
            && deviceCount === 0

    visible: !hideMe

    implicitWidth: row.implicitWidth + Style.marginM * 2
    implicitHeight: Style.barHeight

    color: Style.capsuleColor
    radius: Style.radiusM

    readonly property color accent:
        blockedCount > 0 ? Color.mError
                         : (deviceCount > 0 ? Color.mPrimary
                                            : Color.mOnSurfaceVariant)

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Style.marginXS

        NIcon {
            icon: "usb"
            color: root.accent
        }

        NText {
            visible: pluginApi && pluginApi.pluginSettings
                     && pluginApi.pluginSettings.showCountBadge
                     && root.deviceCount > 0
            text: root.blockedCount > 0
                  ? (root.blockedCount + "/" + root.deviceCount)
                  : String(root.deviceCount)
            color: root.accent
            pointSize: Style.fontSizeS
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (!pluginApi) return;
            if (mouse.button === Qt.RightButton) {
                if (main) main.refresh();
                return;
            }
            pluginApi.togglePanel(root.screen, root);
        }
    }
}
