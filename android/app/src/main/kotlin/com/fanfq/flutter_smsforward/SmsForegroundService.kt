package com.fanfq.flutter_smsforward

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Telephony
import android.telephony.SubscriptionManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import kotlin.math.abs

class SmsForegroundService : Service() {
    private var smsObserver: ContentObserver? = null
    private var lastSeenSmsDate: Long = 0L
    private var serviceStartedAt: Long = 0L
    private val processingFingerprints = mutableSetOf<String>()
    private val forwarder by lazy { SmsForwarder(this) }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        serviceStartedAt = System.currentTimeMillis()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        registerSmsObserver()
        SmsLogger.log("短信监听服务 onCreate：前台通知已启动")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        SmsLogger.log("短信监听服务 onStartCommand：action=${intent?.action ?: "default"}")
        if (smsObserver == null) {
            registerSmsObserver()
        }
        when (intent?.action) {
            ACTION_HANDLE_BROADCAST_SMS -> handleBroadcastSms(intent)
            ACTION_REFRESH_NOTIFICATION -> refreshNotification()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        smsObserver?.let { contentResolver.unregisterContentObserver(it) }
        smsObserver = null
        isRunning = false
        SmsLogger.log("短信监听服务 onDestroy：监听已注销")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun registerSmsObserver() {
        if (!hasSmsPermission()) {
            SmsLogger.log("缺少短信读取权限，无法注册 ContentObserver")
            stopSelf()
            return
        }
        if (smsObserver != null) {
            SmsLogger.log("ContentObserver 已存在，跳过重复注册")
            return
        }
        lastSeenSmsDate = maxOf(lastSeenSmsDate, loadLastSeenSmsDate(), queryLatestSmsDate())
        smsObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                SmsLogger.log("ContentObserver 触发：uri=${uri ?: "unknown"}")
                handleLatestSms()
            }
        }
        contentResolver.registerContentObserver(
            Telephony.Sms.CONTENT_URI,
            true,
            smsObserver!!,
        )
        SmsLogger.log("ContentObserver 注册成功：content://sms，历史基线时间=$lastSeenSmsDate")
    }

    private fun handleBroadcastSms(intent: Intent) {
        val subscriptionId = intent.optionalIntExtra(EXTRA_SUBSCRIPTION_ID)
        val simSlot = intent.optionalIntExtra(EXTRA_SIM_SLOT)
        val sms = SmsMessage(
            id = intent.getStringExtra(EXTRA_SMS_ID) ?: "broadcast-${System.currentTimeMillis()}",
            sender = intent.getStringExtra(EXTRA_SENDER) ?: "未知发件人",
            body = intent.getStringExtra(EXTRA_BODY) ?: "",
            date = intent.getLongExtra(EXTRA_DATE, System.currentTimeMillis()),
            type = intent.getIntExtra(EXTRA_TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX),
            subscriptionId = subscriptionId,
            simSlot = simSlot,
            simDisplayName = resolveSimDisplayName(subscriptionId, simSlot),
        )
        SmsLogger.log(
            "处理广播短信：id=${sms.id}, sender=${sms.sender}, " +
                "subscriptionId=${sms.subscriptionId ?: "unknown"}, sim=${sms.simLabel}",
        )
        processSms(sms, source = "广播")
        scheduleDelayedInboxCheck(sms.date)
    }

    private fun handleLatestSms() {
        Thread {
            val messages = queryNewSmsMessages(minDate = null)
            if (messages.isEmpty()) {
                SmsLogger.log("短信库触发后未发现新短信，已跳过历史记录")
                return@Thread
            }
            messages.forEach { sms -> processSms(sms, source = "数据库") }
        }.start()
    }

    private fun scheduleDelayedInboxCheck(triggerDate: Long) {
        Handler(Looper.getMainLooper()).postDelayed({
            Thread {
                val minDate = triggerDate - DELAYED_QUERY_LOOKBACK_MILLIS
                SmsLogger.log("广播后延迟 ${DELAYED_INBOX_QUERY_MILLIS}ms 查询短信库：minDate=$minDate")
                val messages = queryNewSmsMessages(minDate = minDate, ignoreBaseline = true)
                if (messages.isEmpty()) {
                    SmsLogger.log("广播后延迟查询未发现短信库新记录")
                    return@Thread
                }
                messages.forEach { sms -> processSms(sms, source = "延迟短信库") }
            }.start()
        }, DELAYED_INBOX_QUERY_MILLIS)
    }

    private fun processSms(sms: SmsMessage, source: String) {
        Thread {
            if (sms.body.isBlank()) {
                SmsLogger.log("$source 短信正文为空，跳过")
                return@Thread
            }
            val fingerprint = sms.forwardFingerprint
            synchronized(processingFingerprints) {
                if (processingFingerprints.contains(fingerprint)) {
                    SmsLogger.log("$source 短信正在转发中，跳过并发重复：fingerprint=$fingerprint")
                    return@Thread
                }
                if (hasSuccessfulForwardRecord(sms)) {
                    SmsLogger.log("$source 短信已成功转发过，跳过重复转发：fingerprint=$fingerprint")
                    return@Thread
                }
                processingFingerprints.add(fingerprint)
            }
            try {
                lastSeenSmsDate = maxOf(lastSeenSmsDate, sms.date)
                saveLastSeenSmsDate(lastSeenSmsDate)
                SmsLogger.log(
                    "$source 短信准备转发：sender=${sms.sender}, length=${sms.body.length}, " +
                        "subscriptionId=${sms.subscriptionId ?: "unknown"}, sim=${sms.simLabel}, " +
                        "fingerprint=$fingerprint",
                )
                val forwardOk = forwarder.forwardSms(sms)
                SmsLogger.log("$source 短信转发结果：${if (forwardOk) "成功" else "失败"}")
                saveRecord(sms, forwardOk, fingerprint)
                SmsBridge.emit(sms.toEvent(forwardOk))
            } finally {
                synchronized(processingFingerprints) {
                    processingFingerprints.remove(fingerprint)
                }
            }
        }.start()
    }

    private fun queryNewSmsMessages(
        minDate: Long?,
        ignoreBaseline: Boolean = false,
    ): List<SmsMessage> {
        if (!hasSmsPermission()) {
            SmsLogger.log("查询短信库失败：READ_SMS 未授权")
            return emptyList()
        }
        val baseline = if (ignoreBaseline) {
            maxOf(minDate ?: 0L, serviceStartedAt - STARTUP_HISTORY_GRACE_MILLIS)
        } else {
            maxOf(lastSeenSmsDate, loadLastSeenSmsDate(), minDate ?: 0L)
        }
        val messages = mutableListOf<SmsMessage>()
        contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            null,
            "${Telephony.Sms.DATE} > ?",
            arrayOf(baseline.toString()),
            "${Telephony.Sms.DATE} ASC",
        )?.use { cursor ->
            if (!cursor.moveToFirst()) {
                SmsLogger.log("短信库查询成功，但没有晚于基线 $baseline 的新记录")
                return emptyList()
            }
            do {
                messages.add(cursor.toSmsMessage())
            } while (cursor.moveToNext() && messages.size < MAX_QUERY_MESSAGES)
        }
        SmsLogger.log("短信库查询到 ${messages.size} 条新短信，baseline=$baseline")
        return messages
    }

    private fun queryLatestSmsDate(): Long {
        if (!hasSmsPermission()) {
            return 0L
        }
        return contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.DATE),
            null,
            null,
            "${Telephony.Sms.DATE} DESC",
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getLong(cursor.getColumnIndexOrThrow(Telephony.Sms.DATE))
            } else {
                0L
            }
        } ?: 0L
    }

    private fun Cursor.toSmsMessage(): SmsMessage {
        val id = getString(getColumnIndexOrThrow(Telephony.Sms._ID))
        val sender = getString(getColumnIndexOrThrow(Telephony.Sms.ADDRESS))
            ?: "未知发件人"
        val body = getString(getColumnIndexOrThrow(Telephony.Sms.BODY)) ?: ""
        val date = getLong(getColumnIndexOrThrow(Telephony.Sms.DATE))
        val type = getInt(getColumnIndexOrThrow(Telephony.Sms.TYPE))
        val subscriptionId = optionalInt("sub_id")
            ?: optionalInt("subscription_id")
            ?: optionalInt("sim_id")
        val simSlot = optionalInt("sim_slot")
            ?: optionalInt("slot")
            ?: optionalInt("phone_id")
        val sms = SmsMessage(
            id = id,
            sender = sender,
            body = body,
            date = date,
            type = type,
            subscriptionId = subscriptionId,
            simSlot = simSlot,
            simDisplayName = resolveSimDisplayName(subscriptionId, simSlot),
        )
        SmsLogger.log(
            "短信库读取短信：id=$id, date=$date, sender=$sender, " +
                "subscriptionId=${subscriptionId ?: "unknown"}, sim=${sms.simLabel}",
        )
        return sms
    }

    private fun hasSuccessfulForwardRecord(sms: SmsMessage): Boolean {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        val records = JSONArray(prefs.getString(SmsConfig.KEY_RECORDS, "[]"))
        for (index in 0 until records.length()) {
            val item = records.getJSONObject(index)
            val itemForwardOk = item.optBoolean("forwardOk")
            val sameFingerprint = item.optString("fingerprint") == sms.forwardFingerprint
            val sameLegacyMessage = item.optString("sender") == sms.sender &&
                item.optString("body") == sms.body &&
                abs(item.optLong("date") - sms.date) <= DUPLICATE_WINDOW_MILLIS &&
                simMatches(item, sms)
            if (itemForwardOk && (sameFingerprint || sameLegacyMessage)) {
                return true
            }
        }
        return false
    }

    private fun simMatches(item: JSONObject, sms: SmsMessage): Boolean {
        val itemSubId = item.optInt("subscriptionId", -1)
        val itemSlot = item.optInt("simSlot", -1)
        return when {
            itemSubId >= 0 && sms.subscriptionId != null -> itemSubId == sms.subscriptionId
            itemSlot >= 0 && sms.simSlot != null -> itemSlot == sms.simSlot
            else -> true
        }
    }

    private fun saveRecord(sms: SmsMessage, forwardOk: Boolean, fingerprint: String) {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        val existing = JSONArray(prefs.getString(SmsConfig.KEY_RECORDS, "[]"))
        val next = JSONArray()
        next.put(
            JSONObject()
                .put("id", sms.id)
                .put("sender", sms.sender)
                .put("body", sms.body)
                .put("date", sms.date)
                .put("type", sms.type)
                .put("subscriptionId", sms.subscriptionId ?: -1)
                .put("simSlot", sms.simSlot ?: -1)
                .put("simDisplayName", sms.simDisplayName.orEmpty())
                .put("fingerprint", fingerprint)
                .put("forwardOk", forwardOk),
        )
        for (index in 0 until existing.length()) {
            if (next.length() >= MAX_STORED_RECORDS) {
                break
            }
            val item = existing.getJSONObject(index)
            if (item.optString("fingerprint") != fingerprint && item.optString("id") != sms.id) {
                next.put(item)
            }
        }
        prefs.edit().putString(SmsConfig.KEY_RECORDS, next.toString()).apply()
    }

    private fun loadLastSeenSmsDate(): Long {
        return getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .getLong(SmsConfig.KEY_LAST_SEEN_SMS_DATE, 0L)
    }

    private fun saveLastSeenSmsDate(date: Long) {
        getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putLong(SmsConfig.KEY_LAST_SEEN_SMS_DATE, date)
            .apply()
    }


    private fun hasSmsPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_SMS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun resolveSimDisplayName(subscriptionId: Int?, simSlot: Int?): String? {
        if (subscriptionId == null && simSlot == null) {
            return null
        }
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_PHONE_STATE,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return simSlot?.let { "SIM${it + 1}" }
        }
        return try {
            val manager = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as? SubscriptionManager
            val subscriptions = manager?.activeSubscriptionInfoList.orEmpty()
            val match = subscriptions.firstOrNull { info ->
                (subscriptionId != null && info.subscriptionId == subscriptionId) ||
                    (simSlot != null && info.simSlotIndex == simSlot)
            }
            match?.displayName?.toString()?.takeIf { it.isNotBlank() }
                ?: simSlot?.let { "SIM${it + 1}" }
        } catch (error: Exception) {
            SmsLogger.error("读取 SIM 信息失败：${error.message ?: error.javaClass.simpleName}", error)
            simSlot?.let { "SIM${it + 1}" }
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val phones = enabledPhoneSummary()
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_action_email)
            .setContentTitle("短信监听运行中")
            .setContentText("监听号码：$phones")
            .setStyle(NotificationCompat.BigTextStyle().bigText("监听号码：$phones"))
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun refreshNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
        SmsLogger.log("通知栏监听号码已刷新：${enabledPhoneSummary()}")
    }

    private fun enabledPhoneSummary(): String {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        val array = JSONArray(prefs.getString(SmsConfig.KEY_SIM_CONFIGS, "[]"))
        val phones = mutableListOf<String>()
        for (index in 0 until array.length()) {
            val item = array.getJSONObject(index)
            if (!item.optBoolean("forwardEnabled", true)) {
                continue
            }
            val phone = item.optString("phoneNumber").ifBlank { null }
            val simSlot = item.optInt("simSlot", -1)
            val label = phone ?: if (simSlot >= 0) "SIM${simSlot + 1}" else null
            label?.let { phones.add(it) }
        }
        if (phones.isEmpty()) {
            prefs.getString(SmsConfig.KEY_PHONE_NUMBER, "").orEmpty()
                .ifBlank { "未配置手机号" }
                .let { phones.add(it) }
        }
        return phones.distinct().joinToString("、")
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "短信监听服务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持短信监听服务在后台运行"
            setShowBadge(false)
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val ACTION_HANDLE_BROADCAST_SMS =
            "com.fanfq.flutter_smsforward.ACTION_HANDLE_BROADCAST_SMS"
        const val ACTION_REFRESH_NOTIFICATION =
            "com.fanfq.flutter_smsforward.ACTION_REFRESH_NOTIFICATION"
        const val EXTRA_SMS_ID = "sms_id"
        const val EXTRA_SENDER = "sender"
        const val EXTRA_BODY = "body"
        const val EXTRA_DATE = "date"
        const val EXTRA_TYPE = "type"
        const val EXTRA_SUBSCRIPTION_ID = "subscription_id"
        const val EXTRA_SIM_SLOT = "sim_slot"
        const val CHANNEL_ID = "sms_forward_service"
        private const val NOTIFICATION_ID = 6201
        private const val MAX_STORED_RECORDS = 500
        private const val MAX_QUERY_MESSAGES = 20
        private const val DUPLICATE_WINDOW_MILLIS = 5 * 60 * 1000L
        private const val DELAYED_INBOX_QUERY_MILLIS = 3000L
        private const val DELAYED_QUERY_LOOKBACK_MILLIS = 15000L
        private const val STARTUP_HISTORY_GRACE_MILLIS = 2 * 60 * 1000L
        @Volatile
        var isRunning: Boolean = false
    }
}

data class SmsMessage(
    val id: String,
    val sender: String,
    val body: String,
    val date: Long,
    val type: Int,
    val subscriptionId: Int? = null,
    val simSlot: Int? = null,
    val simDisplayName: String? = null,
) {
    val simLabel: String
        get() {
            val slotLabel = simSlot?.let { "SIM${it + 1}" }
            return listOfNotNull(simDisplayName, slotLabel, subscriptionId?.let { "subId=$it" })
                .distinct()
                .joinToString(" / ")
                .ifBlank { "未知SIM" }
        }
    val forwardFingerprint: String
        get() {
            val simKey = subscriptionId?.let { "sub:$it" }
                ?: simSlot?.let { "slot:$it" }
                ?: simDisplayName.orEmpty()
            val dateBucket = date / 60000L
            return sha256("${sender.trim()}|${body.trim()}|$simKey|$dateBucket")
        }

    fun toEvent(forwardOk: Boolean): Map<String, Any?> {
        return mapOf(
            "event" to "sms",
            "id" to id,
            "sender" to sender,
            "body" to body,
            "date" to date,
            "type" to type,
            "subscriptionId" to (subscriptionId ?: -1),
            "simSlot" to (simSlot ?: -1),
            "simDisplayName" to simDisplayName.orEmpty(),
            "fingerprint" to forwardFingerprint,
            "forwardOk" to forwardOk,
        )
    }
}

private fun sha256(value: String): String {
    val bytes = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
    return bytes.joinToString("") { byte -> "%02x".format(byte) }.take(24)
}

private fun Intent.optionalIntExtra(key: String): Int? {
    if (!hasExtra(key)) {
        return null
    }
    val value = getIntExtra(key, -1)
    return value.takeIf { it >= 0 }
}

private fun Cursor.optionalInt(columnName: String): Int? {
    val index = getColumnIndex(columnName)
    if (index < 0 || isNull(index)) {
        return null
    }
    return getInt(index).takeIf { it >= 0 }
}
