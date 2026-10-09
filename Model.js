// Helpers for the joseluis.weather plugin. Data comes from Open-Meteo; the
// weather icon glyphs in iconForCode are the same ones Omarchy's own weather
// panel uses, so both widgets render identical symbols. Nothing here reads
// Omarchy's files at runtime.

// weather.json holds {"name": ..., "latitude": ..., "longitude": ...} (see
// omarchy-weather-location, which owns the format). Missing, blank, or
// unparseable means no location is configured yet.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude)
    return {
      name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    }
  } catch (e) {
    return unset
  }
}

// Open-Meteo geocoding response → suggestion rows for the location picker.
function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []

    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(r.name),
        description: region,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Best guess for a name-only location: the geocoder's first hit.
function firstGeocodingResult(raw) {
  var results = parseGeocodingResults(raw)
  return results.length > 0 ? results[0] : null
}

function locationCommit(text, suggestions, selectedIndex) {
  var name = String(text || "").replace(/^\s+|\s+$/g, "")
  if (name === "") return { name: "", latitude: null, longitude: null }

  var choices = suggestions || []
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  var suggestion = choices[index]
  if (suggestion) return suggestion

  return { name: name, latitude: null, longitude: null }
}

function isFutureForecastDate(dateString, todayString) {
  if (!dateString) return false
  return String(dateString).slice(0, 10) > String(todayString || "")
}

function roundedTemp(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : String(Math.round(n))
}

function celsiusToFahrenheit(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : (n * 9 / 5) + 32
}

// Current temperature as shown beside the icon: rounded, unit converted.
function displayTemp(value, useImperial) {
  var n = useImperial ? celsiusToFahrenheit(value) : value
  return roundedTemp(n)
}

function normalizedUnit(value) {
  return String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase()
}

function localeUsesImperial(localeName) {
  var name = String(localeName || "").replace(".", "_")
  return /^en[_-]US($|[_.-])/.test(name) || /^en[_-]LR($|[_.-])/.test(name) || /^my($|[_.-])/.test(name)
}

function shouldUseImperial(unitOverride, localeName) {
  var unit = normalizedUnit(unitOverride)
  if (unit === "imperial") return true
  if (unit === "metric") return false
  // Unset/blank defaults to metric (matches Open-Meteo's native units) rather
  // than following the shell locale, which is often en_US on non-US systems.
  return false
}

function dayName(dateString, formatter) {
  if (!dateString) return ""
  var d = new Date(dateString + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  if (formatter) return formatter(d)
  return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d.getDay()]
}

// Next `count` forecast days from an Open-Meteo response, today excluded.
function forecastDays(report, todayString, count) {
  var daily = report && report.daily ? report.daily : null
  if (!daily || !daily.time) return []

  var out = []
  for (var i = 0; i < daily.time.length && out.length < count; ++i) {
    var date = daily.time[i]
    if (!isFutureForecastDate(date, todayString)) continue
    out.push({
      date: date,
      weatherCode: daily.weather_code ? daily.weather_code[i] : null,
      maxC: roundedTemp(daily.temperature_2m_max ? daily.temperature_2m_max[i] : ""),
      minC: roundedTemp(daily.temperature_2m_min ? daily.temperature_2m_min[i] : "")
    })
  }
  return out
}

function bareTemp(day, kind, useImperial) {
  if (!day) return ""
  var raw = kind === "max" ? day.maxC : day.minC
  if (raw === "") return ""
  var n = parseFloat(raw)
  if (isNaN(n)) return ""
  if (useImperial) n = n * 9 / 5 + 32
  return Math.round(n) + "°"
}

function dayIcon(day) {
  if (!day) return ""
  return iconForOpenMeteoCode(day.weatherCode, false)
}

function currentIcon(report) {
  var current = report && report.current ? report.current : null
  if (!current || current.weather_code === undefined || current.weather_code === null) return ""
  return iconForOpenMeteoCode(current.weather_code, Number(current.is_day) === 0)
}

function iconForOpenMeteoCode(code, night) {
  var c = parseInt(String(code || "0"), 10)
  if (c === 0) return iconForCode(113, night)
  if (c === 1 || c === 2) return iconForCode(116, night)
  if (c === 3) return iconForCode(119, night)
  if (c === 45 || c === 48) return iconForCode(143, night)
  if (c === 51 || c === 53 || c === 55 || c === 56 || c === 57 || c === 61) return iconForCode(266, night)
  if (c === 63 || c === 65 || c === 66 || c === 67 || c === 80 || c === 81 || c === 82) return iconForCode(308, night)
  if (c === 71 || c === 73 || c === 75 || c === 77 || c === 85 || c === 86) return iconForCode(338, night)
  if (c === 95 || c === 96 || c === 99) return iconForCode(389, night)
  return iconForCode(119, night)
}

function iconForCode(code, night) {
  var c = parseInt(String(code || "0"), 10)
  switch (c) {
    case 113: return night ? "" : ""
    case 116: return night ? "" : ""
    case 119: case 122: return ""
    case 143: case 248: case 260: return night ? "\ue346" : "\ue313"
    case 176: case 263: case 353: return night ? "" : ""
    case 179: case 227: case 230: case 323: case 326: case 368: return night ? "" : ""
    case 182: case 185: case 281: case 284: case 311: case 314:
    case 317: case 320: case 350: case 362: case 365: case 374: case 377: return ""
    case 200: case 386: case 389: case 392: case 395: return ""
    case 266: case 293: case 296: case 299: case 302: case 305: case 308: case 356: case 359: return ""
    case 329: case 332: case 335: case 338: case 371: return ""
    default: return ""
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseLocationFile: parseLocationFile,
    parseGeocodingResults: parseGeocodingResults,
    firstGeocodingResult: firstGeocodingResult,
    locationCommit: locationCommit,
    isFutureForecastDate: isFutureForecastDate,
    roundedTemp: roundedTemp,
    celsiusToFahrenheit: celsiusToFahrenheit,
    displayTemp: displayTemp,
    normalizedUnit: normalizedUnit,
    localeUsesImperial: localeUsesImperial,
    shouldUseImperial: shouldUseImperial,
    dayName: dayName,
    forecastDays: forecastDays,
    bareTemp: bareTemp,
    dayIcon: dayIcon,
    currentIcon: currentIcon,
    iconForOpenMeteoCode: iconForOpenMeteoCode,
    iconForCode: iconForCode
  }
}
