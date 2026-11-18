import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Mpris

// Now-playing panel (click the track in the bar, or `qs ipc call media toggle`).
PanelWindow {
    id: win

    readonly property var player: {
        const list = Mpris.players.values;
        for (const p of list) if (p.isPlaying) return p;
        return list.length > 0 ? list[0] : null;
    }

    visible: UiState.mediaOpen && player !== null

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-media"
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true }
    margins { top: 52 }
    implicitWidth: 380
    implicitHeight: 128
    color: "transparent"

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: Theme.glassBg
        border.width: 1
        border.color: Theme.edge

        RowLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 14

            Rectangle {
                Layout.preferredWidth: 100
                Layout.preferredHeight: 100
                radius: 12
                color: Theme.glassSurface
                clip: true

                Image {
                    anchors.fill: parent
                    source: win.player ? win.player.trackArtUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4

                Text {
                    Layout.fillWidth: true
                    text: win.player ? win.player.trackTitle : ""
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 15
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    text: win.player ? win.player.trackArtist : ""
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                Item { Layout.fillHeight: true }

                Row {
                    spacing: 22
                    Repeater {
                        model: [
                            { glyph: "⏮", act: "prev" },
                            { glyph: "toggle", act: "toggle" },
                            { glyph: "⏭", act: "next" }
                        ]

                        Text {
                            required property var modelData
                            text: modelData.act === "toggle" ? (win.player && win.player.isPlaying ? "⏸" : "▶") : modelData.glyph
                            color: modelData.act === "toggle" ? Theme.accent : Theme.fg
                            font.pixelSize: 22
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                onClicked: {
                                    if (!win.player) return;
                                    if (modelData.act === "prev" && win.player.canGoPrevious) win.player.previous();
                                    else if (modelData.act === "next" && win.player.canGoNext) win.player.next();
                                    else if (modelData.act === "toggle" && win.player.canTogglePlaying) win.player.togglePlaying();
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
