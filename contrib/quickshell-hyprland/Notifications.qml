import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications

// Notification daemon + toast popups (top right). Replaces mako/dunst: do not run them too.
Scope {
    NotificationServer {
        id: server
        keepOnReload: true
        actionsSupported: true
        bodyMarkupSupported: false
        imageSupported: true
        onNotification: n => { n.tracked = true; }
    }

    PanelWindow {
        id: win
        visible: server.trackedNotifications.values.length > 0

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-notifications"
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; right: true }
        margins { top: 52; right: 12 }
        implicitWidth: 360
        implicitHeight: Math.max(1, stack.implicitHeight)
        color: "transparent"
        mask: Region { item: stack }

        Column {
            id: stack
            width: parent.width
            spacing: 8

            Repeater {
                model: server.trackedNotifications

                Rectangle {
                    id: toast
                    required property var modelData
                    readonly property bool critical: modelData.urgency === NotificationUrgency.Critical

                    width: stack.width
                    height: body.implicitHeight + 24
                    radius: 14
                    color: Theme.glassBg
                    border.width: 1
                    border.color: critical ? Theme.urgent : Theme.edge

                    Timer {
                        running: !toast.critical
                        interval: toast.modelData.expireTimeout > 0 ? toast.modelData.expireTimeout * 1000 : 6000
                        onTriggered: toast.modelData.dismiss()
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: toast.modelData.dismiss()
                    }

                    ColumnLayout {
                        id: body
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 12
                        spacing: 3

                        Text {
                            Layout.fillWidth: true
                            text: toast.modelData.appName
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: toast.modelData.summary
                            color: toast.critical ? Theme.urgent : Theme.accent
                            font.family: Theme.font
                            font.pixelSize: 14
                            font.bold: true
                            wrapMode: Text.Wrap
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: toast.modelData.body
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                        }

                        Row {
                            spacing: 8
                            visible: toast.modelData.actions.length > 0
                            Repeater {
                                model: toast.modelData.actions
                                Rectangle {
                                    required property var modelData
                                    width: label.implicitWidth + 16
                                    height: 24
                                    radius: 8
                                    color: Theme.glassSurface
                                    Text {
                                        id: label
                                        anchors.centerIn: parent
                                        text: parent.modelData.text
                                        color: Theme.accent
                                        font.family: Theme.font
                                        font.pixelSize: 11
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: parent.modelData.invoke()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
