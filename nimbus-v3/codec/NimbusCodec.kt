// Nimbus SMS format NB1 for Android code that sits outside Flutter, such as an Android-phone gateway.
// Mirrors nimbus-codec.js line for line.
//
//   NB1 <type> <town> <field> ... T<hhmm> [/<notice>] K<signature>
//   NB1~P~<town>~<pin>...~T<hhmm>~K<signature> for multipart-safe pin snapshots
//
// The K signature is a demo checksum. A real gateway signs with HMAC-SHA256.
// Check it against test_vectors.json before relying on it.
package nimbus

import kotlin.math.abs
import kotlin.math.floor

object NimbusCodec {
    const val VERSION = "NB1"
    const val MAX_SMS = 160

    /** h = h * 31 + UTF-16 char, kept to 32 bits; returns the low 16 bits as 4 hex digits. */
    fun signature(text: String): String {
        var h = 0L
        for (ch in text) h = (h * 31 + ch.code) and 0xFFFFFFFFL
        return "%04X".format(h and 0xFFFFL)
    }

    /** Keeps a notice in the plain SMS character set so one reply stays one SMS. */
    fun cleanNotice(text: String): String = text
        .replace(Regex("[‘’]"), "'")
        .replace(Regex("[“”]"), "\"")
        .replace(Regex("[–—]"), "-")
        .replace(Regex("[^\\x20-\\x7E]"), "")
        .replace(Regex("\\s+"), " ")
        .trim()

    fun encode(type: String, townCode: String, fields: List<String>, time: String, notice: String = ""): String {
        var body = (listOf(VERSION, type, townCode) + fields + "T$time").joinToString(" ")
        if (notice.isNotEmpty()) body += " /$notice"
        return "$body K${signature(body)}"
    }

    data class MapPin(
        val category: String,
        val label: String,
        val latitude: Double,
        val longitude: Double,
        val status: String,
        val intensity: Int,
    )

    fun encodePins(townCode: String, pins: List<MapPin>, time: String): String {
        val categoryCodes = mapOf("flood" to "F", "evacuation" to "E", "road" to "R")
        val statusCodes = mapOf("F" to setOf("F", "W", "C"), "E" to setOf("O", "F", "X"), "R" to setOf("O", "L", "X"))
        val fields = pins.map { pin ->
            val category = categoryCodes[pin.category]
                ?: throw IllegalArgumentException("Invalid map pin category: ${pin.category}")
            if (pin.status !in statusCodes.getValue(category) ||
                pin.intensity !in 0..100 ||
                !pin.latitude.isFinite() || !pin.longitude.isFinite() ||
                pin.latitude !in -90.0..90.0 || pin.longitude !in -180.0..180.0
            ) {
                throw IllegalArgumentException("Invalid map pin: ${pin.label}")
            }
            val label = cleanNotice(pin.label).replace("|", " ").trim().replace(Regex("\\s+"), "_")
            if (label.isEmpty()) throw IllegalArgumentException("Map pin labels cannot be empty")
            fun coord(value: Double): Int {
                val rounded = floor(abs(value) * 100000 + 0.5).toInt()
                return if (value < 0) -rounded else rounded
            }
            "${category}|${pin.status}|${pin.intensity}|${coord(pin.latitude)}|${coord(pin.longitude)}|$label"
        }
        val body = (listOf(VERSION, "P", townCode) + fields + "T$time").joinToString("~")
        return "$body~K${signature(body)}"
    }

    data class Storm(val warning: String, val rain: Int, val gusts: Int, val evacSite: Int, val evacStatus: String, val classes: Int)

    data class Item(
        val index: Int,
        val level: String? = null,
        val now: String? = null,
        val status: String? = null,
        val percentFull: Int? = null,
        val customName: String? = null,
    )

    data class Reply(
        val version: String,
        val type: String,
        val townCode: String,
        val time: String,
        val notice: String,
        val valid: Boolean,
        val storm: Storm? = null,
        val items: List<Item> = emptyList(),
        val pins: List<MapPin> = emptyList(),
    )

    private val FLOOD = Regex("^A(\\d+)([HML])([FWC])(?::(\\S+))?$")
    private val EVAC = Regex("^S(\\d+)([OFX])(\\d+)$")
    private val ROAD = Regex("^R(\\d+)([OLX])(?::(\\S+))?$")
    private val PIN = Regex("^([FER])\\|([A-Z])\\|(\\d{1,3})\\|(-?\\d{1,8})\\|(-?\\d{1,9})\\|([A-Za-z0-9_.'-]+)$")

    private fun custom(group: String): String? = group.ifEmpty { null }?.replace('_', ' ')

    private fun parseField(type: String, part: String): Item? = when (type) {
        "F" -> FLOOD.matchEntire(part)?.groupValues?.let { Item(it[1].toInt(), level = it[2], now = it[3], customName = custom(it[4])) }
        "E" -> EVAC.matchEntire(part)?.groupValues?.let { Item(it[1].toInt(), status = it[2], percentFull = it[3].toInt()) }
        "R" -> ROAD.matchEntire(part)?.groupValues?.let { Item(it[1].toInt(), status = it[2], customName = custom(it[3])) }
        else -> null
    }

    private fun parsePin(part: String): MapPin? {
        val match = PIN.matchEntire(part) ?: return null
        val categoryCode = match.groupValues[1]
        val status = match.groupValues[2]
        val intensity = match.groupValues[3].toInt()
        val latitude = match.groupValues[4].toInt()
        val longitude = match.groupValues[5].toInt()
        val validStatus = when (categoryCode) {
            "F" -> status in setOf("F", "W", "C")
            "E" -> status in setOf("O", "F", "X")
            else -> status in setOf("O", "L", "X")
        }
        if (!validStatus || intensity > 100 || abs(latitude) > 9000000 || abs(longitude) > 18000000) return null
        val category = mapOf("F" to "flood", "E" to "evacuation", "R" to "road").getValue(categoryCode)
        return MapPin(category, match.groupValues[6].replace('_', ' '), latitude / 100000.0, longitude / 100000.0, status, intensity)
    }

    /** Returns null for anything that isn't an NB1 reply, so a stray text never crashes the app. */
    fun decode(sms: String): Reply? {
        val compactPins = sms.startsWith("$VERSION~P~")
        val marker = if (compactPins) "~K" else " K"
        val k = sms.lastIndexOf(marker)
        if (k < 0 || !sms.startsWith("$VERSION${if (compactPins) "~" else " "}")) return null
        val body = sms.substring(0, k)
        val n = body.indexOf(" /")
        val parts = (if (n >= 0) body.substring(0, n) else body).split(if (compactPins) "~" else " ")
        if (parts.size < 4) return null
        val type = parts[1]
        val items = parts.subList(3, parts.size - 1)
        val timePart = parts.last()
        if (!Regex("^T\\d{4}$").matches(timePart)) return null
        val base = Reply(
            parts[0], type, parts[2], timePart.substring(1),
            if (n >= 0) body.substring(n + 2) else "", signature(body) == sms.substring(k + marker.length),
        )
        if (type == "Q") {
            val f = items.associate { it.substring(0, 1) to it.substring(1) }
            val e = Regex("^(\\d+)([OFX]?)$").matchEntire(f["E"] ?: "0")?.groupValues
            val storm = Storm(
                f["W"] ?: "", f["R"]?.toIntOrNull() ?: 0, f["G"]?.toIntOrNull() ?: 0,
                e?.get(1)?.toInt() ?: 0, e?.get(2) ?: "", f["C"]?.toIntOrNull() ?: 0,
            )
            return base.copy(storm = storm)
        }
        if (type == "P") {
            val parsedPins = items.map { parsePin(it) ?: return null }
            return base.copy(pins = parsedPins)
        }
        val parsed = items.map { parseField(type, it) ?: return null }
        return base.copy(items = parsed)
    }
}
