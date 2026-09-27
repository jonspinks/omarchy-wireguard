import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// WireGuard bar widget: an ouroboros in the bar, and a popup with live tunnel
// stats and a connect/disconnect switch. Modelled on omarchy.network.
//
// All privileged work goes through /usr/local/libexec/blacksheep.wireguard/wg-toggle under a scoped
// NOPASSWD rule; the shell itself runs unprivileged and never calls wg-quick.
Panel {
  id: root
  moduleName: "blacksheep.wireguard"
  ipcTarget: "blacksheep.wireguard"

  implicitWidth: button.implicitWidth
  implicitHeight: bar ? bar.barSize : 26

  property var stats: ({})
  // False until the first stats sample lands, so an empty list is never shown
  // as "None" just because nothing has been read yet.
  property bool loaded: false
  property bool busy: false
  // Why the last privileged action failed, shown under the trusted list. The
  // usual cause is sudo refusing a verb the installed sudoers rule predates.
  property string actionError: ""

  readonly property bool tunnelUp: stats.up === true
  // Trusted networks are where the tunnel stays down -- typically the network
  // the VPN server itself is on, where raising it asks the router to hairpin
  // its own public address; most cannot, the handshake never lands, and the
  // full-tunnel routes blackhole everything. Connecting there is blocked at the
  // UI rather than left to the handshake watchdog, which only rescues you ~10s
  // after the connection has already dropped. To connect anyway, remove the
  // network from the list.
  readonly property bool onTrusted: stats.trusted === true
  readonly property var trustedList: Array.isArray(stats.trustedList) ? stats.trustedList : []
  readonly property string ssid: stats.ssid || ""
  readonly property bool canTrustHere: ssid !== "" && !onTrusted
  // Only the connect direction is barred; disconnecting is always allowed.
  readonly property bool canConnect: !onTrusted
  readonly property bool connected: stats.connected === true
  readonly property string mode: stats.mode || "auto"
  // Wanted up but not connected. "Wanted" is forced on, or automatic on a
  // Wi-Fi network that isn't trusted (the policy raises the tunnel there; with
  // no Wi-Fi at all, ethernet or no link, it stays down on purpose), or up
  // already with a peer that never answers. Shown the way the stock widgets
  // show trouble: the whole icon in the bar's active colour, not a badge.
  readonly property bool wanted: mode === "on" || tunnelUp
    || (mode === "auto" && ssid !== "" && !onTrusted)
  readonly property bool alarming: wanted && !connected

  readonly property string statusText: {
    if (connected) return "Connected"
    if (tunnelUp) return "No reply from peer"
    if (wanted) return "Failed to connect"
    return "Not connected"
  }

  readonly property string modeText: {
    if (mode === "on") return "On"
    if (mode === "off") return "Forced off"
    return "Automatic (by Wi-Fi network)"
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

  // `extra` is only ever the one name `untrust` takes. It goes to wg-toggle on
  // stdin, not argv, so the sudoers rule can list every verb exactly.
  function runToggle(action, extra) {
    if (busy) return
    // Keyboard and IPC reach this too, not just the switch.
    if (!root.canConnect && !root.tunnelUp && (action === "toggle" || action === "on")) return
    if (action === "trust" && !root.canTrustHere) return
    busy = true
    actionError = ""
    toggleProc.input = extra !== undefined ? String(extra) : ""
    toggleProc.command = ["sudo", "-n", "/usr/local/libexec/blacksheep.wireguard/wg-toggle", action]
    toggleProc.running = true
  }

  Component.onCompleted: refresh()
  onOpenedChanged: refresh()

  Process {
    id: statsProc
    // Run from the plugin itself, as a fixed argv: `omarchy plugin update` then
    // updates the helper along with the panel, and no shell parses the path.
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/blacksheep.wireguard/scripts/wireguard-stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.stats = JSON.parse(String(text || "{}").trim() || "{}")
          root.loaded = true
        } catch (e) {
          root.stats = {}
        }
      }
    }
  }

  Process {
    id: toggleProc
    // The one line `untrust` reads on stdin; empty for every other verb.
    property string input: ""
    stdinEnabled: true
    onStarted: {
      write(input + "\n")
      input = ""
    }
    // wg-toggle waits on a handshake before returning, so give the tunnel a
    // moment to settle before believing the next sample.
    stderr: StdioCollector { id: toggleErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) {
        var msg = String(toggleErr.text || "").trim().split("\n").pop()
        // sudo -n says this when no NOPASSWD rule covers the verb.
        if (msg.indexOf("password is required") !== -1)
          msg = "Not permitted. Re-run install.sh in the plugin folder to update the sudoers rule."
        root.actionError = msg || ("wg-toggle failed (exit " + exitCode + ")")
      }
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
          color: root.alarming
            ? (root.bar ? root.bar.urgent : Color.urgent)
            : (root.bar ? root.bar.barForeground : Color.foreground)
          crossed: !root.connected
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
        else if (t === "t" || t === "T") root.runToggle("trust")
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
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            WireGuardIcon {
              iconSize: Style.font.display
              color: root.alarming
                ? (root.bar ? root.bar.urgent : Color.urgent)
                : (root.bar ? root.bar.foreground : Color.foreground)
              crossed: !root.connected
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

          // Mode first: who decides is the one thing here you might change.
          InfoLabel { text: "Mode" }
          InfoValue { text: root.modeText; Layout.fillWidth: true }

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
              text: "On Wi-Fi networks you haven't trusted"
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
          text: "Off on " + (root.ssid || "this network") + " because it's trusted. Remove it below to connect here."
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
          visible: root.alarming && !!root.stats.last
          text: String(root.stats.last || "")
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width }

        PanelSectionHeader {
          width: parent.width
          text: "Trusted networks"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Text {
          width: parent.width
          visible: root.loaded && root.trustedList.length === 0
          text: "None. The tunnel comes up on every Wi-Fi network."
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          opacity: 0.6
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.trustedList

          Item {
            required property string modelData
            width: column.width
            implicitHeight: Math.max(nameText.implicitHeight, removeButton.implicitHeight)

            Text {
              id: nameText
              anchors.left: parent.left
              anchors.right: removeButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData + (modelData === root.ssid ? "  · connected" : "")
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            PanelActionButton {
              id: removeButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅙"
              tooltipText: modelData === root.ssid
                ? "Stop trusting " + modelData + " (the tunnel will try to connect here)"
                : "Stop trusting " + modelData
              enabled: !root.busy
              foreground: root.bar ? root.bar.foreground : Color.foreground
              hoverColor: root.bar ? root.bar.urgent : Color.urgent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.runToggle("untrust", modelData)
            }
          }
        }

        // Only the network you are on can be added: the privileged helper takes
        // no name for `trust`, so the panel cannot trust a network you are not on.
        Button {
          visible: root.canTrustHere
          text: "Trust " + root.ssid
          iconText: "󰒘"
          bordered: true
          enabled: !root.busy
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          fontSize: Style.font.bodySmall
          iconSize: Style.font.bodySmall
          horizontalPadding: 8
          verticalPadding: 3
          onClicked: root.runToggle("trust")
        }

        Text {
          width: parent.width
          visible: root.actionError !== ""
          text: root.actionError
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
