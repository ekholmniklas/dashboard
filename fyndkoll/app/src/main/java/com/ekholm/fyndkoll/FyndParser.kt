package com.ekholm.fyndkoll

import org.json.JSONObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode
import org.jsoup.select.NodeTraversor
import org.jsoup.select.NodeVisitor

/**
 * Turns a SweClockers thread page into [Find]s.
 *
 * Page structure this relies on (verified against both fynd threads):
 *   div.forum-post[data-post={"postid":..,"createTime":..,"isVisible":..}]
 *     time[datetime]
 *     span[itemprop=name]                <- author
 *     div.message[itemprop=text]         <- the post body
 *
 * The body is read as rendered text rather than HTML, because the field labels
 * appear both plain ("Produkt: X") and bold ("<strong>Produkt</strong>: X").
 */
object FyndParser {

    /** Labels that belong to the fynd template; everything else stays as free text. */
    private val TEMPLATE_LABELS = setOf(
        "produkt", "produkter", "pris", "priser", "ord pris", "ordpris",
        "kategori", "länk", "lank", "link", "url",
        "prisjakt", "pricerunner", "pricrunner", "prisrunner",
        "butik", "handlare", "webbutik", "säljare"
    )

    /** Never a shop: screenshots, video and links back into the forum. */
    private val JUNK_HOSTS = listOf(
        "sweclockers.com", "youtube.com", "youtu.be",
        "imgur.com", "ibb.co", "postimg.", "prnt.sc"
    )

    /** Useful, but only as a fallback - the template lists these under "Prisjakt:". */
    private val COMPARISON_HOSTS = listOf("prisjakt.nu", "pricerunner.", "pricespy.")

    private val LABEL = Regex("""^\s*([\p{L}][\p{L} /&-]{0,24})\s*:\s*(.*)$""")

    private val PRICE = Regex(
        """(\d{1,3}(?:[ \u00A0\u2009.]\d{3})+|\d+)(?:[.,](\d{1,2}))?\s*(kr|:-|sek|kronor)""",
        RegexOption.IGNORE_CASE
    )

    private val PER_MONTH = Regex("""^\s*/\s*(mån|manad|månad|mnd|mon)""", RegexOption.IGNORE_CASE)

    fun parsePage(html: String, thread: ForumThread): List<Find> {
        val doc = Jsoup.parse(html, ForumThread.BASE)
        return doc.select("div.forum-post").mapNotNull { parsePost(it, thread) }
    }

    private fun parsePost(postEl: Element, thread: ForumThread): Find? {
        var postId = 0L
        var createdAt = 0L

        val meta = postEl.attr("data-post")
        if (meta.isNotBlank()) {
            try {
                val json = JSONObject(meta)
                if (!json.optBoolean("isVisible", true)) return null
                postId = json.optLong("postid", 0L)
                createdAt = json.optLong("createTime", 0L)
            } catch (_: Exception) {
                // fall through to the DOM fallbacks below
            }
        }
        if (postId == 0L) {
            postId = postEl.id().removePrefix("post").toLongOrNull() ?: return null
        }
        if (createdAt == 0L) {
            createdAt = postEl.selectFirst("time[datetime]")
                ?.attr("datetime")
                ?.let { parseIso8601Seconds(it) } ?: 0L
        }

        val author = postEl.selectFirst("span[itemprop=name]")?.text()?.trim().orEmpty()

        val message = postEl.selectFirst("div.message") ?: return null
        val body = message.clone()
        // Signatures and quoted posts are not part of the tip.
        body.select(".signature, blockquote, .bbQuote, .quote, script, style, .controls").remove()

        val dealLink = pickDealLink(body)
        val lines = renderedLines(body)
        if (lines.isEmpty() && dealLink == null) return null

        val fields = LinkedHashMap<String, String>()
        val freeText = ArrayList<String>()

        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            val match = LABEL.matchEntire(line)
            val label = match?.groupValues?.get(1)?.trim()?.lowercase()
            if (match != null && label != null && label in TEMPLATE_LABELS) {
                var value = match.groupValues[2].trim()
                // "Produkt:" occasionally has its value on the following line.
                if (value.isEmpty() && i + 1 < lines.size && LABEL.matchEntire(lines[i + 1]) == null) {
                    value = lines[i + 1].trim()
                    i++
                }
                if (value.isNotEmpty() && !fields.containsKey(label)) {
                    fields[label] = value
                }
            } else if (line.isNotBlank()) {
                freeText.add(line)
            }
            i++
        }

        val product = firstOf(fields, "produkt", "produkter")
        val priceRaw = firstOf(fields, "pris", "priser")
        val category = firstOf(fields, "kategori")?.take(60)

        val price = priceRaw?.let { normalisePrice(it) }
            ?: normalisePrice(lines.joinToString(" "))

        val store = dealLink?.let { hostLabel(it) }
            ?: firstOf(fields, "butik", "handlare", "webbutik", "säljare")?.take(40)

        val headline = product ?: headlineFrom(freeText)
        // A post that is nothing but a pasted link reads better as the shop name
        // than as a raw URL in the notification title.
        val title = (
            headline?.takeUnless { it.startsWith("http", ignoreCase = true) }
                ?: store
                ?: "Nytt inlägg"
            ).collapseSpaces().ellipsize(90)

        // Everything the poster wrote outside the template. This is where the good
        // detail lives ("Bara 9h kvar", "Power har samma för 124 kr + frakt").
        // Truncated anchor text such as "https://www.komplett.se/product/1329..."
        // is dropped, since the real URL is kept in dealLink.
        val note = freeText
            .filterNot { it == headline }
            .filterNot { it.startsWith("http") && it.endsWith("...") }
            .joinToString("\n")
            .collapseBlankLines()
            .trim()

        return Find(
            postId = postId,
            threadId = thread.id,
            threadLabel = thread.label,
            author = author,
            createdAt = createdAt,
            title = title,
            price = price,
            category = category,
            store = store,
            dealLink = dealLink,
            note = note,
            isStructured = product != null
        )
    }

    private fun firstOf(fields: Map<String, String>, vararg keys: String): String? =
        keys.firstNotNullOfOrNull { key -> fields[key]?.takeIf { it.isNotBlank() } }

    /**
     * For posts that skip the template, the first line that reads like a headline.
     * A bare pasted URL makes a useless notification title, so prefer real prose.
     */
    private fun headlineFrom(lines: List<String>): String? =
        lines.firstOrNull { it.length > 3 && !it.startsWith("http", ignoreCase = true) }
            ?: lines.firstOrNull { it.length > 3 }

    /**
     * The shop link. The template puts "Länk:" above "Prisjakt:", so document order
     * already favours the shop; a price-comparison link is only used if there is no
     * other one. Posts that link nothing but a screenshot get no link at all, rather
     * than reporting "i.imgur.com" as the shop.
     */
    private fun pickDealLink(body: Element): String? {
        val usable = body.select("a[href]")
            .mapNotNull { el -> el.absUrl("href").takeIf { it.startsWith("http") } }
            .filterNot { href -> JUNK_HOSTS.any { href.contains(it, ignoreCase = true) } }

        return usable.firstOrNull { href ->
            COMPARISON_HOSTS.none { href.contains(it, ignoreCase = true) }
        } ?: usable.firstOrNull()
    }

    /**
     * Rendered text of the post, one entry per visual line. jsoup's text() discards
     * <br>, which is exactly what separates the template fields, so walk the tree.
     */
    private fun renderedLines(root: Element): List<String> {
        val sb = StringBuilder()
        NodeTraversor.traverse(object : NodeVisitor {
            override fun head(node: Node, depth: Int) {
                when {
                    node is TextNode -> sb.append(node.text())
                    node is Element && node.normalName() == "br" -> sb.append('\n')
                }
            }

            override fun tail(node: Node, depth: Int) {
                if (node is Element && (node.isBlock || node.normalName() == "li")) {
                    sb.append('\n')
                }
            }
        }, root)

        return sb.toString()
            .split('\n')
            .map { it.collapseSpaces() }
            .filter { it.isNotEmpty() }
    }

    /**
     * First price in the text, normalised to "7128 kr". Handles "369:-", "1999kr",
     * "1 279 kr", "120 kr (ord 177 kr)", "7128 kr. Flex-avtal 297 kr/mån" and
     * "399kr/mån".
     */
    fun normalisePrice(raw: String): String? {
        val match = PRICE.find(raw) ?: return null
        val whole = match.groupValues[1].replace(Regex("""[ \u00A0\u2009.]"""), "")
        if (whole.isEmpty() || whole.length > 9) return null
        val decimals = match.groupValues[2]
        val trailing = raw.substring(minOf(match.range.last + 1, raw.length))
        val suffix = if (PER_MONTH.containsMatchIn(trailing)) "/mån" else ""
        val number = if (decimals.isNotEmpty() && decimals.trimEnd('0').isNotEmpty()) {
            "$whole,$decimals"
        } else {
            whole
        }
        return "$number kr$suffix"
    }

    /** "https://www.komplett.se/product/..." -> "komplett.se" */
    fun hostLabel(url: String): String? {
        val host = Regex("""^https?://([^/?#]+)""", RegexOption.IGNORE_CASE)
            .find(url)?.groupValues?.get(1) ?: return null
        return host.removePrefix("www.").lowercase().takeIf { it.isNotBlank() }
    }

    /** Page number that /sista-sidan redirected to: ".../slug?p=69" -> 69. */
    fun pageNumberOf(url: String): Int? =
        Regex("""[?&]p=(\d+)""").find(url)?.groupValues?.get(1)?.toIntOrNull()

    private fun parseIso8601Seconds(value: String): Long? = try {
        // "2026-09-01T13:37:30+02:00" -> SimpleDateFormat wants "+0200"
        val fixed = value.replace(Regex("""([+-]\d{2}):(\d{2})$"""), "$1$2")
        java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", java.util.Locale.US)
            .parse(fixed)?.time?.div(1000)
    } catch (_: Exception) {
        null
    }
}

private fun String.collapseSpaces(): String =
    replace('\u00A0', ' ').replace(Regex("""[ \t]+"""), " ").trim()

/** Trim to [max] characters on a word boundary, so titles do not break mid-word. */
private fun String.ellipsize(max: Int): String {
    if (length <= max) return this
    val cut = lastIndexOf(' ', max)
    val end = if (cut > max / 2) cut else max
    return substring(0, end).trimEnd(' ', ',', '.', '-', '/') + "\u2026"
}

private fun String.collapseBlankLines(): String =
    replace(Regex("""\n{3,}"""), "\n\n")
