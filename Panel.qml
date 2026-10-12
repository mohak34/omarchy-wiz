import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup for one WiZ bulb. Every bulb call goes through the
// bundled wiz.py, which runs once per action and exits, so the widget keeps
// nothing resident besides this QML. Writes are queued and coalesced:
// dragging a slider sends only the latest value once the previous command
// returns. Timer refreshes only try the bulb's last known address; opening
// the panel or a click may rescan, which wiz.py limits to the home network.
Panel {
  id: root
  moduleName: "mohak34.wiz"
  manageIpc: false

  readonly property var helper: ["python3", "-I", decodeURIComponent(Qt.resolvedUrl("wiz.py").toString().replace(/^file:\/\//, ""))]
  readonly property string mac: String(setting("mac", ""))
  readonly property int refreshMs: Math.max(10, parseInt(setting("refreshIntervalSec", 60), 10) || 60) * 1000

  // Last state from the helper: { ip, mac, on, dimming, temp, color, r, g, b, scene, rssi }.
  property var bulb: null
  // Last state the bulb itself reported, restored when a command fails.
  property var confirmed: null
  property string error: ""
  property var queued: null
  property real wheelAccumulator: 0

  readonly property bool isOn: !!bulb && bulb.on
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color lightColor: !bulb ? dim
    : bulb.color ? Qt.rgba(bulb.r / 255, bulb.g / 255, bulb.b / 255, 1)
    : Model.tempColor(bulb.temp || 2700)

  // scan lets the helper search the home network when the bulb moved.
  function refresh(scan) {
    if (getProc.running || setProc.running || queued) return
    getProc.command = helper.concat(scan ? ["get", mac] : ["get", mac, "--cached"])
    getProc.running = true
  }

  // Any change other than power implies the light should be on.
  function send(params) {
    if (!bulb) return
    if (params.state === undefined) params.state = true
    bulb = Model.apply(bulb, params)
    queued = Model.merge(queued, params)
    flush()
  }

  function flush() {
    if (setProc.running || !queued) return
    setProc.command = helper.concat(["set", mac, JSON.stringify(queued)])
    queued = null
    setProc.running = true
  }

  function togglePower() { if (bulb) send({ state: !bulb.on }) }

  function setBrightness(v) { send({ dimming: Math.max(10, Math.min(100, Math.round(v))) }) }

  function setHue(h) {
    var c = Qt.hsva(Math.max(0, Math.min(1, h)), 1, 1, 1)
    send({ r: Math.round(c.r * 255), g: Math.round(c.g * 255), b: Math.round(c.b * 255) })
  }

  function handle(text) {
    var out = null
    try { out = JSON.parse(text) } catch (e) {}
    if (!out) return
    if (out.error) { error = out.error; bulb = confirmed; return }
    error = ""
    bulb = out
    confirmed = out
  }

  onOpenedChanged: if (opened) refresh(true)

  Process {
    id: getProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!setProc.running && !root.queued) root.handle(text)
    }
  }

  // A reply that lands while newer values are queued is already stale, so
  // only the last command in a burst updates the panel.
  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.queued) root.handle(text)
    }
    onExited: Qt.callLater(root.flush)
  }

  Timer {
    interval: root.opened ? 5000 : root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.glyph(root.isOn)
    dimmed: !root.isOn
    tooltipText: "Light: " + Model.status(root.bulb, root.error)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePower()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.bulb) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps !== 0) root.setBrightness(root.bulb.dimming + wheel.steps * 10)
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
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dx !== 0 && root.bulb) root.setBrightness(root.bulb.dimming + dx * 10) }
      onActivateRequested: root.togglePower()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          width: parent.width
          title: "Light"
          meta: Model.status(root.bulb, root.error)
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.isOn ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: Model.glyph(root.isOn)
              color: root.isOn ? root.lightColor : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.isOn
              visible: !!root.bulb
              foreground: root.foreground
              onToggled: root.togglePower()
            }
          }
        }

        Text {
          visible: root.error !== "" && !!root.bulb
          width: parent.width
          textFormat: Text.PlainText
          text: root.error
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Column {
          visible: !!root.bulb
          width: parent.width
          spacing: Style.space(14)

          PanelSeparator { foreground: root.foreground }

          SliderSection {
            label: "BRIGHTNESS"
            unit: "%"
            minimum: 10
            maximum: 100
            step: 10
            value: root.bulb ? root.bulb.dimming : 100
            onMoved: function(v) { root.setBrightness(v) }
          }

          SliderSection {
            readonly property bool white: !!root.bulb && !root.bulb.color && root.bulb.scene === 0
            label: "WHITE"
            unit: "K"
            showValue: white
            minimum: Model.minTemp
            maximum: Model.maxTemp
            step: 100
            value: root.bulb && root.bulb.temp ? root.bulb.temp : 2700
            sliderOpacity: white ? 1.0 : 0.5
            onMoved: function(v) { root.send({ temp: Math.round(v / 100) * 100 }) }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "COLOR"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              id: hueStrip
              width: parent.width
              implicitHeight: Style.space(22)
              readonly property bool showKnob: !!root.bulb && root.bulb.color
              readonly property real hue: showKnob ? Math.max(0, root.lightColor.hsvHue) : 0

              Rectangle {
                id: hueTrack
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                height: Style.space(10)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                gradient: Gradient {
                  orientation: Gradient.Horizontal
                  GradientStop { position: 0.0; color: "#ff0000" }
                  GradientStop { position: 1 / 6; color: "#ffff00" }
                  GradientStop { position: 2 / 6; color: "#00ff00" }
                  GradientStop { position: 3 / 6; color: "#00ffff" }
                  GradientStop { position: 4 / 6; color: "#0000ff" }
                  GradientStop { position: 5 / 6; color: "#ff00ff" }
                  GradientStop { position: 1.0; color: "#ff0000" }
                }
              }

              BorderSurface {
                visible: hueStrip.showKnob
                width: Style.space(16)
                height: width
                radius: width / 2
                color: root.lightColor
                borderSpec: Border.flat(root.bar ? root.bar.background : Color.background, Math.max(1, Style.space(2)))
                anchors.verticalCenter: hueTrack.verticalCenter
                x: hueTrack.x + hueTrack.width * hueStrip.hue - width / 2
              }

              MouseArea {
                anchors.fill: hueTrack
                anchors.topMargin: -Style.space(6)
                anchors.bottomMargin: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onPressed: function(mouse) { root.setHue(mouse.x / width) }
                onPositionChanged: function(mouse) { if (pressed) root.setHue(mouse.x / width) }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "SCENES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Grid {
              id: sceneGrid
              width: parent.width
              columns: 4
              spacing: Style.spacing.xs
              readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: Model.scenes

                Button {
                  required property var modelData
                  width: sceneGrid.cellWidth
                  text: modelData.label
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.sm
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  active: root.isOn && root.bulb.scene === modelData.id
                  onClicked: root.send({ sceneId: modelData.id })
                }
              }
            }
          }
        }
      }
    }
  }

  // Section header with the current value on the right, over a slider.
  component SliderSection: Column {
    id: section
    property string label: ""
    property string unit: ""
    property bool showValue: true
    property real minimum: 0
    property real maximum: 1
    property real step: 1
    property real value: 0
    property real sliderOpacity: 1.0
    signal moved(real value)

    width: parent.width
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(header.implicitHeight, valueLabel.implicitHeight)

      PanelSectionHeader {
        id: header
        text: section.label
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: valueLabel
        textFormat: Text.PlainText
        visible: section.showValue
        text: Math.round(slider.dragging ? slider.liveValue : section.value) + section.unit
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    PanelSlider {
      id: slider
      bar: root.bar
      width: parent.width - Style.space(12)
      x: Style.space(6)
      minimum: section.minimum
      maximum: section.maximum
      step: section.step
      integer: true
      value: section.value
      opacity: section.sliderOpacity
      onMoved: function(v) { section.moved(v) }
    }
  }
}
