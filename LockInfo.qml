import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.UPower

// What the lock screen's info strip shows: weather, media and system stats.
// One instance in Service.qml shared by every screen. It only polls while
// `active` (a lit lock screen or its preview).
Item {
  id: root

  property bool active: false

  // The screen that gets the field and the info strip: a laptop's own panel,
  // else the first screen.
  readonly property string mainScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (/^(eDP|LVDS|DSI)/.test(screens[i].name)) return screens[i].name
    return screens.length > 0 ? screens[0].name : ""
  }

  // ---- weather: open-meteo, for the place set in Omarchy's weather settings

  property var location: null      // { name, lat, lon }
  property var weather: null       // { temp, feels, high, low, wind, label, glyph }
  property double weatherFetchedAt: 0

  // ---- media: straight from MPRIS, read only. The shell keeps its media
  // service from authentication plugins like this one.

  readonly property var mediaPlayer: pickPlayer(Mpris.players.values)
  readonly property bool hasMedia: mediaPlayer !== null
  readonly property bool playing: hasMedia && mediaPlayer.isPlaying
  readonly property string title: hasMedia ? mediaPlayer.trackTitle || "" : ""
  readonly property string artist: hasMedia ? mediaPlayer.trackArtist || "" : ""
  readonly property string player: hasMedia ? mediaPlayer.identity || "" : ""
  // Local art, or the https art Spotify and browsers hand out; nothing else.
  readonly property string artUrl: hasMedia && /^(file|https):\/\//.test(mediaPlayer.trackArtUrl) ? mediaPlayer.trackArtUrl : ""

  // A playing player with a track, else a paused one, else none.
  function pickPlayer(players) {
    var paused = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p.trackTitle && !p.trackArtist) continue
      if (p.isPlaying) return p
      if (!paused) paused = p
    }
    return paused
  }

  // ---- system

  property int cpuPercent: -1
  property int tempC: -1
  property real memUsedGb: 0
  property real memTotalGb: 0
  property int uptimeSeconds: 0
  property var lastCpu: null

  // Hidden on a machine without a battery.
  readonly property var battery: UPower.displayDevice
  readonly property bool hasBattery: !!(battery && battery.isPresent && battery.isLaptopBattery)
  readonly property int batteryPercent: hasBattery ? Math.round(battery.percentage * 100) : -1
  readonly property string batteryState: {
    if (!hasBattery) return ""
    if (battery.state === UPowerDeviceState.Charging) return "charging"
    if (battery.state === UPowerDeviceState.FullyCharged) return "full"
    if (battery.state === UPowerDeviceState.Discharging)
      return battery.timeToEmpty > 0 ? duration(battery.timeToEmpty) + " left" : "on battery"
    return UPower.onBattery ? "on battery" : "plugged in"
  }

  function duration(seconds) {
    var h = Math.floor(seconds / 3600)
    var m = Math.floor(seconds % 3600 / 60)
    return h > 0 ? h + "h " + m + "m" : m + "m"
  }

  // WMO weather codes, as open-meteo reports them.
  function describe(code) {
    var g = function(cp) { return String.fromCodePoint(cp) }
    if (code === 0) return { label: "Clear", glyph: g(0xF0599) }
    if (code <= 2) return { label: "Partly cloudy", glyph: g(0xF0595) }
    if (code === 3) return { label: "Overcast", glyph: g(0xF0590) }
    if (code <= 48) return { label: "Fog", glyph: g(0xF0591) }
    if (code <= 57) return { label: "Drizzle", glyph: g(0xF0597) }
    if (code <= 67) return { label: "Rain", glyph: g(0xF0597) }
    if (code <= 77) return { label: "Snow", glyph: g(0xF0598) }
    if (code <= 82) return { label: "Showers", glyph: g(0xF0596) }
    if (code <= 86) return { label: "Snow showers", glyph: g(0xF0598) }
    return { label: "Thunderstorm", glyph: g(0xF0593) }
  }

  function parseLocation(raw) {
    try {
      var o = JSON.parse(raw)
      var lat = Number(o.latitude), lon = Number(o.longitude)
      if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null
      return { name: String(o.name || "").slice(0, 40), lat: lat, lon: lon }
    } catch (e) {
      return null
    }
  }

  function refreshWeather() {
    if (!location || weatherProc.running) return
    weatherProc.url = "https://api.open-meteo.com/v1/forecast?latitude=" + location.lat + "&longitude=" + location.lon
      + "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m"
      + "&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto"
    weatherProc.running = true
  }

  function applyWeather(raw) {
    try {
      var o = JSON.parse(raw)
      var c = o.current, d = o.daily
      var values = [c.temperature_2m, c.apparent_temperature, c.wind_speed_10m, d.temperature_2m_max[0], d.temperature_2m_min[0]]
      if (!values.every(isFinite) || !isFinite(c.weather_code)) return
      var w = describe(Math.round(c.weather_code))
      w.temp = Math.round(values[0]); w.feels = Math.round(values[1]); w.wind = Math.round(values[2])
      w.high = Math.round(values[3]); w.low = Math.round(values[4])
      weather = w
      weatherFetchedAt = Date.now()
    } catch (e) {
      // Keep the last good reading.
    }
  }

  function applySystem(raw) {
    var lines = String(raw).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].trim().split(/\s+/)
      var n = Number(f[1])
      if (!isFinite(n)) continue
      if (f[0] === "cpu") {
        var idle = Number(f[2])
        if (lastCpu && n > lastCpu.total) cpuPercent = Math.round(100 * (1 - (idle - lastCpu.idle) / (n - lastCpu.total)))
        lastCpu = { total: n, idle: idle }
      } else if (f[0] === "MemTotal:") memTotalGb = n / 1048576
      else if (f[0] === "MemAvailable:") memUsedGb = memTotalGb - n / 1048576
      else if (f[0] === "up") uptimeSeconds = n
      else if (f[0] === "temp") tempC = Math.round(n / 1000)
    }
  }

  onActiveChanged: {
    if (!active) return
    systemProc.running = true
    if (Date.now() - weatherFetchedAt > 15 * 60 * 1000) refreshWeather()
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.location = root.parseLocation(text()); root.refreshWeather() }
    onLoadFailed: root.location = null
  }

  Timer {
    interval: 30 * 60 * 1000
    repeat: true
    running: root.active
    onTriggered: root.refreshWeather()
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.active
    onTriggered: if (!systemProc.running) systemProc.running = true
  }

  // Every command below has a deadline (timeout -k) and an output ceiling (head -c).
  Process {
    id: weatherProc
    property string url: ""
    command: ["bash", "-c", "timeout -k 2 10 curl -fsS --max-time 8 \"$1\" | head -c 8192", "_", url]
    stdout: StdioCollector { onStreamFinished: root.applyWeather(text) }
  }

  Process {
    id: systemProc
    command: ["bash", "-c", "timeout -k 1 3 bash -c '"
      + "read -r _ u n s i w q sq st _ < /proc/stat; echo \"cpu $((u+n+s+i+w+q+sq+st)) $((i+w))\"; "
      + "grep -E \"^Mem(Total|Available):\" /proc/meminfo; "
      + "read -r up _ < /proc/uptime; echo \"up ${up%.*}\"; "
      + "for d in /sys/class/hwmon/hwmon*; do case $(< \"$d/name\") in coretemp|k10temp|zenpower) echo \"temp $(< \"$d/temp1_input\")\"; break;; esac; done"
      + "' | head -c 4096"]
    stdout: StdioCollector { onStreamFinished: root.applySystem(text) }
  }
}
