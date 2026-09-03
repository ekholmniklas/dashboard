package com.ekholm.fyndkoll

import org.json.JSONArray
import org.json.JSONObject

/** One of the SweClockers "fynd" threads we watch. */
data class ForumThread(
    val id: Long,
    val slug: String,
    val label: String
) {
    /** SweClockers redirects this to the highest page number, no login needed. */
    val lastPageUrl: String get() = "$BASE/forum/trad/$slug/sista-sidan"

    fun pageUrl(page: Int): String = "$BASE/forum/trad/$slug?p=$page"

    companion object {
        const val BASE = "https://www.sweclockers.com"
    }
}

object Threads {
    val DAGENS = ForumThread(
        id = 999559,
        slug = "999559-dagens-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst",
        label = "Dagens fynd"
    )
    val OVRIGA = ForumThread(
        id = 1465406,
        slug = "1465406-ovriga-fynd-bara-tips-ingen-diskussion-las-forsta-inlagget-forst",
        label = "Övriga fynd"
    )
    val ALL = listOf(DAGENS, OVRIGA)

    fun byId(id: Long): ForumThread? = ALL.firstOrNull { it.id == id }
}

/**
 * A single post, parsed into the fields the "fynd" template uses
 * (Produkt / Länk / Kategori / Prisjakt / Pris) plus whatever free text
 * the poster added underneath, which is often where the real detail is
 * ("Bara 9h kvar", "Power har samma för 124 kr + frakt").
 */
data class Find(
    val postId: Long,
    val threadId: Long,
    val threadLabel: String,
    val author: String,
    val createdAt: Long,
    val title: String,
    val price: String?,
    val category: String?,
    val store: String?,
    val dealLink: String?,
    val note: String,
    val isStructured: Boolean
) {
    val permalink: String get() = "${ForumThread.BASE}/forum/post/$postId"

    fun toJson(): JSONObject = JSONObject().apply {
        put("postId", postId)
        put("threadId", threadId)
        put("threadLabel", threadLabel)
        put("author", author)
        put("createdAt", createdAt)
        put("title", title)
        put("price", price ?: JSONObject.NULL)
        put("category", category ?: JSONObject.NULL)
        put("store", store ?: JSONObject.NULL)
        put("dealLink", dealLink ?: JSONObject.NULL)
        put("note", note)
        put("isStructured", isStructured)
    }

    companion object {
        fun fromJson(o: JSONObject) = Find(
            postId = o.optLong("postId"),
            threadId = o.optLong("threadId"),
            threadLabel = o.optString("threadLabel"),
            author = o.optString("author"),
            createdAt = o.optLong("createdAt"),
            title = o.optString("title"),
            price = o.optStringOrNull("price"),
            category = o.optStringOrNull("category"),
            store = o.optStringOrNull("store"),
            dealLink = o.optStringOrNull("dealLink"),
            note = o.optString("note"),
            isStructured = o.optBoolean("isStructured")
        )

        fun listToJson(items: List<Find>): String =
            JSONArray().apply { items.forEach { put(it.toJson()) } }.toString()

        fun listFromJson(raw: String?): List<Find> {
            if (raw.isNullOrBlank()) return emptyList()
            return try {
                val arr = JSONArray(raw)
                (0 until arr.length()).mapNotNull { i ->
                    arr.optJSONObject(i)?.let { fromJson(it) }
                }
            } catch (_: Exception) {
                emptyList()
            }
        }
    }
}

private fun JSONObject.optStringOrNull(key: String): String? =
    if (isNull(key)) null else optString(key).takeIf { it.isNotBlank() }
