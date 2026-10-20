import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// Clock and date at the top; weather, media and system cards along the
// bottom. Other monitors get the clock, date and weather only. Colors come
// from the theme's lock colors, so light and dark themes both work.
Item {
  id: root

  property var info: null
  property bool primary: true

  readonly property real s: Math.max(0.8, Math.min(1.35, Math.min(width / 1280, height / 800)))
  readonly property var locale: Qt.locale(Commons.I18n.formatLocale)
  readonly property var weather: info ? info.weather : null

  component Label: LockLabel {}

  component Card: Rectangle {
    width: Math.round(336 * root.s)
    height: Math.round(84 * root.s)
    radius: Math.round(10 * root.s)
    color: Commons.Color.lock.background
  }

  component Stat: Column {
    property string label
    property string value
    width: Math.round(130 * root.s)
    spacing: 2
    Label { text: parent.label; color: Commons.Color.lock.placeholder; font.pixelSize: Math.round(12 * root.s) }
    Label { text: parent.value; width: parent.width; font.pixelSize: Math.round(15 * root.s) }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  Column {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: Math.round(parent.height * 0.11)
    spacing: Math.round(10 * root.s)

    Label {
      anchors.horizontalCenter: parent.horizontalCenter
      text: clock.date.toLocaleTimeString(root.locale, "HH:mm")
      font.pixelSize: Math.round(128 * root.s)
      font.weight: Font.Light
      font.letterSpacing: 4
    }
    Label {
      anchors.horizontalCenter: parent.horizontalCenter
      text: clock.date.toLocaleDateString(root.locale, "dddd d MMMM").toUpperCase()
      color: Commons.Color.lock.placeholder
      font.pixelSize: Math.round(18 * root.s)
      font.letterSpacing: 6
    }
    Label {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: !root.primary && !!root.weather
      text: root.weather ? root.weather.glyph + "  " + root.weather.temp + "° " + root.weather.label : ""
      color: Commons.Color.lock.placeholder
      font.pixelSize: Math.round(15 * root.s)
    }
  }

  Row {
    visible: root.primary && !!root.info
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Math.round(48 * root.s)
    spacing: Math.round(16 * root.s)

    Card {
      visible: !!root.weather
      Row {
        anchors.fill: parent
        anchors.leftMargin: Math.round(20 * root.s)
        spacing: Math.round(16 * root.s)
        Label {
          anchors.verticalCenter: parent.verticalCenter
          text: root.weather ? root.weather.glyph : ""
          font.pixelSize: Math.round(40 * root.s)
        }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: 4
          Row {
            spacing: Math.round(10 * root.s)
            Label { id: tempLabel; text: root.weather ? root.weather.temp + "°" : ""; font.pixelSize: Math.round(30 * root.s); font.weight: Font.Medium }
            Label { anchors.baseline: tempLabel.baseline; text: root.weather ? root.weather.label + " · feels " + root.weather.feels + "°" : ""; font.pixelSize: Math.round(14 * root.s) }
          }
          Label {
            width: Math.round(240 * root.s)
            text: root.weather ? [root.info.location ? root.info.location.name : "", "↑" + root.weather.high + "° ↓" + root.weather.low + "°", root.weather.wind + " km/h"].filter(Boolean).join(" · ") : ""
            color: Commons.Color.lock.placeholder
            font.pixelSize: Math.round(12 * root.s)
          }
        }
      }
    }

    Card {
      visible: !!(root.info && root.info.hasMedia)
      Row {
        anchors.fill: parent
        anchors.leftMargin: Math.round(16 * root.s)
        spacing: Math.round(14 * root.s)
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.round(52 * root.s)
          height: width
          radius: 6
          color: Commons.Color.lock.selection
          clip: true
          Label {
            anchors.centerIn: parent
            visible: art.status !== Image.Ready
            text: String.fromCodePoint(0xF075A)
            font.pixelSize: Math.round(22 * root.s)
          }
          Image {
            id: art
            anchors.fill: parent
            source: root.info ? root.info.artUrl : ""
            sourceSize.width: width
            sourceSize.height: height
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
          }
        }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.round(230 * root.s)
          spacing: 3
          Label { width: parent.width; text: root.info ? root.info.title : ""; font.pixelSize: Math.round(14 * root.s); font.weight: Font.Medium }
          Label {
            width: parent.width
            text: root.info ? [root.info.artist, root.info.player].filter(Boolean).join(" · ") : ""
            color: Commons.Color.lock.placeholder
            font.pixelSize: Math.round(12 * root.s)
          }
          Label {
            visible: !!(root.info && !root.info.playing)
            text: "Paused"
            color: Commons.Color.lock.placeholder
            font.pixelSize: Math.round(12 * root.s)
            font.italic: true
          }
        }
      }
    }

    Card {
      Grid {
        anchors.centerIn: parent
        columns: 2
        columnSpacing: Math.round(18 * root.s)
        rowSpacing: Math.round(8 * root.s)
        Stat {
          label: "CPU"
          value: root.info && root.info.cpuPercent >= 0 ? root.info.cpuPercent + "%" + (root.info.tempC > 0 ? " · " + root.info.tempC + "°C" : "") : "—"
        }
        Stat {
          label: "Memory"
          value: root.info && root.info.memTotalGb > 0 ? Math.round(root.info.memUsedGb) + " / " + Math.round(root.info.memTotalGb) + " GB" : "—"
        }
        Stat {
          visible: !!(root.info && root.info.hasBattery)
          label: "Battery"
          value: root.info ? root.info.batteryPercent + "% · " + root.info.batteryState : ""
        }
        Stat {
          label: "Up"
          value: root.info && root.info.uptimeSeconds > 0 ? root.info.duration(root.info.uptimeSeconds) : "—"
        }
      }
    }
  }
}
