package com.ekholm.fyndkoll

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import androidx.appcompat.content.res.AppCompatResources
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object Notifier {

    private const val CHANNEL_FINDS = "fynd"
    private const val CHANNEL_STATUS = "status"
    private const val GROUP_FINDS = "com.ekholm.fyndkoll.FINDS"

    private const val ID_SUMMARY = 1
    private const val ID_STATUS = 2
    private const val ID_FIND_BASE = 1000

    /** SweClockers orange, used as the notification accent. */
    private const val ACCENT = 0xFFF3994E.toInt()

    /** Never post more than this many individual notifications from one poll. */
    private const val MAX_INDIVIDUAL = 10

    /**
     * The single short line under the title while the notification is collapsed.
     * Price first, since that is what decides whether the tip is interesting; the
     * shop is skipped when it is already being used as the title.
     */
    private fun collapsedLine(find: Find): String =
        find.price
            ?: find.category
            ?: find.store?.takeIf { it != find.title }
            ?: find.threadLabel

    /** SimpleDateFormat is not thread-safe and this is called from the worker thread. */
    private fun formatTime(epochSeconds: Long): String =
        SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(epochSeconds * 1000))

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return

        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_FINDS,
                context.getString(R.string.channel_finds),
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = context.getString(R.string.channel_finds_desc)
                enableVibration(true)
            }
        )

        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_STATUS,
                context.getString(R.string.channel_status),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = context.getString(R.string.channel_status_desc)
            }
        )
    }

    fun notificationsBlocked(context: Context): Boolean =
        !NotificationManagerCompat.from(context).areNotificationsEnabled()

    fun notifyFinds(context: Context, finds: List<Find>) {
        if (finds.isEmpty()) return
        ensureChannels(context)
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return

        // Newest last so the newest ends up on top of the shade.
        val ordered = finds.sortedBy { it.postId }
        val shown = ordered.takeLast(MAX_INDIVIDUAL)

        shown.forEach { find ->
            manager.notify(idFor(find), buildFind(context, find))
        }

        if (ordered.size > 1) {
            manager.notify(ID_SUMMARY, buildSummary(context, ordered))
        }
    }

    /**
     * Collapsed, this shows just the product name and the price - that is all a
     * Samsung shade has room for. Expanding it reveals the category and shop, the
     * poster's own comment (often the most useful part: "Bara 9h kvar", "Power har
     * samma för 124 kr + frakt") and who posted it when.
     */
    private fun buildFind(context: Context, find: Find): android.app.Notification {
        val expanded = buildString {
            val head = listOfNotNull(find.price, find.category, find.store)
                .joinToString(" · ")
            if (head.isNotBlank()) appendLine(head)

            if (find.note.isNotBlank()) {
                if (isNotEmpty()) appendLine()
                appendLine(find.note.take(900))
            }

            if (isNotEmpty()) appendLine()
            append(
                listOfNotNull(
                    find.threadLabel,
                    find.author.takeIf { it.isNotBlank() },
                    find.createdAt.takeIf { it > 0 }?.let { formatTime(it) }
                ).joinToString(" · ")
            )
        }.trim()

        val builder = NotificationCompat.Builder(context, CHANNEL_FINDS)
            .setSmallIcon(R.drawable.ic_notification)
            .setLargeIcon(badgeBitmap(context))
            .setColor(ACCENT)
            .setSubText(context.getString(R.string.notification_subtext))
            .setContentTitle(find.title)
            .setContentText(collapsedLine(find))
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(expanded)
                    .setSummaryText(find.threadLabel)
            )
            .setContentIntent(openUrl(context, find.permalink, idFor(find)))
            .setAutoCancel(true)
            .setGroup(GROUP_FINDS)
            .setCategory(NotificationCompat.CATEGORY_PROMO)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        if (find.createdAt > 0) {
            builder.setWhen(find.createdAt * 1000).setShowWhen(true)
        }

        find.dealLink?.let { link ->
            builder.addAction(
                0,
                shopLabel(context, find),
                openUrl(context, link, idFor(find) + 500_000)
            )
        }
        builder.addAction(
            0,
            context.getString(R.string.action_open_post),
            openUrl(context, find.permalink, idFor(find) + 900_000)
        )

        return builder.build()
    }

    private fun buildSummary(context: Context, finds: List<Find>): android.app.Notification {
        val inbox = NotificationCompat.InboxStyle()
            .setBigContentTitle(
                context.resources.getQuantityString(
                    R.plurals.new_finds, finds.size, finds.size
                )
            )
        finds.asReversed().take(6).forEach { find ->
            inbox.addLine(
                listOfNotNull(find.title, find.price).joinToString(" - ")
            )
        }
        if (finds.size > 6) {
            inbox.setSummaryText(
                context.getString(R.string.and_more, finds.size - 6)
            )
        }

        return NotificationCompat.Builder(context, CHANNEL_FINDS)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ACCENT)
            .setContentTitle(
                context.resources.getQuantityString(R.plurals.new_finds, finds.size, finds.size)
            )
            .setStyle(inbox)
            .setGroup(GROUP_FINDS)
            .setGroupSummary(true)
            .setAutoCancel(true)
            .setContentIntent(openApp(context))
            .build()
    }

    /** Low-priority note used for the first run and for errors worth surfacing. */
    fun notifyStatus(context: Context, title: String, body: String) {
        ensureChannels(context)
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        manager.notify(
            ID_STATUS,
            NotificationCompat.Builder(context, CHANNEL_STATUS)
                .setSmallIcon(R.drawable.ic_notification)
                .setColor(ACCENT)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openApp(context))
                .setAutoCancel(true)
                .build()
        )
    }

    /** Posts the most recent cached find again so notification styling can be checked. */
    fun notifySample(context: Context) {
        val sample = Store.cached(context).firstOrNull() ?: Find(
            postId = 0L,
            threadId = Threads.DAGENS.id,
            threadLabel = Threads.DAGENS.label,
            author = "napahlm",
            createdAt = System.currentTimeMillis() / 1000,
            title = "Dreame Matrix 10 Ultra",
            price = "7128 kr",
            category = "Robotdammsugare",
            store = "komplett.se",
            dealLink = "https://www.komplett.se/",
            note = "Leasa för 297 kr/mån i 24 månader. Eller köp nu för 8990 kr, " +
                "samma pris hos Webbhallen och NetOnNet.\nBara 9h kvar.",
            isStructured = true
        )
        ensureChannels(context)
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        manager.notify(idFor(sample), buildFind(context, sample))
    }

    private fun idFor(find: Find): Int =
        ID_FIND_BASE + (find.postId % 400_000L).toInt()

    private fun openUrl(context: Context, url: String, requestCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun openApp(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    /** The mascot on its grey disc, rendered from the vector for use as the large icon. */
    private fun badgeBitmap(context: Context): Bitmap? {
        val drawable = AppCompatResources.getDrawable(context, R.drawable.ic_swec_badge)
            ?: return null
        val size = (context.resources.displayMetrics.density * 64f).toInt().coerceIn(64, 256)
        return try {
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(Canvas(bitmap))
            bitmap
        } catch (_: Exception) {
            null
        }
    }
}
