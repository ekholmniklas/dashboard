package com.ekholm.fyndkoll

import android.text.format.DateUtils
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.ekholm.fyndkoll.databinding.ItemFindBinding

class FindAdapter(
    private val onOpenPost: (Find) -> Unit,
    private val onOpenShop: (Find) -> Unit
) : ListAdapter<Find, FindAdapter.Holder>(DIFF) {

    class Holder(val binding: ItemFindBinding) : RecyclerView.ViewHolder(binding.root)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = Holder(
        ItemFindBinding.inflate(LayoutInflater.from(parent.context), parent, false)
    )

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val find = getItem(position)
        val binding = holder.binding
        val context = binding.root.context

        binding.title.text = find.title

        binding.price.text = find.price
        binding.price.visibility = if (find.price != null) View.VISIBLE else View.GONE

        val meta = listOfNotNull(find.category, find.store).joinToString(" · ")
        binding.meta.text = meta
        binding.meta.visibility = if (meta.isNotBlank()) View.VISIBLE else View.GONE

        binding.note.text = find.note
        binding.note.visibility = if (find.note.isNotBlank()) View.VISIBLE else View.GONE

        val stamp = if (find.createdAt > 0) {
            DateUtils.getRelativeTimeSpanString(
                find.createdAt * 1000,
                System.currentTimeMillis(),
                DateUtils.MINUTE_IN_MILLIS
            ).toString()
        } else {
            null
        }
        binding.footer.text = listOfNotNull(
            find.threadLabel,
            find.author.takeIf { it.isNotBlank() },
            stamp
        ).joinToString(" · ")

        binding.openShop.visibility = if (find.dealLink != null) View.VISIBLE else View.GONE
        binding.openShop.text = shopLabel(context, find)
        binding.openShop.setOnClickListener { onOpenShop(find) }

        binding.root.setOnClickListener { onOpenPost(find) }
    }

    companion object {
        private val DIFF = object : DiffUtil.ItemCallback<Find>() {
            override fun areItemsTheSame(oldItem: Find, newItem: Find) =
                oldItem.postId == newItem.postId

            override fun areContentsTheSame(oldItem: Find, newItem: Find) =
                oldItem == newItem
        }
    }
}
