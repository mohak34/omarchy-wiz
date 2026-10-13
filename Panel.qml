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
  // Saved looks from presets.json, outside the plugin folder so updates and
  // reinstalls keep them.
  property var presets: []
  readonly property string presetsPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy-wiz/presets.json"
  // True while a slider value is being typed, so panel keys go to the field.
  property bool editingValue: false

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

  // h and s run 0..1; full value, since brightness is its own control.
  function setColor(h, s) {
    var c = Qt.hsva(Math.max(0, Math.min(1, h)), Math.max(0, Math.min(1, s)), 1, 1)
    send({ r: Math.round(c.r * 255), g: Math.round(c.g * 255), b: Math.round(c.b * 255) })
  }

  function savePreset() {
    if (!bulb) return
    var p = Model.presetOf(bulb)
    for (var i = 0; i < presets.length; i++) if (Model.samePreset(presets[i], p)) return
    writePresets(presets.concat([p]))
  }

  function removePreset(index) {
    var list = presets.slice()
    list.splice(index, 1)
    writePresets(list)
  }

  function writePresets(list) {
    presets = list
    presetsFile.setText(JSON.stringify(list, null, 2) + "\n")
  }

  function restoreFocus() {
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
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

  FileView {
    id: presetsFile
    path: root.presetsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.presets = Model.parsePresets(text())
    onLoadFailed: root.presets = []
    onFileChanged: reload()
  }

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
      blocked: root.editingValue
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

          Column {
            width: parent.width
            spacing: Style.space(4)

            Item {
              width: parent.width
              implicitHeight: Math.max(savedHeader.implicitHeight, addButton.implicitHeight)

              PanelSectionHeader {
                id: savedHeader
                text: "SAVED"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelActionButton {
                id: addButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.isOn
                iconText: Model.addGlyph
                tooltipText: "Save current light"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.savePreset()
              }
            }

            Repeater {
              model: root.presets
              PresetRow {}
            }
          }

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
            snap: 100
            value: root.bulb && root.bulb.temp ? root.bulb.temp : 2700
            sliderOpacity: white ? 1.0 : 0.5
            onMoved: function(v) { root.send({ temp: Math.round(v) }) }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(colorHeader.implicitHeight, hexValue.implicitHeight)

              PanelSectionHeader {
                id: colorHeader
                text: "COLOR"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              EditableValue {
                id: hexValue
                readonly property string hex: root.bulb && root.bulb.color ? Model.hex(root.bulb.r, root.bulb.g, root.bulb.b).toUpperCase() : ""
                text: hex || "--"
                editText: hex
                maximumLength: 7
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                onCommitted: function(text) {
                  var c = Model.parseHex(text)
                  if (c) root.send(c)
                }
              }
            }

            // Hue left to right, saturation top (full) to bottom (pale). The
            // knob marks the light's colour while it is in colour mode.
            Item {
              id: colorPad
              width: parent.width - Style.space(12)
              x: Style.space(6)
              implicitHeight: Style.space(110)
              readonly property bool showKnob: !!root.bulb && root.bulb.color && root.bulb.scene === 0
              readonly property real hue: Math.max(0, root.lightColor.hsvHue)
              readonly property real saturation: root.lightColor.hsvSaturation

              function pick(mouse) {
                root.setColor(mouse.x / width, 1 - mouse.y / height)
              }

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
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

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                gradient: Gradient {
                  GradientStop { position: 0.0; color: "#00ffffff" }
                  GradientStop { position: 1.0; color: "#ffffff" }
                }
              }

              BorderSurface {
                visible: colorPad.showKnob
                width: Style.space(16)
                height: width
                radius: width / 2
                color: root.lightColor
                borderSpec: Border.flat(root.bar ? root.bar.background : Color.background, Math.max(1, Style.space(2)))
                x: colorPad.width * colorPad.hue - width / 2
                y: colorPad.height * (1 - colorPad.saturation) - height / 2
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.CrossCursor
                onPressed: function(mouse) { colorPad.pick(mouse) }
                onPositionChanged: function(mouse) { if (pressed) colorPad.pick(mouse) }
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

  // One saved look: swatch, name, value. Click applies it; the row is
  // highlighted while the light matches it.
  component PresetRow: CursorSurface {
    id: row
    required property var modelData
    required property int index
    readonly property bool active: Model.presetActive(root.bulb, modelData)

    width: parent.width
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
    hasCursor: rowMouse.containsMouse
    current: active
    foreground: root.foreground

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.send(Model.copy(row.modelData))
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(nameLabel.implicitHeight, removeButton.implicitHeight)

      Rectangle {
        id: swatch
        width: Style.space(12)
        height: width
        radius: width / 2
        color: Model.presetColor(row.modelData)
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: nameLabel
        textFormat: Text.PlainText
        text: Model.presetLabel(row.modelData)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.active
        elide: Text.ElideRight
        anchors.left: swatch.right
        anchors.leftMargin: Style.space(10)
        anchors.right: valueText.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: valueText
        textFormat: Text.PlainText
        text: Model.presetValue(row.modelData)
        color: row.active ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: removeButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }

      PanelActionButton {
        id: removeButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        property bool pointerOver: false
        opacity: rowMouse.containsMouse || pointerOver ? 1 : 0
        onHovered: function(isHovered) { pointerOver = isHovered }
        iconText: Model.removeGlyph
        tooltipText: "Remove"
        foreground: root.foreground
        hoverColor: root.bar ? root.bar.urgent : Color.urgent
        fontFamily: root.fontFamily
        onClicked: root.removePreset(row.index)
      }
    }
  }

  // Value shown at the right of a section header. Clicking it turns it into a
  // field: Enter commits, Esc or clicking elsewhere cancels.
  component EditableValue: Item {
    id: editable
    property string text: ""
    property string editText: text
    property int maximumLength: 8
    property bool editing: false
    signal committed(string text)

    implicitWidth: editing ? field.width : label.implicitWidth
    implicitHeight: editing ? field.implicitHeight : label.implicitHeight

    function startEdit() {
      editing = true
      root.editingValue = true
      Qt.callLater(function() {
        field.text = editable.editText
        field.selectAll()
        field.forceActiveFocus()
      })
    }

    function endEdit(commit) {
      if (!editing) return
      editing = false
      root.editingValue = false
      if (commit) editable.committed(field.text.trim())
      root.restoreFocus()
    }

    Text {
      id: label
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: !editable.editing
      textFormat: Text.PlainText
      text: editable.text
      color: labelMouse.containsMouse ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.underline: labelMouse.containsMouse

      MouseArea {
        id: labelMouse
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        hoverEnabled: true
        cursorShape: Qt.IBeamCursor
        onClicked: editable.startEdit()
      }
    }

    TextField {
      id: field
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: editable.editing
      width: Style.space(80)
      verticalPadding: 0
      maximumLength: editable.maximumLength
      horizontalAlignment: TextInput.AlignRight
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          editable.endEdit(true)
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          editable.endEdit(false)
          event.accepted = true
        }
      }
      onActiveFocusChanged: if (!activeFocus) editable.endEdit(false)
    }
  }

  // Section header with the current value on the right, over a slider. The
  // value can be typed in; out-of-range numbers are clamped.
  component SliderSection: Column {
    id: section
    property string label: ""
    property string unit: ""
    property bool showValue: true
    property real minimum: 0
    property real maximum: 1
    property real step: 1
    // Dragging rounds to this; typed values are sent as typed.
    property real snap: 1
    property real value: 0
    property real sliderOpacity: 1.0
    signal moved(real value)

    width: parent.width
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(header.implicitHeight, valueEdit.implicitHeight)

      PanelSectionHeader {
        id: header
        text: section.label
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      EditableValue {
        id: valueEdit
        text: section.showValue ? Math.round(slider.dragging ? slider.liveValue : section.value) + section.unit : "--"
        editText: String(Math.round(section.value))
        maximumLength: 5
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        onCommitted: function(text) {
          var v = parseInt(text, 10)
          if (!isNaN(v)) section.moved(Math.max(section.minimum, Math.min(section.maximum, v)))
        }
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
      onMoved: function(v) { section.moved(Math.round(v / section.snap) * section.snap) }
    }
  }
}
