import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Weather panel: current conditions, a click-to-edit location picker, and a
// compact multi-day forecast. The popup is opened from the bar widget and
// anchored under it.
//
// Data comes from Open-Meteo. The location lives in omarchy's shared
// weather.json (owned by omarchy-weather-location), so the built-in weather
// panel and this one always agree on where "here" is.
Panel {
  id: root
  moduleName: "joseluis.weather"
  ipcTarget: "joseluis.weather"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Location, mirrored from weather.json ------------------------------
  property var locationState: ({ name: "", latitude: null, longitude: null })
  property real resolvedLatitude: NaN
  property real resolvedLongitude: NaN
  property string resolvedName: ""
  property bool loading: false

  // ---- Current conditions and forecast -----------------------------------
  property var report: null

  readonly property var current: report && report.current ? report.current : null
  readonly property bool useImperial: Model.shouldUseImperial(setting("unit", "metric"), Qt.locale().name)
  readonly property string unitLetter: useImperial ? "F" : "C"
  readonly property string label: Model.currentIcon(report)
  readonly property string tempText: current ? Model.displayTemp(current.temperature_2m, useImperial) : ""
  readonly property string barLabel: (label !== "" && tempText !== "") ? label + " " + tempText + "°" + unitLetter : label
  readonly property string reportLocation: locationState.name || resolvedName || ""

  readonly property string feelsText: (current && current.apparent_temperature !== undefined)
    ? Model.displayTemp(current.apparent_temperature, useImperial) + "°" + unitLetter : ""
  readonly property string windText: (current && current.wind_speed_10m !== undefined)
    ? (useImperial ? Math.round(current.wind_speed_10m * 0.621371) + " mph" : Math.round(current.wind_speed_10m) + " km/h") : ""
  readonly property string humidityText: (current && current.relative_humidity_2m !== undefined)
    ? Math.round(current.relative_humidity_2m) + "%" : ""

  readonly property var forecastDays: Model.forecastDays(report, Qt.formatDate(new Date(), "yyyy-MM-dd"), 4)

  // ---- Location editing state --------------------------------------------
  property bool editingLocation: false
  property bool savingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodeQuery: ""
  property string geocodeActive: ""
  property bool geocodeForEditor: false

  // ---- Lifecycle ---------------------------------------------------------
  function open() {
    root.controller.show()
    locationFile.reload()
    refresh()
  }

  function close() {
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // ---- Resolve the configured location, then fetch ------------------------
  function refresh() {
    if (!isNaN(resolvedLatitude) && !isNaN(resolvedLongitude)) {
      fetchForecast()
      return
    }
    var name = String(locationState.name).replace(/^\s+|\s+$/g, "")
    if (name !== "") {
      startGeocode(false, name)
      return
    }
    if (!locationProc.running) {
      loading = true
      locationProc.running = true
    }
  }

  function startGeocode(forEditor, query) {
    geocodeForEditor = forEditor
    geocodeQuery = query
    if (!geocodeProc.running) runGeocode()
  }

  function runGeocode() {
    geocodeActive = geocodeQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "6",
      "https://geocoding-api.open-meteo.com/v1/search?count=5&language=en&format=json&name=" + encodeURIComponent(geocodeActive)]
    geocodeProc.running = true
  }

  function fetchForecast() {
    if (fetchProc.running) return
    loading = true
    fetchProc.command = ["curl", "-fsS", "--max-time", "7",
      "https://api.open-meteo.com/v1/forecast?latitude=" + encodeURIComponent(resolvedLatitude)
      + "&longitude=" + encodeURIComponent(resolvedLongitude)
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      + "&forecast_days=5&timezone=auto"]
    fetchProc.running = true
  }

  function applyLocationFile(raw) {
    var next = Model.parseLocationFile(raw)
    var changed = next.name !== locationState.name
      || next.latitude !== locationState.latitude
      || next.longitude !== locationState.longitude
    if (changed) {
      locationState = next
      resolvedLatitude = NaN
      resolvedLongitude = NaN
      resolvedName = next.name
    }
    if (changed || report === null) refresh()
  }

  // ---- Location editing ---------------------------------------------------
  function startEditingLocation() {
    editingLocation = true
    savingLocation = false
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = root.reportLocation
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var loc = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (loc.name === "") { clearLocation(); return }
    applyPickedLocation(loc)
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    applyPickedLocation(suggestion)
  }

  function applyPickedLocation(loc) {
    savingLocation = true
    locationState = { name: loc.name, latitude: loc.latitude, longitude: loc.longitude }
    resolvedLatitude = (loc.latitude === null || loc.latitude === undefined) ? NaN : Number(loc.latitude)
    resolvedLongitude = (loc.longitude === null || loc.longitude === undefined) ? NaN : Number(loc.longitude)
    resolvedName = loc.name
    persistLocation(loc.name, loc.latitude, loc.longitude)
    if (!isNaN(resolvedLatitude) && !isNaN(resolvedLongitude)) fetchForecast()
  }

  function clearLocation() {
    persistLocation("", null, null)
    locationState = { name: "", latitude: null, longitude: null }
    resolvedLatitude = NaN
    resolvedLongitude = NaN
    resolvedName = ""
    cancelEditingLocation()
  }

  function persistLocation(name, latitude, longitude) {
    var hasCoords = latitude !== null && latitude !== undefined && longitude !== null && longitude !== undefined
    if (name && hasCoords) locationSaveProc.command = ["omarchy-weather-location", "--set", name, latitude + "," + longitude]
    else if (name) locationSaveProc.command = ["omarchy-weather-location", "--set", name]
    else locationSaveProc.command = ["omarchy-weather-location", "--clear"]
    locationSaveProc.running = true
  }

  function finishSavingLocation() {
    if (!savingLocation) return
    savingLocation = false
    cancelEditingLocation()
  }

  // ---- State file + network ----------------------------------------------
  FileView {
    id: locationFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyLocationFile(text())
    onLoadFailed: root.applyLocationFile("")
  }

  // The first read can race shell startup, leaving a stored location
  // unhonored. One delayed reload self-corrects; when the first read was fine
  // it is a no-op because identical state triggers no refetch.
  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  Process {
    id: locationProc
    command: ["omarchy-weather-location"]
    onExited: function(exitCode) { if (exitCode !== 0) root.loading = false }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var name = String(text || "").replace(/^\s+|\s+$/g, "")
        if (name === "") { root.loading = false; return }
        root.resolvedName = name
        root.startGeocode(false, name)
      }
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (root.geocodeForEditor) {
          root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(raw) : []
          root.suggestionIndex = 0
        } else {
          var hit = Model.firstGeocodingResult(raw)
          if (hit) {
            root.resolvedLatitude = Number(hit.latitude)
            root.resolvedLongitude = Number(hit.longitude)
            root.resolvedName = hit.name
            root.fetchForecast()
          } else {
            root.loading = false
          }
        }
        if (root.geocodeQuery !== root.geocodeActive && String(root.geocodeQuery).trim() !== "")
          Qt.callLater(root.runGeocode)
      }
    }
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") { root.loading = false; return }
        try {
          root.report = JSON.parse(raw)
          root.loading = false
          root.finishSavingLocation()
        } catch (e) {
          root.loading = false
        }
      }
    }
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.savingLocation = false; return }
      locationFile.reload()
      if (!root.savingLocation) return
      if (!isNaN(root.resolvedLatitude) && !isNaN(root.resolvedLongitude)) fetchForecast()
      else root.startGeocode(false, root.locationState.name)
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 350
    onTriggered: root.startGeocode(true, String(locationField.text).trim())
  }

  Timer {
    interval: Math.max(1, Number(setting("refreshMinutes", 15))) * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { if (!root.editingLocation) root.refresh() }
  }

  // ---- Popup --------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: scroll.width
          spacing: Style.space(14)

          // ---- Hero: icon + temperature on the left, place + stats right.
          Item {
            width: parent.width
            height: Math.max(heroLeft.height, heroRight.height)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              anchors.verticalCenterOffset: statsRow.visible
                ? (statsRow.mapToItem(parent, 0, statsRow.height / 2).y - parent.height / 2)
                : 0
              spacing: Style.space(12)

              Text {
                id: heroIcon
                textFormat: Text.PlainText
                text: root.label !== "" ? root.label : "—"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: 46
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 0
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  id: tempBig
                  textFormat: Text.PlainText
                  text: root.tempText !== "" ? root.tempText : "—"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: 42
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.current ? "°" + root.unitLetter : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  anchors.top: tempBig.top
                  anchors.topMargin: Style.space(6)
                }
              }
            }

            Column {
              id: heroRight
              anchors.right: parent.right
              anchors.rightMargin: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              // Location label; click to edit.
              Row {
                id: locationRow
                visible: !root.editingLocation
                anchors.right: parent.right
                spacing: Style.space(5)

                TapHandler { onTapped: root.startEditingLocation() }
                HoverHandler { cursorShape: Qt.PointingHandCursor }

                Text {
                  textFormat: Text.PlainText
                  text: "\uf041"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.reportLocation !== "" ? root.reportLocation.toUpperCase() : "SET LOCATION"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // Location editor.
              Row {
                id: editorRow
                visible: root.editingLocation
                anchors.right: parent.right
                spacing: Style.space(6)

                TextField {
                  id: locationField
                  width: Style.space(180)
                  enabled: !root.savingLocation
                  placeholderText: "Search city"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  onTextChanged: if (root.editingLocation && !root.savingLocation) geocodeDebounce.restart()

                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.cancelEditingLocation()
                      event.accepted = true
                    } else if (event.key === Qt.Key_Down) {
                      if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                      event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                      if (root.suggestionIndex > 0) root.suggestionIndex--
                      event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.commitLocation()
                      event.accepted = true
                    }
                  }
                }

                Rectangle {
                  width: Style.space(20)
                  height: Style.space(20)
                  anchors.verticalCenter: parent.verticalCenter
                  radius: Math.min(4, Style.cornerRadius)
                  color: !root.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"

                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.savingLocation ? "\uf021" : "✕"
                    font.family: root.fontFamily
                    color: Qt.darker(root.foreground, 1.4)
                    font.pixelSize: Style.font.bodySmall

                    RotationAnimator on rotation {
                      running: root.savingLocation && !Style.reduceMotion
                      from: 0; to: 360
                      duration: 800
                      loops: Animation.Infinite
                    }
                  }

                  MouseArea {
                    id: clearLocationArea
                    anchors.fill: parent
                    enabled: !root.savingLocation
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.clearLocation()
                  }
                }
              }

              // Stats.
              Row {
                id: statsRow
                visible: !!root.current
                anchors.right: parent.right
                spacing: Style.space(20)

                Repeater {
                  model: [
                    { label: "FEELS", value: root.feelsText },
                    { label: "WIND", value: root.windText },
                    { label: "HUMID", value: root.humidityText }
                  ]

                  Column {
                    required property var modelData
                    spacing: Style.space(4)

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.label
                      color: Qt.darker(root.foreground, 1.5)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.value
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                    }
                  }
                }
              }
            }
          }

          // ---- Geocoding suggestions while editing.
          Column {
            visible: root.editingLocation && !root.savingLocation && root.locationSuggestions.length > 0
            width: parent.width

            Repeater {
              model: root.locationSuggestions

              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: suggestionRow.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: index === root.suggestionIndex ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"

                Row {
                  id: suggestionRow
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: index === root.suggestionIndex ? Style.hoverStateColor(root.foreground, Commons.Color.accent) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: modelData.description
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = index
                  onClicked: root.pickSuggestion(modelData)
                }
              }
            }
          }

          Text {
            visible: !root.current && !root.editingLocation
            textFormat: Text.PlainText
            text: root.loading ? "Fetching weather…" : "No weather available"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Divider + forecast strip.
          Rectangle {
            visible: root.forecastDays.length > 0
            width: parent.width
            height: Style.spacing.hairline
            color: root.foreground
            opacity: 0.12
          }

          Item {
            visible: root.forecastDays.length > 0
            width: parent.width
            height: forecastRow.height

            Row {
              id: forecastRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              Repeater {
                model: root.forecastDays

                Item {
                  required property var modelData
                  width: Style.space(74)
                  height: forecastCell.height

                  Column {
                    id: forecastCell
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(6)

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      textFormat: Text.PlainText
                      text: Model.dayIcon(modelData)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.display
                    }

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      textFormat: Text.PlainText
                      text: Model.dayName(modelData.date, function(date) { return Qt.formatDate(date, "ddd") }).toUpperCase()
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Row {
                      anchors.horizontalCenter: parent.horizontalCenter
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: Model.bareTemp(modelData, "max", root.useImperial)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: Model.bareTemp(modelData, "min", root.useImperial)
                        color: Qt.darker(root.foreground, 1.5)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
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
  }
}
