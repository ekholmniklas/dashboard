package com.ekholm.fyndkoll

import org.jsoup.Jsoup

/** Fetches and parses the fynd threads. */
object Scraper {

    private const val USER_AGENT =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/126.0.0.0 Mobile Safari/537.36 Fyndkoll/1.0"

    private const val TIMEOUT_MS = 20_000

    /** How far back to walk if a whole page of posts arrived between two polls. */
    private const val MAX_EXTRA_PAGES = 3

    /**
     * Posts from the end of [thread]. Normally one request to /sista-sidan is enough
     * (a page holds ~29 posts). If every post on that page is newer than [lastSeen]
     * we may have missed some, so walk back a few pages.
     */
    fun fetchThread(thread: ForumThread, lastSeen: Long): List<Find> {
        val response = Jsoup.connect(thread.lastPageUrl)
            .userAgent(USER_AGENT)
            .header("Accept-Language", "sv-SE,sv;q=0.9,en;q=0.8")
            .timeout(TIMEOUT_MS)
            .followRedirects(true)
            .ignoreHttpErrors(false)
            .execute()

        val collected = ArrayList<Find>()
        collected += FyndParser.parsePage(response.body(), thread)

        // /sista-sidan redirects to "?p=<last>", which tells us where we are.
        var page = FyndParser.pageNumberOf(response.url().toString())
        var extra = 0
        while (
            lastSeen > 0L &&
            page != null && page > 1 &&
            extra < MAX_EXTRA_PAGES &&
            collected.isNotEmpty() &&
            collected.minOf { it.postId } > lastSeen
        ) {
            page -= 1
            extra += 1
            val html = Jsoup.connect(thread.pageUrl(page))
                .userAgent(USER_AGENT)
                .header("Accept-Language", "sv-SE,sv;q=0.9,en;q=0.8")
                .timeout(TIMEOUT_MS)
                .followRedirects(true)
                .execute()
                .body()
            val older = FyndParser.parsePage(html, thread)
            if (older.isEmpty()) break
            collected += older
        }

        return collected.distinctBy { it.postId }.sortedBy { it.postId }
    }
}
