package com.ekholm.fyndkoll

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

class FyndWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        return try {
            val result = Refresher.refresh(applicationContext, notify = true)
            if (result.error != null && result.all.isEmpty()) Result.retry() else Result.success()
        } catch (e: Exception) {
            Store.setLastError(applicationContext, e.javaClass.simpleName)
            if (runAttemptCount < 3) Result.retry() else Result.success()
        }
    }
}

object Scheduler {

    private const val WORK_PERIODIC = "fynd-poll"
    private const val WORK_ONESHOT = "fynd-poll-now"

    /** WorkManager will not run periodic work more often than every 15 minutes. */
    const val MIN_INTERVAL_MINUTES = 15

    val INTERVAL_CHOICES = listOf(15, 30, 60, 120, 180)

    fun schedule(context: Context, minutes: Int = Store.intervalMinutes(context)) {
        val interval = minutes.coerceAtLeast(MIN_INTERVAL_MINUTES).toLong()
        val request = PeriodicWorkRequestBuilder<FyndWorker>(interval, TimeUnit.MINUTES)
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build()
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.MINUTES)
            .build()

        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_PERIODIC,
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }

    fun runNow(context: Context) {
        WorkManager.getInstance(context).enqueueUniqueWork(
            WORK_ONESHOT,
            androidx.work.ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<FyndWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()
        )
    }
}
