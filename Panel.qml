// Plugin panel: full device list with per-row actions.
//
// One row per device known to the daemon. Each row shows:
//   - colored dot (current target)
//   - name (or "Unknown") + VID:PID + serial in a smaller line
//   - port + rule id on the right
//   - Allow / Block / Reject buttons
//
// Header has a refresh button and an "Allow Permanently" toggle that controls
// whether each action passes `-p` to usbguard.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Widgets

Rectangle {
    id: root

    property var pluginApi: null
    readonly property var main: pluginApi ? pluginApi.mainInstance : null
    readonly property var devices: main ? main.devices : null

    // Local UI state. Seeded from settings on first open, then user-controlled
    // for this session.
    property bool permanent: pluginApi && pluginApi.pluginSettings
                             ? !!pluginApi.pluginSettings.defaultAllowPermanent
                             : false

    implicitWidth: 460
    implicitHeight: Math.min(560, header.implicitHeight + listContainer.implicitHeight + Style.marginL * 3)

    color: Color.mSurface
    radius: Style.radiusL

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.marginL
        spacing: Style.marginM

        // ---- Header --------------------------------------------------------
        RowLayout {
            id: header
            Layout.fillWidth: true
            spacing: Style.marginS

            NIcon { icon: "usb"; color: Color.mPrimary }

            NText {
                text: "USBGuard"
                pointSize: Style.fontSizeL
                Layout.fillWidth: true
            }

            NText {
                visible: main && !main.watchRunning
                text: "watch offline"
                color: Color.mError
                pointSize: Style.fontSizeS
            }

            NIconButton {
                icon: "refresh"
                tooltipText: "Re-sync from daemon"
                onClicked: if (main) main.refresh()
            }

            NIconButton {
                icon: "close"
                tooltipText: "Close"
                onClicked: if (pluginApi) pluginApi.closePanel(pluginApi.panelOpenScreen)
            }
        }

        // ---- Permanent toggle ---------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS

            CheckBox {
                id: permBox
                checked: root.permanent
                onToggled: root.permanent = checked
            }
            NText {
                text: "Make decisions permanent (write to rules.conf)"
                Layout.fillWidth: true
                pointSize: Style.fontSizeS
                color: Color.mOnSurfaceVariant
            }
        }

        // ---- Empty state ---------------------------------------------------
        NText {
            visible: !devices || devices.count === 0
            text: "No USB devices known to usbguard."
            color: Color.mOnSurfaceVariant
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.marginL
        }

        // ---- Device list ---------------------------------------------------
        ScrollView {
            id: listContainer
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: devices && devices.count > 0
            clip: true

            ListView {
                model: root.devices
                spacing: Style.marginS

                delegate: Rectangle {
                    id: row
                    width: ListView.view ? ListView.view.width : 0
                    radius: Style.radiusM
                    color: Color.mSurfaceVariant
                    implicitHeight: rowCol.implicitHeight + Style.marginM * 2

                    // Per-device color cue.
                    readonly property color targetColor:
                        model.target === "allow"  ? Color.mPrimary :
                        model.target === "block"  ? Color.mError   :
                                                    Color.mTertiary  // reject

                    ColumnLayout {
                        id: rowCol
                        anchors.fill: parent
                        anchors.margins: Style.marginM
                        spacing: Style.marginXS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.marginS

                            // State dot
                            Rectangle {
                                width: 10; height: 10; radius: 5
                                color: row.targetColor
                                Layout.alignment: Qt.AlignVCenter
                            }

                            NText {
                                text: model.name && model.name.length
                                      ? model.name : "Unknown device"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            NText {
                                text: "#" + model.ruleId
                                color: Color.mOnSurfaceVariant
                                pointSize: Style.fontSizeS
                            }
                        }

                        // Secondary line: VID:PID, serial, port
                        NText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            pointSize: Style.fontSizeS
                            color: Color.mOnSurfaceVariant
                            text: {
                                const bits = [];
                                if (model.vendorId && model.productId)
                                    bits.push(model.vendorId + ":" + model.productId);
                                if (model.serial) bits.push("sn " + model.serial);
                                if (model.port)   bits.push("port " + model.port);
                                bits.push("target " + model.target);
                                return bits.join("  •  ");
                            }
                        }

                        // Action buttons
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.marginXS

                            Item { Layout.fillWidth: true }

                            NButton {
                                text: "Allow"
                                enabled: model.target !== "allow"
                                onClicked: if (main) main.allowDevice(model.ruleId, root.permanent)
                            }
                            NButton {
                                text: "Block"
                                enabled: model.target !== "block"
                                onClicked: if (main) main.blockDevice(model.ruleId, root.permanent)
                            }
                            NButton {
                                text: "Reject"
                                enabled: model.target !== "reject"
                                onClicked: if (main) main.rejectDevice(model.ruleId, root.permanent)
                            }
                        }
                    }
                }
            }
        }
    }
}
