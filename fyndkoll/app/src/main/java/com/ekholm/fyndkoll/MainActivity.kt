package com.ekholm.fyndkoll

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.format.DateUtils
import android.view.Menu
import android.view.MenuItem
import android.view.View
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import com.ekholm.fyndkoll.databinding.ActivityMainBinding
import com.google.android.material.snackbar.Snackbar
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var adapter: FindAdapter

    private val requestNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (!granted) {
                Snackbar.make(
                    binding.root,
                    R.string.notifications_denied,
                    Snackbar.LENGTH_LONG
                ).setAction(R.string.action_settings) { openNotificationSettings() }.show()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar)

        Notifier.ensureChannels(this)

        adapter = FindAdapter(
            onOpenPost = { open(it.permalink) },
            onOpenShop = { find -> find.dealLink?.let { open(it) } }
        )
        binding.list.layoutManager = LinearLayoutManager(this)
        binding.list.adapter = adapter

        binding.swipe.setOnRefreshListener { refresh(userInitiated = true) }

        adapter.submitList(Store.cached(this))
        renderStatus()

        askForNotificationPermission()
        Scheduler.schedule(this)

        // First launch has nothing cached, so fetch immediately.
        if (Store.cached(this).isEmpty()) {
            refresh(userInitiated = false)
        }
    }

    override fun onResume() {
        super.onResume()
        adapter.submitList(Store.cached(this))
        renderStatus()
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.main, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean = when (item.itemId) {
        R.id.action_refresh -> {
            refresh(userInitiated = true)
            true
        }
        R.id.action_interval -> {
            showIntervalDialog()
            true
        }
        R.id.action_test -> {
            Notifier.notifySample(this)
            true
        }
        R.id.action_threads -> {
            showThreadDialog()
            true
        }
        R.id.action_notification_settings -> {
            openNotificationSettings()
            true
        }
        R.id.action_battery -> {
            openBatterySettings()
            true
        }
        else -> super.onOptionsItemSelected(item)
    }

    private fun refresh(userInitiated: Boolean) {
        binding.swipe.isRefreshing = true
        lifecycleScope.launch {
            val result = Refresher.refresh(this@MainActivity, notify = !userInitiated)
            binding.swipe.isRefreshing = false
            adapter.submitList(result.all)
            if (result.all.isNotEmpty()) binding.list.scrollToPosition(0)
            renderStatus()

            when {
                result.error != null && result.all.isEmpty() ->
                    Snackbar.make(binding.root, getString(R.string.refresh_failed, result.error), Snackbar.LENGTH_LONG).show()
                userInitiated && result.new.isNotEmpty() ->
                    Snackbar.make(
                        binding.root,
                        resources.getQuantityString(R.plurals.new_finds, result.new.size, result.new.size),
                        Snackbar.LENGTH_SHORT
                    ).show()
                userInitiated && result.seeded ->
                    Snackbar.make(binding.root, R.string.seeded_title, Snackbar.LENGTH_SHORT).show()
            }
        }
    }

    private fun renderStatus() {
        val lastCheck = Store.lastCheck(this)
        val interval = Store.intervalMinutes(this)
        val stamp = if (lastCheck > 0) {
            DateUtils.getRelativeTimeSpanString(
                lastCheck, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS
            ).toString()
        } else {
            getString(R.string.never)
        }

        val parts = mutableListOf(getString(R.string.status_line, stamp, interval))
        if (Notifier.notificationsBlocked(this)) parts += getString(R.string.status_blocked)
        Store.lastError(this)?.let { parts += getString(R.string.status_error, it) }

        binding.status.text = parts.joinToString(" — ")

        val empty = adapter.itemCount == 0
        binding.empty.visibility = if (empty) View.VISIBLE else View.GONE
        binding.list.visibility = if (empty) View.GONE else View.VISIBLE
    }

    private fun showIntervalDialog() {
        val choices = Scheduler.INTERVAL_CHOICES
        val labels = choices.map { minutes ->
            if (minutes < 60) {
                getString(R.string.interval_minutes, minutes)
            } else {
                getString(R.string.interval_hours, minutes / 60)
            }
        }.toTypedArray()
        val current = choices.indexOf(Store.intervalMinutes(this)).coerceAtLeast(0)

        AlertDialog.Builder(this)
            .setTitle(R.string.action_interval)
            .setSingleChoiceItems(labels, current) { dialog, which ->
                Store.setIntervalMinutes(this, choices[which])
                Scheduler.schedule(this, choices[which])
                renderStatus()
                dialog.dismiss()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun showThreadDialog() {
        val labels = Threads.ALL.map { it.label }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(R.string.action_threads)
            .setItems(labels) { _, which -> open(Threads.ALL[which].lastPageUrl) }
            .show()
    }

    /**
     * Notifications are the whole point of the app, so ask whenever it is not granted.
     * If the user has permanently denied it the system call returns immediately and the
     * snackbar explains what is missing.
     */
    private fun askForNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private fun openNotificationSettings() {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        startSafely(intent)
    }

    /**
     * Samsung is aggressive about putting apps to sleep, which stops the periodic
     * poll. This opens the system list where Fyndkoll can be excluded.
     */
    private fun openBatterySettings() {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val exempt = power?.isIgnoringBatteryOptimizations(packageName) == true
        if (exempt) {
            Snackbar.make(binding.root, R.string.battery_already_ok, Snackbar.LENGTH_LONG).show()
            return
        }
        startSafely(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    private fun open(url: String) {
        startSafely(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }

    private fun startSafely(intent: Intent) {
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            Snackbar.make(binding.root, R.string.no_app_for_intent, Snackbar.LENGTH_LONG).show()
        }
    }
}
