package com.fanfq.flutter_smsforward

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Telephony
import androidx.core.content.ContextCompat
import kotlin.math.abs

class SmsBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
            return
        }
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) {
            SmsLogger.log("收到 SMS_RECEIVED 广播，但 PDU 为空")
            return
        }

        val sender = messages.firstOrNull()?.displayOriginatingAddress.orEmpty()
        val body = messages.joinToString(separator = "") { it.messageBody.orEmpty() }
        val date = messages.firstOrNull()?.timestampMillis ?: System.currentTimeMillis()
        val subscriptionId = intent.readSubscriptionId()
        val simSlot = intent.readSimSlot()
        val id = "broadcast-${abs("$date|$sender|$body|$subscriptionId".hashCode())}"

        SmsLogger.log(
            "收到 SMS_RECEIVED 广播：sender=$sender, length=${body.length}, " +
                "subscriptionId=${subscriptionId ?: "unknown"}, simSlot=${simSlot ?: "unknown"}",
        )

        val serviceIntent = Intent(context, SmsForegroundService::class.java).apply {
            action = SmsForegroundService.ACTION_HANDLE_BROADCAST_SMS
            putExtra(SmsForegroundService.EXTRA_SMS_ID, id)
            putExtra(SmsForegroundService.EXTRA_SENDER, sender.ifBlank { "未知发件人" })
            putExtra(SmsForegroundService.EXTRA_BODY, body)
            putExtra(SmsForegroundService.EXTRA_DATE, date)
            putExtra(SmsForegroundService.EXTRA_TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX)
            subscriptionId?.let { putExtra(SmsForegroundService.EXTRA_SUBSCRIPTION_ID, it) }
            simSlot?.let { putExtra(SmsForegroundService.EXTRA_SIM_SLOT, it) }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(context, serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }

    private fun Intent.readSubscriptionId(): Int? {
        val keys = listOf(
            "subscription",
            "subscription_id",
            "android.telephony.extra.SUBSCRIPTION_INDEX",
            "phone",
        )
        return keys.firstNotNullOfOrNull { key -> readIntExtra(key) }
    }

    private fun Intent.readSimSlot(): Int? {
        val keys = listOf(
            "slot",
            "simSlot",
            "slot_id",
            "sim_slot",
            "android.telephony.extra.SLOT_INDEX",
        )
        return keys.firstNotNullOfOrNull { key -> readIntExtra(key) }
    }

    private fun Intent.readIntExtra(key: String): Int? {
        if (!hasExtra(key)) {
            return null
        }
        val value = extras?.get(key)
        return when (value) {
            is Int -> value
            is Long -> value.toInt()
            is String -> value.toIntOrNull()
            else -> null
        }?.takeIf { it >= 0 }
    }
}
