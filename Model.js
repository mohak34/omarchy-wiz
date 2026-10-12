.pragma library

// WiZ scene ids from the bulb's local API. The panel offers the ones that
// suit a room light; the bulb supports more (see pywizlight's scenes.py).
var scenes = [
  { id: 11, label: "Warm" },
  { id: 12, label: "Daylight" },
  { id: 13, label: "Cool" },
  { id: 14, label: "Night" },
  { id: 15, label: "Focus" },
  { id: 16, label: "Relax" },
  { id: 6, label: "Cozy" },
  { id: 18, label: "TV" },
  { id: 29, label: "Candle" },
  { id: 5, label: "Fireplace" },
  { id: 3, label: "Sunset" },
  { id: 1, label: "Ocean" },
  { id: 7, label: "Forest" },
  { id: 2, label: "Romance" },
  { id: 4, label: "Party" },
  { id: 26, label: "Club" }
]

var minTemp = 2200
var maxTemp = 6500

function sceneLabel(id) {
  for (var i = 0; i < scenes.length; i++) if (scenes[i].id === id) return scenes[i].label
  return "Scene " + id
}

function glyph(on) {
  // Nerd Font md-lightbulb / md-lightbulb-outline.
  return String.fromCodePoint(on ? 0xF0335 : 0xF0336)
}

function copy(obj) {
  var out = {}
  for (var k in obj) out[k] = obj[k]
  return out
}

// Colour, white and scene are exclusive bulb modes, so a newer one replaces
// whatever an older queued command asked for.
function merge(queued, params) {
  var out = copy(queued || {})
  if (params.r !== undefined || params.temp !== undefined || params.sceneId !== undefined) {
    delete out.r; delete out.g; delete out.b; delete out.temp; delete out.sceneId
  }
  for (var k in params) out[k] = params[k]
  return out
}

// The bulb state with params applied, so the panel moves before the bulb
// answers. The helper's reply replaces it with the real state.
function apply(bulb, params) {
  var s = copy(bulb)
  if (params.state !== undefined) s.on = params.state
  if (params.dimming !== undefined) s.dimming = params.dimming
  if (params.temp !== undefined) { s.temp = params.temp; s.color = false; s.scene = 0 }
  if (params.r !== undefined) { s.r = params.r; s.g = params.g; s.b = params.b; s.color = true; s.temp = 0; s.scene = 0 }
  if (params.sceneId !== undefined) { s.scene = params.sceneId; s.color = false }
  return s
}

// "WARM WHITE 2700K · 60%" style status line.
function status(bulb, error) {
  if (!bulb) return error || "Looking for the bulb"
  if (!bulb.on) return "Off"
  var mode = bulb.scene > 0 ? sceneLabel(bulb.scene)
    : bulb.color ? "Color"
    : bulb.temp + "K"
  return mode + " · " + bulb.dimming + "%"
}

// Approximate light colour for a white temperature, used to tint the hero icon.
function tempColor(temp) {
  var t = Math.max(0, Math.min(1, (temp - minTemp) / (maxTemp - minTemp)))
  var warm = [255, 170, 90]
  var cool = [215, 228, 255]
  var c = []
  for (var i = 0; i < 3; i++) c.push(Math.round(warm[i] + (cool[i] - warm[i]) * t))
  return "#" + c.map(function(v) { return (v < 16 ? "0" : "") + v.toString(16) }).join("")
}
