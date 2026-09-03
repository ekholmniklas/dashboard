package com.ekholm.fyndkoll

import android.content.Context

/** "Till komplett.se" when the shop is known, otherwise a plain "Till butiken". */
fun shopLabel(context: Context, find: Find): String =
    find.store
        ?.let { context.getString(R.string.action_open_shop_named, it) }
        ?: context.getString(R.string.action_open_shop)
