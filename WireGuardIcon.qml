import QtQuick
import qs.Commons
import qs.Ui

// The WireGuard mark: an ouroboros -- a serpent curled into a ring, biting its
// own tail. Drawn rather than taken from a font because no Nerd Font glyph
// carries the shape, and Qt SVG rendering is unreliable at bar-icon sizes.
//
// The body is stroked as a run of short arc segments whose width tapers from
// head to tail; a single arc with a uniform stroke reads as a plain circle at
// 11px and loses the serpent entirely.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool crossed: false
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  onColorChanged: canvas.requestPaint()
  onIconSizeChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()

      var s = Math.min(width, height)
      var cx = width / 2
      var cy = height / 2
      var r = s * 0.33

      // Leave a wedge open where the head meets the tail, so the ring reads as
      // a creature rather than a closed circle.
      var start = -Math.PI * 0.30   // head
      var sweep = Math.PI * 1.72    // body, clockwise to the tail
      var segments = 18

      var headW = Math.max(1.6, s * 0.20)
      var tailW = Math.max(0.7, s * 0.055)

      ctx.strokeStyle = root.color
      ctx.lineCap = "round"

      for (var i = 0; i < segments; i++) {
        var t0 = i / segments
        var t1 = (i + 1) / segments
        // Overlap each segment slightly; butted arc ends leave hairline gaps
        // once the stroke width changes between them.
        var a0 = start + sweep * t0
        var a1 = start + sweep * t1 + 0.012

        ctx.beginPath()
        ctx.lineWidth = headW + (tailW - headW) * t0
        ctx.arc(cx, cy, r, a0, a1, false)
        ctx.stroke()
      }

      // Head: a blunt knob at the start of the sweep, slightly proud of the
      // body so the bite reads at small sizes.
      var hx = cx + r * Math.cos(start)
      var hy = cy + r * Math.sin(start)
      ctx.beginPath()
      ctx.fillStyle = root.color
      ctx.arc(hx, hy, headW * 0.62, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  // Same struck-through convention as the Wi-Fi and Tailscale marks.
  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
