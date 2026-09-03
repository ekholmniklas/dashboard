package com.ekholm.fyndkoll

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class RefreshResult(
    val all: List<Find>,
    val new: List<Find>,
    val seeded: Boolean,
    val error: String? = null
)

/**
 * One poll of both threads. Shared by the background worker and by pull-to-refresh
 * so notifications and the cache behave identically either way.
 */
object Refresher {

    suspend fun refresh(context: Context, notify: Boolean): RefreshResult =
        withContext(Dispatchers.IO) {
            val seeded = Store.isFirstRun(context)
            val scraped = ArrayList<Find>()
            val fresh = ArrayList<Find>()
            val failures = ArrayList<String>()

            for (thread in Threads.ALL) {
                val lastSeen = Store.lastSeen(context, thread.id)
                try {
                    val posts = Scraper.fetchThread(thread, lastSeen)
                    if (posts.isEmpty()) continue
                    scraped += posts

                    if (lastSeen > 0L) {
                        fresh += posts.filter { it.postId > lastSeen }
                    }

                    val highest = posts.maxOf { it.postId }
                    if (highest > lastSeen) {
                        Store.setLastSeen(context, thread.id, highest)
                    }
                } catch (e: Exception) {
                    failures += "${thread.label}: ${e.javaClass.simpleName}"
                }
            }

            if (scraped.isEmpty() && failures.isNotEmpty()) {
                val message = failures.joinToString(", ")
                Store.setLastError(context, message)
                return@withContext RefreshResult(
                    all = Store.cached(context),
                    new = emptyList(),
                    seeded = false,
                    error = message
                )
            }

            val merged = Store.mergeIntoCache(context, scraped)
            Store.setLastCheck(context, System.currentTimeMillis())
            Store.setLastError(context, failures.joinToString(", ").takeIf { it.isNotBlank() })

            if (notify) {
                if (seeded) {
                    // Do not fire ~35 notifications for posts that were already there.
                    Notifier.notifyStatus(
                        context,
                        context.getString(R.string.seeded_title),
                        context.getString(R.string.seeded_body, merged.size)
                    )
                } else if (fresh.isNotEmpty()) {
                    Notifier.notifyFinds(context, fresh)
                }
            }

            RefreshResult(
                all = merged,
                new = if (seeded) emptyList() else fresh,
                seeded = seeded,
                error = failures.joinToString(", ").takeIf { it.isNotBlank() }
            )
        }
}
