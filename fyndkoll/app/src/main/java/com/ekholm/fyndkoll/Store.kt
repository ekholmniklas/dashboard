package com.ekholm.fyndkoll

import android.content.Context

/** Everything the app remembers between runs. */
object Store {

    private const val PREFS = "fyndkoll"
    private const val KEY_LAST_SEEN = "last_seen_"
    private const val KEY_CACHE = "cache"
    private const val KEY_INTERVAL = "interval_minutes"
    private const val KEY_LAST_CHECK = "last_check"
    private const val KEY_LAST_ERROR = "last_error"

    const val DEFAULT_INTERVAL_MINUTES = 30
    private const val MAX_CACHE = 200

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Highest post id already seen in a thread. Post ids increase monotonically,
     * so "> lastSeen" is a reliable "new since last check".
     */
    fun lastSeen(context: Context, threadId: Long): Long =
        prefs(context).getLong(KEY_LAST_SEEN + threadId, 0L)

    fun setLastSeen(context: Context, threadId: Long, postId: Long) {
        prefs(context).edit().putLong(KEY_LAST_SEEN + threadId, postId).apply()
    }

    /** True until the first successful poll, so the first run does not fire 30 notifications. */
    fun isFirstRun(context: Context): Boolean =
        Threads.ALL.all { lastSeen(context, it.id) == 0L }

    fun intervalMinutes(context: Context): Int =
        prefs(context).getInt(KEY_INTERVAL, DEFAULT_INTERVAL_MINUTES)

    fun setIntervalMinutes(context: Context, minutes: Int) {
        prefs(context).edit().putInt(KEY_INTERVAL, minutes).apply()
    }

    fun lastCheck(context: Context): Long = prefs(context).getLong(KEY_LAST_CHECK, 0L)

    fun setLastCheck(context: Context, millis: Long) {
        prefs(context).edit().putLong(KEY_LAST_CHECK, millis).apply()
    }

    fun lastError(context: Context): String? =
        prefs(context).getString(KEY_LAST_ERROR, null)?.takeIf { it.isNotBlank() }

    fun setLastError(context: Context, message: String?) {
        prefs(context).edit().putString(KEY_LAST_ERROR, message ?: "").apply()
    }

    fun cached(context: Context): List<Find> =
        Find.listFromJson(prefs(context).getString(KEY_CACHE, null))

    /** Merge freshly scraped posts into the cache, newest first, de-duplicated by post id. */
    fun mergeIntoCache(context: Context, incoming: List<Find>): List<Find> {
        val byId = LinkedHashMap<Long, Find>()
        (incoming + cached(context)).forEach { byId[it.postId] = it }
        val merged = byId.values
            .sortedByDescending { it.postId }
            .take(MAX_CACHE)
        prefs(context).edit().putString(KEY_CACHE, Find.listToJson(merged)).apply()
        return merged
    }
}
