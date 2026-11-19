// Nimbus SMS format NB1 for Android code that sits outside Flutter, such as an Android-phone gateway.
// Mirrors nimbus-codec.js line for line.
//
//   NB1 <type> <town> <field> ... T<hhmm> [/<notice>] K<signature>
//
// The K signature is a demo checksum. A real gateway signs with HMAC-SHA256.
// Check it against test_vectors.json before relying on it.
package nimbus

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
    )

    private val FLOOD = Regex("^A(\\d+)([HML])([FWC])(?::(\\S+))?$")
    private val EVAC = Regex("^S(\\d+)([OFX])(\\d+)$")
    private val ROAD = Regex("^R(\\d+)([OLX])(?::(\\S+))?$")

    private fun custom(group: String): String? = group.ifEmpty { null }?.replace('_', ' ')

    private fun parseField(type: String, part: String): Item? = when (type) {
        "F" -> FLOOD.matchEntire(part)?.groupValues?.let { Item(it[1].toInt(), level = it[2], now = it[3], customName = custom(it[4])) }
        "E" -> EVAC.matchEntire(part)?.groupValues?.let { Item(it[1].toInt(), status = it[2], percentFull = it[3].toInt()) }
        "R" -> ROAD.matchEntire(part)?.groupValues?.let { Item(it[1].toInt(), status = it[2], customName = custom(it[3])) }
        else -> null
    }

    /** Returns null for anything that isn't an NB1 reply, so a stray text never crashes the app. */
    fun decode(sms: String): Reply? {
        val k = sms.lastIndexOf(" K")
        if (k < 0 || !sms.startsWith("$VERSION ")) return null
        val body = sms.substring(0, k)
        val n = body.indexOf(" /")
        val parts = (if (n >= 0) body.substring(0, n) else body).split(" ")
        if (parts.size < 4) return null
        val type = parts[1]
        val items = parts.subList(3, parts.size - 1)
        val timePart = parts.last()
        if (!Regex("^T\\d{4}$").matches(timePart)) return null
        val base = Reply(
            parts[0], type, parts[2], timePart.substring(1),
            if (n >= 0) body.substring(n + 2) else "", signature(body) == sms.substring(k + 2),
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
        val parsed = items.map { parseField(type, it) ?: return null }
        return base.copy(items = parsed)
    }
}
