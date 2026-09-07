import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// WireGuard bar widget: an ouroboros in the bar, and a popup with live tunnel
// stats and a connect/disconnect switch. Modelled on omarchy.network.
//
// All privileged work goes through /usr/local/bin/wg-toggle under a scoped
// NOPASSWD rule; the shell itself runs unprivileged and never calls wg-quick.
Panel {
  id: root
  moduleName: "jon.wireguard"
  ipcTarget: "jon.wireguard"

  implicitWidth: button.implicitWidth
  implicitHeight: bar ? bar.barSize : 26

  property var stats: ({})
  property bool busy: false

  readonly property bool tunnelUp: stats.up === true
  // The VPN endpoint is the home network's own public IP, so raising the tunnel
  // from a trusted SSID asks the router to hairpin its own WAN address. It
  // cannot, the handshake never lands, and the full-tunnel routes blackhole
  // everything. Blocked at the UI rather than left to the handshake watchdog,
  // which only rescues you ~10s after the connection has already dropped.
  readonly property bool onTrusted: stats.trusted === true
  // Only the connect direction is barred; disconnecting is always allowed.
  readonly property bool canConnect: !onTrusted
  readonly property bool connected: stats.connected === true
  readonly property string mode: stats.mode || "auto"
  // Asked for but not running, or running with a peer that never answers.
  readonly property bool faulted: (mode === "on" && !tunnelUp) || (tunnelUp && !connected)

  readonly property string statusText: {
    if (connected) return "Connected"
    if (tunnelUp) return "No reply from peer"
    if (mode === "on") return "Failed to connect"
    return "Not connected"
  }

  readonly property string modeText: {
    if (mode === "on") return "Forced on"
    if (mode === "off") return "Forced off"
    return "Automatic (by Wi-Fi network)"
  }

  // PanelHero renders `detail` as a bordered pill on the title row, and that
  // pill is the one element the hero does NOT fit inside trailingInset -- a
  // long string overflows straight under the trailing ToggleSwitch. Keep it to
  // a badge, and only when the automatic policy has been overridden; the full
  // wording lives in the stats grid below.
  readonly property string modeBadge: {
    if (mode === "on") return "FORCED ON"
    if (mode === "off") return "FORCED OFF"
    return ""
  }

  function humanBytes(n) {
    var b = Number(n) || 0
    if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GiB"
    if (b >= 1048576) return (b / 1048576).toFixed(1) + " MiB"
    if (b >= 1024) return Math.round(b / 1024) + " KiB"
    return b + " B"
  }

  function humanAge(sec) {
    var s = Number(sec)
    if (!isFinite(s) || s < 0) return "—"
    if (s < 60) return s + "s ago"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    return Math.floor(s / 3600) + "h ago"
  }

  function refresh() {
    if (statsProc.running) return
    statsProc.running = true
  }

  // Turning "Automatically connect" off must not change the tunnel -- it only
  // stops the Wi-Fi policy from owning it. Pinning the override to whatever is
  // already running does exactly that, and reuses the on/off verbs the sudoers
  // rule already grants rather than needing a new one.
  function pinManual() {
    runToggle(tunnelUp ? "on" : "off")
  }

  function runToggle(action) {
    if (busy) return
    // Keyboard and IPC reach this too, not just the switch.
    if (!root.canConnect && !root.tunnelUp && (action === "toggle" || action === "on")) return
    busy = true
    toggleProc.command = ["sudo", "-n", "/usr/local/bin/wg-toggle", action]
    toggleProc.running = true
  }

  Component.onCompleted: refresh()
  onOpenedChanged: refresh()

  Process {
    id: statsProc
    command: ["bash", "-lc", "~/.config/omarchy/bar/scripts/wireguard-stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.stats = JSON.parse(String(text || "{}").trim() || "{}")
        } catch (e) {
          root.stats = {}
        }
      }
    }
  }

  Process {
    id: toggleProc
    // wg-toggle waits on a handshake before returning, so give the tunnel a
    // moment to settle before believing the next sample.
    onExited: {
      root.busy = false
      settleTimer.restart()
    }
  }

  Timer {
    id: settleTimer
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  // The bar icon has to stay honest even while the popup is shut, but polling
  // hard when nobody is looking wakes the machine for nothing.
  Timer {
    interval: root.opened ? 2000 : 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.connected
      ? "WireGuard — connected\n" + root.humanBytes(root.stats.rx) + " in · " + root.humanBytes(root.stats.tx) + " out"
      : "WireGuard — " + root.statusText

    iconComponent: Component {
      Item {
        WireGuardIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.bar ? root.bar.barForeground : Color.foreground
          badgeColor: root.bar ? root.bar.urgent : Color.urgent
          crossed: !root.connected
          warning: root.faulted
        }
      }
    }

    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "a" || t === "A") root.runToggle("auto")
        else if (t === "c" || t === "C") root.runToggle("toggle")
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          title: "WireGuard"
          meta: root.statusText
          detail: root.modeBadge
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            WireGuardIcon {
              iconSize: Style.font.display
              color: root.bar ? root.bar.foreground : Color.foreground
              badgeColor: root.bar ? root.bar.urgent : Color.urgent
              crossed: !root.connected
              warning: root.faulted
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.tunnelUp
              busy: root.busy
              interactive: root.canConnect || root.tunnelUp
              opacity: interactive ? 1.0 : 0.4
              foreground: root.bar ? root.bar.foreground : Color.foreground
              onToggled: root.runToggle("toggle")
            }
          }
        }

        PanelSeparator { width: parent.width }

        GridLayout {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(14)
          rowSpacing: Style.space(6)

          InfoLabel { text: "Endpoint" }
          InfoValue { text: root.stats.peer || "—"; Layout.fillWidth: true }

          InfoLabel { text: "Handshake" }
          InfoValue { text: root.humanAge(root.stats.handshakeAge) }

          InfoLabel { text: "Received" }
          InfoValue { text: root.humanBytes(root.stats.rx) }

          InfoLabel { text: "Sent" }
          InfoValue { text: root.humanBytes(root.stats.tx) }

          InfoLabel { text: "Tunnel IP" }
          InfoValue { text: root.stats.address || "—" }

          InfoLabel { text: "Network" }
          InfoValue { text: root.stats.ssid || "—"; Layout.fillWidth: true }

          InfoLabel { text: "Mode" }
          InfoValue { text: root.modeText; Layout.fillWidth: true }
        }

        PanelSeparator { width: parent.width }

        // Two switches, because the state really is three-valued: automatic,
        // forced on, forced off. One switch plus a "go back to automatic"
        // button made the third state look like a second way to connect.
        // Here the hero switch says whether the tunnel is up, and this one says
        // who decides. Flipping the hero switch while this is on is itself an
        // override, so this drops to off on its own.
        Item {
          width: parent.width
          implicitHeight: Math.max(autoLabels.implicitHeight, autoSwitch.implicitHeight)

          Column {
            id: autoLabels
            anchors.left: parent.left
            anchors.right: autoSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Automatically connect"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              text: "On Wi-Fi away from home"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              opacity: 0.6
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          ToggleSwitch {
            id: autoSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.mode === "auto"
            busy: root.busy
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onToggled: root.mode === "auto" ? root.pinManual() : root.runToggle("auto")
          }
        }

        Text {
          width: parent.width
          visible: root.onTrusted && !root.tunnelUp
          text: "Off on " + (root.stats.ssid || "this network") + " — the VPN server is here, so connecting would cut your connection."
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          opacity: 0.6
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          id: faultText
          width: parent.width
          visible: root.faulted && !!root.stats.last
          text: String(root.stats.last || "")
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Color.foreground
    opacity: 0.6
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.bar ? root.bar.foreground : Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
}
