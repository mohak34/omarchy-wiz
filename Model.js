.pragma library

// WiZ scene ids from the bulb's local API. The panel offers the ones that
// suit a room light; the bulb supports more (see pywizlight's scenes.py).
var scenes = [
  { id: 11, label: "Warm", color: "#ffb46b" },
  { id: 12, label: "Daylight", color: "#fff1dc" },
  { id: 13, label: "Cool", color: "#dbe6ff" },
  { id: 14, label: "Night", color: "#c86a2a" },
  { id: 15, label: "Focus", color: "#f4f6ff" },
  { id: 16, label: "Relax", color: "#ffc58a" },
  { id: 6, label: "Cozy", color: "#ff9a4a" },
  { id: 18, label: "TV", color: "#8aa6ff" },
  { id: 29, label: "Candle", color: "#ff9a3c" },
  { id: 5, label: "Fireplace", color: "#ff6a1f" },
  { id: 3, label: "Sunset", color: "#ff7a4a" },
  { id: 1, label: "Ocean", color: "#2f8cff" },
  { id: 7, label: "Forest", color: "#3fbf5f" },
  { id: 2, label: "Romance", color: "#ff4f8a" },
  { id: 4, label: "Party", color: "#c04bff" },
  { id: 26, label: "Club", color: "#7a3cff" }
]

var minTemp = 2200
var maxTemp = 6500

function scene(id) {
  for (var i = 0; i < scenes.length; i++) if (scenes[i].id === id) return scenes[i]
  return { id: id, label: "Scene " + id, color: "#ffb46b" }
}

function sceneLabel(id) { return scene(id).label }

function glyph(on) {
  // Nerd Font md-lightbulb / md-lightbulb-outline.
  return String.fromCodePoint(on ? 0xF0335 : 0xF0336)
}

// Nerd Font md-plus and md-close, for the preset buttons.
var addGlyph = String.fromCodePoint(0xF0415)
var removeGlyph = String.fromCodePoint(0xF0156)

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
    : bulb.color ? colorName(bulb.r, bulb.g, bulb.b)
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
  return hex(c[0], c[1], c[2])
}

function hex(r, g, b) {
  return "#" + [r, g, b].map(function(v) { return (v < 16 ? "0" : "") + v.toString(16) }).join("")
}

// Everyday name for an RGB colour: its hue bucket, "Pale" when washed out.
function colorName(r, g, b) {
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  if (max === 0) return "Color"
  var d = max - min
  if (d / max < 0.15) return "White"
  var h = d === 0 ? 0
    : max === r ? 60 * (((g - b) / d + 6) % 6)
    : max === g ? 60 * ((b - r) / d + 2)
    : 60 * ((r - g) / d + 4)
  var names = [[15, "Red"], [40, "Orange"], [65, "Yellow"], [160, "Green"], [195, "Cyan"], [255, "Blue"], [290, "Purple"], [335, "Pink"], [360, "Red"]]
  var name = "Red"
  for (var i = 0; i < names.length; i++) if (h < names[i][0]) { name = names[i][1]; break }
  return d / max < 0.5 ? "Pale " + name.toLowerCase() : name
}

// A preset is the setPilot params that recreate one look: brightness plus a
// white temperature, a colour or a scene. Saved in presets.json as a list.
function presetOf(bulb) {
  var p = { dimming: bulb.dimming }
  if (bulb.scene > 0) p.sceneId = bulb.scene
  else if (bulb.color) { p.r = bulb.r; p.g = bulb.g; p.b = bulb.b }
  else p.temp = bulb.temp
  return p
}

// Presets from presets.json, dropping anything that is not a preset.
function parsePresets(text) {
  var list = []
  try { list = JSON.parse(text) } catch (e) {}
  if (!Array.isArray(list)) return []
  return list.filter(function(p) {
    return p && typeof p.dimming === "number"
      && (typeof p.temp === "number" || typeof p.sceneId === "number" || typeof p.r === "number")
  })
}

function samePreset(a, b) {
  return a.dimming === b.dimming && a.temp === b.temp && a.sceneId === b.sceneId
    && a.r === b.r && a.g === b.g && a.b === b.b
}

// Whether the light is showing this preset right now.
function presetActive(bulb, p) {
  if (!bulb || !bulb.on || bulb.dimming !== p.dimming) return false
  if (p.sceneId !== undefined) return bulb.scene === p.sceneId
  if (bulb.scene > 0) return false
  if (p.r !== undefined) return bulb.color && bulb.r === p.r && bulb.g === p.g && bulb.b === p.b
  return !bulb.color && Math.abs(bulb.temp - p.temp) < 50
}

function presetLabel(p) {
  if (p.sceneId !== undefined) return sceneLabel(p.sceneId)
  if (p.r !== undefined) return colorName(p.r, p.g, p.b)
  return p.temp < 3000 ? "Warm white" : p.temp < 4500 ? "Neutral white" : "Cool white"
}

function presetValue(p) {
  return (p.temp !== undefined ? p.temp + "K · " : "") + p.dimming + "%"
}

function presetColor(p) {
  if (p.sceneId !== undefined) return scene(p.sceneId).color
  if (p.r !== undefined) return hex(p.r, p.g, p.b)
  return tempColor(p.temp)
}
