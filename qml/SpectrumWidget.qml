import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui
import "SpectrumModel.js" as Model

// Live spectrum of what is playing.
// Bar: 10 octave bands. Popup: 60 log bands 20 Hz–20 kHz with lows/mids/highs
// and peak hold. With an EQ chain configured (musicSink + speakerSink), a
// Music (pre-EQ) / Speakers (post-EQ) source toggle; otherwise it follows the
// default output.
//
// Hover the widget  -> preview (closes ~300 ms after the pointer leaves both
//                      the widget and the card).
// Click widget/card -> pin: stays open until the widget is clicked again,
//                      Escape, or the × control. Outside clicks don't close it.
// Right-click       -> toggle Music / Speakers (EQ chain configured).
// Middle-click      -> pause / resume the capture.
//
// Paused means the helper process is not running at all, so the widget costs
// no CPU. The state lives in ~/.config/omarchy/spectrum.json and survives a
// restart; the card still opens while paused, to offer the resume button.
//
// Data comes from ../bin/omarchy-spectrum, a passive, read-only monitor
// capture that only runs while this widget is on screen.
//
// NOTE: this shell's plugin hot reload re-uses Qt's cached compile of this
// file, so edits here only go live after `omarchy restart shell`.
Panel {
  id: root
  moduleName: "io.github.dragosol.spectrum"
  ipcTarget: "io.github.dragosol.spectrum"
  manageIpc: false   // one handler below serves panel + source methods

  // Bundled with the plugin; run through python3 so it needs no exec bit.
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("../bin/omarchy-spectrum")).replace(/^file:\/\//, ""))

  // ---- settings (shell.json entry) -----------------------------------------
  readonly property string musicSink: String(setting("musicSink", "")).trim()
  readonly property string speakerSink: String(setting("speakerSink", "")).trim()
  readonly property bool chainConfigured: musicSink !== "" && speakerSink !== ""

  // ---- pause (persisted) --------------------------------------------------
  // Paused stops the capture helper outright: no pw-record, no FFT, no CPU.
  // Kept in a watched file, so a script can flip it even while paused (the
  // control FIFO lives in the helper and is gone then):
  //   ~/.config/omarchy/spectrum.json  {"paused": true}
  readonly property bool paused: pauseState.paused

  FileView {
    id: settingsFile
    path: Quickshell.env("HOME") + "/.config/omarchy/spectrum.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onAdapterUpdated: writeAdapter()
    onLoadFailed: function(error) { if (error === FileViewError.FileNotFound) writeAdapter() }

    JsonAdapter {
      id: pauseState
      property bool paused: false
    }
  }

  function setPaused(p) {
    if (pauseState.paused === !!p) return
    pauseState.paused = !!p
    console.log("spectrum: " + (p ? "paused" : "resumed"))
  }
  function togglePaused() { setPaused(!root.paused) }

  // ---- source selection ---------------------------------------------------
  property string source: "music"   // "music" | "speakers"

  readonly property var defaultSink: Pipewire.defaultAudioSink
  readonly property string defaultSinkName: defaultSink && defaultSink.name ? defaultSink.name : ""
  readonly property string defaultSinkLabel: defaultSink ? (defaultSink.description || defaultSink.nickname || defaultSinkName) : ""
  // With an EQ chain configured and the default output on it, the toggle picks
  // which end of the chain to watch. Otherwise: the default output's monitor.
  readonly property bool speakerChain: chainConfigured && Model.inChain(defaultSinkName, musicSink, speakerSink)
  readonly property string target: speakerChain
    ? (source === "speakers" ? speakerSink : musicSink)
    : defaultSinkName

  readonly property string statusLine: {
    if (paused) return "PAUSED · CAPTURE STOPPED"
    if (captureState.indexOf("missing") === 0) return "NEEDS " + captureState.substring(8).toUpperCase() + " · SEE README"
    var s = !speakerChain ? "DEFAULT OUTPUT · " + String(defaultSinkLabel || "…").toUpperCase()
      : (source === "speakers" ? "SPEAKERS · AFTER EQ + LIMITER" : "MUSIC · BEFORE SPEAKER EQ")
    if (captureState.indexOf("restart") === 0) s += " · RECONNECTING"
    return s
  }

  function cycleSource() {
    if (speakerChain) source = source === "music" ? "speakers" : "music"
  }

  // ---- popup state: hover preview + click-to-pin --------------------------
  property bool pinned: false
  property bool hoverPreview: false
  property bool suppressHover: false   // after a click-close, until the pointer leaves
  property bool focusOnPin: false      // take keyboard focus (Escape) on this pin?
  readonly property bool hovering: button.tooltipHovered || (popup.visible && popup.containsMouse)
  readonly property bool popupVisible: pinned || hoverPreview

  function stateString() {
    return (pinned ? "pinned" : (hoverPreview ? "preview" : "closed")) + " " + source + " " + target
      + (paused ? " paused" : " running")
  }

  // withFocus: true for a real click on the widget/card (the user is
  // interacting, so Escape should work at once); false for scripts/IPC so a
  // pin never steals keystrokes from the window being typed in.
  function pin(withFocus) {
    suppressHover = false
    graceTimer.stop()
    focusOnPin = !!withFocus
    pinned = true
  }

  // Overrides Panel.close(): unpins and drops the preview; a click-close
  // doesn't immediately reopen as a preview under the pointer.
  function close(reason) {
    if (pinned) console.log("spectrum: unpinned (" + (reason || "close") + ")")
    openDelay.stop()
    graceTimer.stop()
    pinned = false
    hoverPreview = false
    if (hovering) suppressHover = true
  }
  function open() { pin(false) }
  function toggle() { if (pinned) close("toggle"); else pin(false) }

  function clickWidget() {
    if (pinned) close("widget click")
    else pin(true)
  }

  function control(cmd) {
    if (cmd === "preview") { if (!pinned) hoverPreview = true }
    else if (cmd === "unpreview") { if (!pinned) hoverPreview = false }
    else if (cmd === "pin") pin(false)
    else if (cmd === "close") close("ctl")
    else if (cmd === "toggle") toggle()
    else if (cmd === "music" || cmd === "speakers") source = cmd
    else if (cmd === "cycle") cycleSource()
    else if (cmd === "pause") setPaused(true)
    else if (cmd === "resume") setPaused(false)
    else if (cmd === "playpause") togglePaused()
    console.log("spectrum: " + cmd + " -> " + stateString())
  }

  onHoveringChanged: {
    if (hovering) {
      graceTimer.stop()
      if (!pinned && !hoverPreview && !suppressHover && !paused) openDelay.restart()
    } else {
      openDelay.stop()
      suppressHover = false
      if (hoverPreview && !pinned) graceTimer.restart()
    }
  }

  onPinnedChanged: {
    popup.focusPrimed = false
    if (pinned) {
      hoverPreview = false
      focusPrimeTimer.restart()
    } else {
      focusPrimeTimer.stop()
    }
  }

  Timer {
    id: openDelay
    interval: 140
    onTriggered: if (root.hovering && !root.pinned && !root.suppressHover && !root.paused) root.hoverPreview = true
  }

  Timer {
    id: graceTimer
    interval: 300
    onTriggered: if (!root.hovering && !root.pinned) root.hoverPreview = false
  }

  // Click-pins: brief Exclusive keyboard focus so Escape works straight away.
  // Every pin then settles on OnDemand: other windows stay usable and a click
  // on the card refocuses it. Script pins go None -> OnDemand, which Hyprland
  // does not auto-focus on an already-mapped surface.
  Timer {
    id: focusPrimeTimer
    interval: 75
    onTriggered: {
      if (!root.pinned) return
      popup.focusPrimed = true
      if (root.focusOnPin) keyItem.forceActiveFocus()
    }
  }

  // omarchy-shell io.github.dragosol.spectrum open|close|toggle|preview|music|speakers|cycle|state
  // (Registered on shell start. After a plugin hot reload Quickshell keeps the
  // old handler; the control FIFO always reaches the live widget:
  //   timeout 3 sh -c 'echo pin > $XDG_RUNTIME_DIR/omarchy-spectrum.ctl')
  IpcHandler {
    target: "io.github.dragosol.spectrum"
    function open(): void { root.pin(false) }
    function show(): void { root.pin(false) }
    function close(): void { root.close("ipc") }
    function hide(): void { root.close("ipc") }
    function toggle(): void { root.toggle() }
    function preview(): void { root.control("preview") }
    function music(): void { root.source = "music" }
    function speakers(): void { root.source = "speakers" }
    function cycle(): void { root.cycleSource() }
    function pause(): void { root.setPaused(true) }
    function resume(): void { root.setPaused(false) }
    function playpause(): void { root.togglePaused() }
    function state(): string { return root.stateString() }
  }

  // ---- capture lifecycle --------------------------------------------------
  readonly property bool windowShown: QsWindow.window ? QsWindow.window.visible : true
  readonly property bool barHidden: !!(bar && bar.barHidden === true)
  readonly property bool captureWanted: !paused && (popupVisible || (visible && windowShown && !barHidden))

  property string captureState: ""
  property var barLevels: []
  property var popLevels: []
  property var popPeaks: []
  property var regionLevels: [-100, -100, -100]
  readonly property bool popupSilent: regionLevels[0] <= -99 && regionLevels[1] <= -99 && regionLevels[2] <= -99

  function send(cmd) {
    if (proc.running) proc.write(cmd + "\n")
  }

  function syncCapture() {
    if (captureWanted && !proc.running) proc.running = true
    else if (!captureWanted && proc.running) proc.running = false
  }

  function clearLevels() {
    barLevels = []
    popLevels = []
    popPeaks = []
    regionLevels = [-100, -100, -100]
  }

  function handleLine(line) {
    var c = line.charAt(0)
    if (c === "F") {
      var parts = line.substring(2).split(" | ")
      barLevels = parts[0].split(" ").map(Number)
      if (parts.length === 4) {
        popLevels = parts[1].split(" ").map(Number)
        popPeaks = parts[2].split(" ").map(Number)
        regionLevels = parts[3].split(" ").map(Number)
      }
    } else if (c === "S") {
      captureState = line.substring(2)
    } else if (c === "C") {
      control(line.substring(2))
    }
  }

  onCaptureWantedChanged: syncCapture()
  onPausedChanged: {
    if (!paused) return
    clearLevels()
    // Paused: hovering no longer previews (a click still pins, to resume).
    openDelay.stop()
    if (hoverPreview && !pinned) hoverPreview = false
  }
  onTargetChanged: send("target " + target)
  onPopupVisibleChanged: {
    popLevels = []
    popPeaks = []
    regionLevels = [-100, -100, -100]
    // high-resolution analysis only while the popup is on screen
    send("mode " + (popupVisible ? "popup" : "bar"))
  }
  Component.onCompleted: syncCapture()

  Process {
    id: proc
    // Read once per start; later changes are pushed over stdin.
    command: ["python3", root.helper, "--mode", root.popupVisible ? "popup" : "bar", "--target", root.target]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser { onRead: function(line) { console.warn("spectrum:", line) } }
    onExited: function(code) {
      root.clearLevels()
      if (root.captureWanted) restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 2000
    onTriggered: root.syncCapture()
  }

  // ---- theme --------------------------------------------------------------
  property var palette: ({})
  readonly property var tints: Model.pickTints(palette, Color.foreground, Color.accent)
  readonly property color popupText: Color.popups.text
  readonly property color popupDim: Util.alpha(Color.popups.text, 0.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  FileView {
    id: paletteFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.palette = Model.parsePalette(text())
    onFileChanged: reload()
  }

  Connections {
    target: Color
    function onAccentChanged() { paletteFile.reload() }
    function onForegroundChanged() { paletteFile.reload() }
  }

  // ---- bar mini view ------------------------------------------------------
  readonly property int miniBarWidth: 3
  readonly property int miniGap: 2
  readonly property int miniWidth: Model.BAR_BANDS * (miniBarWidth + miniGap) - miniGap
  readonly property int barThickness: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property bool verticalBar: bar ? bar.vertical : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.verticalBar ? -1 : root.miniWidth + 14
    fixedHeight: root.verticalBar ? root.miniWidth + 14 : -1
    tooltipText: ""   // the hover preview replaces the tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.togglePaused()
      else if (mouseButton === Qt.RightButton) root.cycleSource()
      else root.clickWidget()
    }

    Item {
      id: mini
      anchors.centerIn: parent
      width: root.miniWidth
      height: Math.max(8, Math.round(root.barThickness * 0.58))
      rotation: root.verticalBar ? -90 : 0

      Repeater {
        model: root.paused ? 0 : Model.BAR_BANDS

        delegate: Rectangle {
          required property int index
          readonly property real level: root.barLevels.length > index ? root.barLevels[index] : -100
          readonly property real frac: Model.norm(level, Model.BAR_DB_TOP, Model.BAR_DB_BOTTOM)
          x: index * (root.miniBarWidth + root.miniGap)
          width: root.miniBarWidth
          height: Math.max(2, Math.round(frac * mini.height))
          y: mini.height - height
          radius: 1
          color: root.tints[Model.regionIndex(Model.barCentre(index))]
          opacity: frac > 0 ? 0.55 + 0.45 * frac : 0.3
        }
      }

      // Paused: the bars are gone because nothing is being captured.
      Text {
        textFormat: Text.PlainText
        visible: root.paused
        anchors.centerIn: parent
        rotation: root.verticalBar ? 90 : 0
        text: "󰏤"
        color: root.bar ? root.bar.barForeground : Color.foreground
        opacity: 0.45
        font.family: root.fontFamily
        font.pixelSize: Math.max(10, Math.round(mini.height * 0.9))
      }

      // pinned marker: a hairline under the mini spectrum
      Rectangle {
        visible: root.pinned
        anchors.top: parent.bottom
        anchors.topMargin: 2
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width
        height: 1
        color: root.bar ? root.bar.barForeground : Color.foreground
        opacity: 0.6
      }
    }
  }

  // ---- popup analyzer -----------------------------------------------------
  // A card-sized layer-shell surface placed under the widget. Card-sized (not
  // a full-screen overlay) because the analyzer repaints 30x/s; no focus grab
  // so a pinned card survives clicks in other windows.
  PanelWindow {
    id: popup

    readonly property var anchorWindow: button.QsWindow.window
    readonly property string barPos: root.bar ? root.bar.position : "top"
    readonly property int gap: Style.gapsOut
    readonly property int margin: Style.gapsOut
    readonly property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    readonly property real screenW: screen ? screen.width : 0
    readonly property real screenH: screen ? screen.height : 0
    readonly property real barW: anchorWindow ? anchorWindow.width : screenW
    readonly property real barH: anchorWindow ? anchorWindow.height : 0
    readonly property bool containsMouse: cardHover.hovered
    property bool focusPrimed: false

    readonly property real insetsX: card.contentLeftInset + card.contentRightInset
    readonly property real insetsY: card.contentTopInset + card.contentBottomInset
    readonly property int cardW: Math.round(Math.min(Style.space(660) + insetsX, screenW > 0 ? screenW - 2 * margin : 100000))
    readonly property int cardH: Math.round(Math.min(panelColumn.implicitHeight + insetsY, screenH > 0 ? screenH - barH - 2 * margin : 100000))

    TransformWatcher {
      id: anchorWatcher
      a: popup.anchorWindow ? popup.anchorWindow.contentItem : null
      b: button
    }

    readonly property point anchorPos: {
      anchorWatcher.transform  // reactive dependency
      if (!popup.anchorWindow) return Qt.point(0, 0)
      return button.mapToItem(popup.anchorWindow.contentItem, 0, 0)
    }

    // Same placement rules as the shell's KeyboardPanel.
    readonly property point origin: {
      var x = 0, y = 0
      if (barPos === "bottom") {
        x = anchorPos.x + button.width / 2 - cardW / 2
        y = screenH - barH - cardH - gap
      } else if (barPos === "left") {
        x = barW + gap
        y = anchorPos.y + button.height / 2 - cardH / 2
      } else if (barPos === "right") {
        x = screenW - barW - cardW - gap
        y = anchorPos.y + button.height / 2 - cardH / 2
      } else {
        x = anchorPos.x + button.width / 2 - cardW / 2
        y = barH + gap
      }
      x = Math.max(margin, Math.min(x, screenW - cardW - margin))
      y = Math.max(margin, Math.min(y, screenH - cardH - margin))
      return Qt.point(Math.round(x), Math.round(y))
    }

    screen: anchorWindow ? anchorWindow.screen : null
    visible: root.popupVisible || card.opacity > 0
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: cardW
    implicitHeight: cardH
    anchors {
      top: true
      left: true
    }
    margins {
      top: origin.y
      left: origin.x
    }

    WlrLayershell.namespace: "dragos-spectrum"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: !root.pinned ? WlrKeyboardFocus.None
      : (focusPrimed ? WlrKeyboardFocus.OnDemand
        : (root.focusOnPin ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None))

    BorderSurface {
      id: card
      anchors.fill: parent
      color: Color.popups.background
      borderSpec: popup.borderSpec
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius
      opacity: root.popupVisible ? 1.0 : 0

      Behavior on opacity {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      HoverHandler { id: cardHover }

      Item {
        id: keyItem
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.close("escape"); event.accepted = true }
          else if (event.text === "m" && root.speakerChain) { root.source = "music"; event.accepted = true }
          else if (event.text === "s" && root.speakerChain) { root.source = "speakers"; event.accepted = true }
          else if (event.text === "p") { root.togglePaused(); event.accepted = true }
        }
      }

      Item {
        id: contentHolder
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Column {
          id: panelColumn
          width: parent.width
          spacing: Style.space(12)

          // Header: title + pin state, status, source toggle, close
          Item {
            width: parent.width
            implicitHeight: Math.max(titleCol.implicitHeight, rightControls.implicitHeight)

            Column {
              id: titleCol
              anchors.left: parent.left
              anchors.right: rightControls.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Row {
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  id: titleText
                  text: "Spectrum"
                  color: root.popupText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.baseline: titleText.baseline
                  text: root.pinned ? "󰐃 PINNED" : "CLICK TO PIN"
                  color: root.pinned ? root.tints[0] : root.popupDim
                  opacity: root.pinned ? 0.9 : 0.8
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.statusLine
                elide: Text.ElideRight
                color: root.popupDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            Row {
              id: rightControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              ButtonGroup {
                visible: root.speakerChain
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.popupText
                fontFamily: root.fontFamily
                focusable: false
                value: root.source
                options: [
                  { value: "music", label: "Music", tooltip: root.musicSink + " monitor — the music before the speaker EQ (m)" },
                  { value: "speakers", label: "Speakers", tooltip: root.speakerSink + " monitor — what the speakers receive after EQ (s)" }
                ]
                onChanged: function(value) { root.source = value }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.chainConfigured && !root.speakerChain
                anchors.verticalCenter: parent.verticalCenter
                text: "Not on the EQ chain"
                color: root.popupDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              // Pause / resume the capture
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(24)
                height: Style.space(24)
                radius: Style.cornerRadius
                color: pauseArea.containsMouse ? Style.hoverFill : "transparent"
                opacity: root.pinned ? 1 : 0.45

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.paused ? "󰐊" : "󰏤"
                  color: root.paused ? root.tints[0] : root.popupText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                MouseArea {
                  id: pauseArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.togglePaused()
                }
              }

              // Close / unpin
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(24)
                height: Style.space(24)
                radius: Style.cornerRadius
                color: closeArea.containsMouse ? Style.hoverFill : "transparent"
                opacity: root.pinned ? 1 : 0.45

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: "󰅖"
                  color: root.popupText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                MouseArea {
                  id: closeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.close("× button")
                }
              }
            }
          }

          Item {
            id: analyzer
            width: parent.width
            readonly property int axisW: Style.space(34)
            readonly property int stripH: Style.space(38)
            readonly property int hzH: Style.space(18)
            readonly property int plotH: Style.space(230)
            readonly property real plotW: width - axisW
            implicitHeight: stripH + Style.space(6) + plotH + hzH

            // Region header strip: name, range, live band power
            Repeater {
              model: Model.REGIONS

              delegate: Item {
                required property var modelData
                required property int index
                readonly property color tint: root.tints[index]
                readonly property real level: root.regionLevels[index]
                x: analyzer.axisW + Model.xFrac(modelData.lo) * analyzer.plotW
                width: (Model.xFrac(modelData.hi) - Model.xFrac(modelData.lo)) * analyzer.plotW
                height: analyzer.stripH

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.leftMargin: 1
                  anchors.rightMargin: 1
                  height: Math.max(2, Style.space(2))
                  radius: height / 2
                  color: parent.tint
                  opacity: 0.85
                }

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.top: parent.top
                  spacing: 0

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: parent.parent.tint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.4
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.range
                    color: root.popupDim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.top: parent.top
                  text: Model.formatDb(parent.level)
                  color: root.popupText
                  opacity: parent.level <= -99 ? 0.4 : 1
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }
            }

            Item {
              id: plot
              x: analyzer.axisW
              y: analyzer.stripH + Style.space(6)
              width: analyzer.plotW
              height: analyzer.plotH

              // Region backgrounds
              Repeater {
                model: Model.REGIONS
                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  x: Model.xFrac(modelData.lo) * plot.width
                  width: (Model.xFrac(modelData.hi) - Model.xFrac(modelData.lo)) * plot.width
                  height: plot.height
                  color: Util.alpha(root.tints[index], index === 1 ? 0.045 : 0.075)
                }
              }

              // dB grid
              Repeater {
                model: Model.DB_TICKS
                delegate: Rectangle {
                  required property var modelData
                  width: plot.width
                  height: 1
                  y: Math.round((1 - Model.norm(modelData, Model.DB_TOP, Model.DB_BOTTOM)) * (plot.height - 1))
                  color: Util.alpha(root.popupText, modelData === 0 ? 0.16 : 0.07)
                }
              }

              // Hz grid
              Repeater {
                model: Model.HZ_TICKS
                delegate: Rectangle {
                  required property var modelData
                  x: Math.round(Model.xFrac(modelData.hz) * plot.width)
                  width: 1
                  height: plot.height
                  color: Util.alpha(root.popupText, 0.06)
                }
              }

              // Region boundaries (250 Hz, 4 kHz)
              Repeater {
                model: [250, 4000]
                delegate: Rectangle {
                  required property var modelData
                  x: Math.round(Model.xFrac(modelData) * plot.width)
                  width: 1
                  height: plot.height
                  color: Util.alpha(root.popupText, 0.22)
                }
              }

              // Bars + peak markers
              Repeater {
                model: Model.POP_BANDS
                delegate: Item {
                  id: band
                  required property int index
                  readonly property real slot: plot.width / Model.POP_BANDS
                  readonly property real gap: Math.max(1, slot * 0.24)
                  readonly property color tint: root.tints[Model.regionIndex(Model.popCentre(index))]
                  readonly property real level: root.popLevels.length > index ? root.popLevels[index] : -100
                  readonly property real peak: root.popPeaks.length > index ? root.popPeaks[index] : -100
                  x: index * slot + gap / 2
                  width: slot - gap
                  height: plot.height

                  Rectangle {
                    readonly property real frac: Model.norm(band.level, Model.DB_TOP, Model.DB_BOTTOM)
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.round(frac * plot.height)
                    visible: height > 0
                    radius: Math.min(2, width / 2)
                    gradient: Gradient {
                      GradientStop { position: 0.0; color: band.tint }
                      GradientStop { position: 1.0; color: Util.alpha(band.tint, 0.28) }
                    }
                  }

                  Rectangle {
                    readonly property real frac: Model.norm(band.peak, Model.DB_TOP, Model.DB_BOTTOM)
                    visible: frac > 0.01
                    width: parent.width
                    height: 2
                    radius: 1
                    y: Math.round((1 - frac) * plot.height) - 1
                    color: Qt.lighter(band.tint, 1.25)
                    opacity: 0.95
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                visible: root.popupSilent
                text: root.paused ? "Paused"
                  : (root.captureState.indexOf("restart") === 0 ? "Reconnecting to " + root.target + "…" : "No signal")
                color: root.popupDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            // dB axis labels
            Repeater {
              model: Model.DB_TICKS
              delegate: Text {
                required property var modelData
                anchors.right: plot.left
                anchors.rightMargin: Style.space(6)
                y: plot.y + Math.round((1 - Model.norm(modelData, Model.DB_TOP, Model.DB_BOTTOM)) * (plot.height - 1)) - height / 2
                text: modelData === 0 ? "0" : "−" + Math.abs(modelData)
                color: root.popupDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: plot.left
              anchors.rightMargin: Style.space(6)
              y: plot.y + plot.height - height
              text: "dB"
              color: root.popupDim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            // Hz axis labels
            Repeater {
              model: Model.HZ_TICKS
              delegate: Text {
                required property var modelData
                x: plot.x + Model.xFrac(modelData.hz) * plot.width - width / 2
                y: plot.y + plot.height + Style.space(3)
                text: modelData.label
                color: root.popupDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: plot.right
              y: plot.y + plot.height + Style.space(3)
              text: "Hz"
              color: root.popupDim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          PanelSeparator { width: parent.width }

          // Balance + footer
          Column {
            width: parent.width
            spacing: Style.space(4)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.popupSilent ? "Balance vs mids   —"
                : "Balance vs mids   lows " + Model.formatDelta(root.regionLevels[0] - root.regionLevels[1])
                  + "   ·   highs " + Model.formatDelta(root.regionLevels[2] - root.regionLevels[1])
              color: root.popupText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideMiddle
              text: (root.paused
                  ? "Capture stopped — no pw-record, no CPU"
                  : "1/6-octave band power, dBFS · peak hold 1.2 s · " + (root.target || "default sink") + ".monitor")
                + (root.pinned ? "   ·   Esc / × closes   ·   p " + (root.paused ? "resumes" : "pauses") : "")
              color: root.popupDim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Preview: a click anywhere on the card pins it (controls go live once
      // pinned). A real click, so the pin takes keyboard focus for Escape.
      MouseArea {
        anchors.fill: parent
        z: 100
        visible: !root.pinned
        cursorShape: Qt.PointingHandCursor
        onClicked: root.pin(true)
      }
    }
  }
}
