.pragma library

// Shared numbers and helpers for the Spectrum widget.
// Levels arrive from bin/omarchy-spectrum as band power in dBFS.

var F_MIN = 20
var F_MAX = 20000
var POP_BANDS = 60
var BAR_BANDS = 10

var DB_TOP = 0
var DB_BOTTOM = -84
var DB_TICKS = [0, -12, -24, -36, -48, -60, -72]
var BAR_DB_TOP = -6
var BAR_DB_BOTTOM = -66

var HZ_TICKS = [
  { hz: 50, label: "50" }, { hz: 100, label: "100" }, { hz: 200, label: "200" },
  { hz: 500, label: "500" }, { hz: 1000, label: "1k" }, { hz: 2000, label: "2k" },
  { hz: 5000, label: "5k" }, { hz: 10000, label: "10k" }
]

var REGIONS = [
  { key: "lows",  name: "LOWS",  lo: 20,   hi: 250,   range: "20–250 Hz" },
  { key: "mids",  name: "MIDS",  lo: 250,  hi: 4000,  range: "250 Hz–4 kHz" },
  { key: "highs", name: "HIGHS", lo: 4000, hi: 20000, range: "4–20 kHz" }
]

// 0..1 horizontal position of a frequency on the 20 Hz – 20 kHz log axis.
function xFrac(hz) {
  return Math.log(hz / F_MIN) / Math.log(F_MAX / F_MIN)
}

// Centre frequency of popup band i (geometric centre of its edges).
function popCentre(i) {
  return F_MIN * Math.pow(F_MAX / F_MIN, (i + 0.5) / POP_BANDS)
}

// Octave centre for bar band i (31.25 Hz .. 16 kHz).
function barCentre(i) {
  return 31.25 * Math.pow(2, i)
}

function regionIndex(hz) {
  return hz < 250 ? 0 : (hz < 4000 ? 1 : 2)
}

function norm(db, top, bottom) {
  var v = (db - bottom) / (top - bottom)
  return v < 0 ? 0 : (v > 1 ? 1 : v)
}

function formatDb(db) {
  if (db <= -99.5) return "—"
  return (db >= 0 ? "+" : "−") + Math.abs(db).toFixed(1)
}

function formatDelta(db) {
  if (!isFinite(db)) return ""
  var r = Math.round(db * 10) / 10
  return (r >= 0 ? "+" : "−") + Math.abs(r).toFixed(1) + " dB"
}

// The default output is "on the EQ chain" when it is either configured sink.
function inChain(name, musicSink, speakerSink) {
  return name !== "" && (name === musicSink || name === speakerSink)
}

// Parse "key = \"#rrggbb\"" lines from the theme's colors.toml.
function parsePalette(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})["']?\s*$/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

var SKIP = /background|selection|border|tab|dark_foreground|color0$|color8$/

// Pick three distinguishable region tints from the theme palette: the most
// saturated warm colour for lows, cool colour for highs, and something in
// between (or the foreground) for mids. Monochrome themes fall back to
// foreground / accent lightness steps so the regions still read apart.
function pickTints(palette, fg, accent) {
  var warm = null, cool = null, mid = null
  for (var key in palette) {
    if (SKIP.test(key)) continue
    var c = Qt.color(palette[key])
    var h = c.hslHue, s = c.hslSaturation, l = c.hslLightness
    if (h < 0 || s < 0.35 || l < 0.35 || l > 0.85) continue
    var deg = h * 360
    var cand = { color: c, s: s, deg: deg }
    if ((deg >= 330 || deg < 60) && (!warm || s > warm.s)) warm = cand
    else if (deg >= 160 && deg < 290 && (!cool || s > cool.s)) cool = cand
    else if (deg >= 60 && deg < 160 && (!mid || s > mid.s)) mid = cand
  }
  var lows = warm ? warm.color : Qt.lighter(accent, 1.35)
  var highs = cool ? cool.color : Qt.lighter(accent, 1.2)
  var mids = mid ? mid.color : fg
  if (!warm && !cool) {
    lows = fg
    mids = Qt.lighter(accent, 1.3)
    highs = accent
  }
  return [lows, mids, highs]
}
