package com.fanfq.flutter_smsforward

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.provider.Telephony
import android.telephony.SubscriptionManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SmsBridge.attachEventChannel(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SmsBridge.METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasSmsPermission" -> result.success(hasSmsPermission())
                "requestSmsPermission" -> requestSmsPermission(result)
                "requestIgnoreBatteryOptimizations" -> {
                    openBatteryOptimizationSettings()
                    result.success(null)
                }
                "startService" -> result.success(startSmsService())
                "stopService" -> {
                    stopService(Intent(this, SmsForegroundService::class.java))
                    result.success(null)
                }
                "isServiceRunning" -> result.success(SmsForegroundService.isRunning)
                "saveConfig" -> {
                    saveConfig(call.arguments as? Map<*, *> ?: emptyMap<String, Any?>())
                    result.success(null)
                }
                "getConfig" -> result.success(loadConfig())
                "getSimCards" -> result.success(loadSimCards())
                "getRecords" -> result.success(loadRecords())
                "getSentSmsRecords" -> result.success(loadSentSmsRecords())
                "checkKeepAliveNotifications" -> {
                    Thread {
                        val count = checkKeepAliveNotifications()
                        runOnUiThread { result.success(count) }
                    }.start()
                }
                "testKeepAliveNotification" -> {
                    val simKey = call.argument<String>("simKey").orEmpty()
                    Thread {
                        val response = testKeepAliveNotification(simKey)
                        runOnUiThread { result.success(response) }
                    }.start()
                }
                "testForward" -> {
                    Thread {
                        val ok = SmsForwarder(this).sendTestMessage()
                        runOnUiThread { result.success(ok) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SmsBridge.activity = this
    }

    override fun onDestroy() {
        if (SmsBridge.activity == this) {
            SmsBridge.activity = null
        }
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == SMS_PERMISSION_REQUEST) {
            SmsLogger.log("权限申请返回：核心短信权限=${if (hasSmsPermission()) "已授权" else "未授权"}")
            pendingPermissionResult?.success(hasSmsPermission())
            pendingPermissionResult = null
        }
    }

    private fun requestSmsPermission(result: MethodChannel.Result) {
        val missing = requiredRuntimePermissions().filter { permission ->
            ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            SmsLogger.log("权限检查通过：短信、广播、通知权限已具备")
            result.success(true)
            return
        }
        pendingPermissionResult = result
        SmsLogger.log("请求运行时权限：${missing.joinToString()}")
        ActivityCompat.requestPermissions(
            this,
            missing.toTypedArray(),
            SMS_PERMISSION_REQUEST,
        )
    }

    private fun hasSmsPermission(): Boolean {
        return listOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS).all { permission ->
            ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requiredRuntimePermissions(): List<String> {
        return buildList {
            add(Manifest.permission.READ_SMS)
            add(Manifest.permission.RECEIVE_SMS)
            add(Manifest.permission.READ_PHONE_STATE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    private fun startSmsService(): Boolean {
        if (!hasSmsPermission()) {
            SmsLogger.log("启动监听失败：权限未完整授权")
            return false
        }
        SmsLogger.log("准备启动前台短信监听服务")
        val intent = Intent(this, SmsForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(this, intent)
        } else {
            startService(intent)
        }
        return true
    }

    private fun openBatteryOptimizationSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isIgnoringBatteryOptimizations(packageName)) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            return
        }
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        startActivity(intent)
    }

    private fun saveConfig(args: Map<*, *>) {
        getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(SmsConfig.KEY_PHONE_NUMBER, args["phoneNumber"] as? String ?: "")
            .putString(SmsConfig.KEY_DEVICE_NAME, args["deviceName"] as? String ?: "")
            .putString(SmsConfig.KEY_CHANNEL, args["channel"] as? String ?: "feishu")
            .putString(SmsConfig.KEY_WEBHOOK_URL, args["webhookUrl"] as? String ?: "")
            .putString(SmsConfig.KEY_SECRET, args["secret"] as? String ?: "")
            .putString(SmsConfig.KEY_CHANNEL_CONFIGS, encodeChannelConfigs(args["channels"]))
            .putString(SmsConfig.KEY_SIM_CONFIGS, encodeSimConfigs(args["simCards"]))
            .apply()
        refreshServiceNotification()
    }

    private fun refreshServiceNotification() {
        if (!SmsForegroundService.isRunning) {
            return
        }
        val intent = Intent(this, SmsForegroundService::class.java).apply {
            action = SmsForegroundService.ACTION_REFRESH_NOTIFICATION
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(this, intent)
        } else {
            startService(intent)
        }
    }

    private fun loadConfig(): Map<String, Any> {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        return mapOf(
            "phoneNumber" to prefs.getString(SmsConfig.KEY_PHONE_NUMBER, "").orEmpty(),
            "deviceName" to prefs.getString(SmsConfig.KEY_DEVICE_NAME, "").orEmpty(),
            "channel" to prefs.getString(SmsConfig.KEY_CHANNEL, "feishu").orEmpty(),
            "webhookUrl" to prefs.getString(SmsConfig.KEY_WEBHOOK_URL, "").orEmpty(),
            "secret" to prefs.getString(SmsConfig.KEY_SECRET, "").orEmpty(),
            "channels" to loadChannelConfigs(),
            "simCards" to loadSimCards(),
        )
    }

    private fun loadChannelConfigs(): List<Map<String, Any?>> {
        return readSavedChannelConfigs().map { it.toMap() }
    }

    private fun encodeChannelConfigs(value: Any?): String {
        val items = value as? List<*> ?: return getSharedPreferences(
            SmsConfig.PREFS_NAME,
            Context.MODE_PRIVATE,
        ).getString(SmsConfig.KEY_CHANNEL_CONFIGS, "[]").orEmpty()
        val array = JSONArray()
        items.forEach { item ->
            val map = item as? Map<*, *> ?: return@forEach
            array.put(
                JSONObject()
                    .put("channel", map["channel"] as? String ?: "feishu")
                    .put("enabled", map["enabled"] as? Boolean ?: false)
                    .put("webhookUrl", map["webhookUrl"] as? String ?: "")
                    .put("secret", map["secret"] as? String ?: ""),
            )
        }
        return array.toString()
    }

    private fun readSavedChannelConfigs(): List<ForwardChannelConfig> {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(SmsConfig.KEY_CHANNEL_CONFIGS, "[]").orEmpty()
        val array = JSONArray(raw.ifBlank { "[]" })
        val configs = List(array.length()) { index ->
            val item = array.getJSONObject(index)
            ForwardChannelConfig(
                channel = item.optString("channel", "feishu"),
                enabled = item.optBoolean("enabled", false),
                webhookUrl = item.optString("webhookUrl"),
                secret = item.optString("secret"),
            )
        }
        if (configs.isNotEmpty()) {
            return configs
        }
        val legacyWebhook = prefs.getString(SmsConfig.KEY_WEBHOOK_URL, "").orEmpty()
        val legacyChannel = prefs.getString(SmsConfig.KEY_CHANNEL, "feishu").orEmpty()
        val legacySecret = prefs.getString(SmsConfig.KEY_SECRET, "").orEmpty()
        return listOf(
            ForwardChannelConfig(
                channel = legacyChannel.ifBlank { "feishu" },
                enabled = legacyWebhook.isNotBlank(),
                webhookUrl = legacyWebhook,
                secret = legacySecret,
            ),
        )
    }

    private fun loadSimCards(): List<Map<String, Any?>> {
        val saved = readSavedSimConfigs()
        val active = readActiveSimCards()
        if (active.isEmpty()) {
            return saved.values.map { it.toMap() }
        }
        return active.map { sim ->
            val savedConfig = saved[sim.key]
                ?: saved.values.firstOrNull { item ->
                    item.subscriptionId == sim.subscriptionId || item.simSlot == sim.simSlot
                }
            sim.copy(
                phoneNumber = savedConfig?.phoneNumber.orEmpty(),
                forwardEnabled = savedConfig?.forwardEnabled ?: true,
                keepAliveEnabled = savedConfig?.keepAliveEnabled ?: false,
                keepAliveMode = savedConfig?.keepAliveMode ?: "countdown",
                keepAliveDays = savedConfig?.keepAliveDays ?: 100,
                keepAliveNotifyThresholdDays = savedConfig?.keepAliveNotifyThresholdDays ?: 3,
                keepAliveNotifyChannels = savedConfig?.keepAliveNotifyChannels ?: emptyList(),
            ).toMap()
        }
    }

    private fun readActiveSimCards(): List<SimCardConfig> {
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_PHONE_STATE,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            SmsLogger.log("读取当前 SIM 卡信息失败：READ_PHONE_STATE 未授权")
            return emptyList()
        }
        return try {
            val manager = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as? SubscriptionManager
            manager?.activeSubscriptionInfoList.orEmpty().map { info ->
                SimCardConfig(
                    key = SimCardConfig.buildKey(info.subscriptionId, info.simSlotIndex),
                    subscriptionId = info.subscriptionId,
                    simSlot = info.simSlotIndex,
                    displayName = info.displayName?.toString().orEmpty(),
                    carrierName = info.carrierName?.toString().orEmpty(),
                    phoneNumber = "",
                    forwardEnabled = true,
                    keepAliveEnabled = false,
                    keepAliveMode = "countdown",
                    keepAliveDays = 100,
                    keepAliveNotifyThresholdDays = 3,
                    keepAliveNotifyChannels = emptyList(),
                )
            }
        } catch (error: Exception) {
            SmsLogger.error("读取当前 SIM 卡信息异常：${error.message ?: error.javaClass.simpleName}", error)
            emptyList()
        }
    }

    private fun encodeSimConfigs(value: Any?): String {
        val items = value as? List<*> ?: return getSharedPreferences(
            SmsConfig.PREFS_NAME,
            Context.MODE_PRIVATE,
        ).getString(SmsConfig.KEY_SIM_CONFIGS, "[]").orEmpty()
        val array = JSONArray()
        items.forEach { item ->
            val map = item as? Map<*, *> ?: return@forEach
            val subscriptionId = map["subscriptionId"] as? Int ?: -1
            val simSlot = map["simSlot"] as? Int ?: -1
            val key = map["key"] as? String ?: SimCardConfig.buildKey(subscriptionId, simSlot)
            array.put(
                JSONObject()
                    .put("key", key)
                    .put("subscriptionId", subscriptionId)
                    .put("simSlot", simSlot)
                    .put("displayName", map["displayName"] as? String ?: "")
                    .put("carrierName", map["carrierName"] as? String ?: "")
                    .put("phoneNumber", map["phoneNumber"] as? String ?: "")
                    .put("forwardEnabled", map["forwardEnabled"] as? Boolean ?: true)
                    .put("keepAliveEnabled", map["keepAliveEnabled"] as? Boolean ?: false)
                    .put("keepAliveMode", map["keepAliveMode"] as? String ?: "countdown")
                    .put("keepAliveDays", map["keepAliveDays"] as? Int ?: 100)
                    .put(
                        "keepAliveNotifyThresholdDays",
                        map["keepAliveNotifyThresholdDays"] as? Int ?: 3,
                    )
                    .put("keepAliveNotifyChannels", JSONArray(map["keepAliveNotifyChannels"] as? List<*> ?: emptyList<Any>())),
            )
        }
        return array.toString()
    }

    private fun readSavedSimConfigs(): Map<String, SimCardConfig> {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(SmsConfig.KEY_SIM_CONFIGS, "[]").orEmpty()
        val fallbackPhone = prefs.getString(SmsConfig.KEY_PHONE_NUMBER, "").orEmpty()
        val array = JSONArray(raw.ifBlank { "[]" })
        if (array.length() == 0 && fallbackPhone.isNotBlank()) {
            val fallback = SimCardConfig(
                key = "legacy",
                subscriptionId = -1,
                simSlot = -1,
                displayName = "默认号码",
                carrierName = "",
                phoneNumber = fallbackPhone,
                forwardEnabled = true,
                keepAliveEnabled = false,
                keepAliveMode = "countdown",
                keepAliveDays = 100,
                keepAliveNotifyThresholdDays = 3,
                keepAliveNotifyChannels = emptyList(),
            )
            return mapOf(fallback.key to fallback)
        }
        return List(array.length()) { index ->
            val item = array.getJSONObject(index)
            SimCardConfig(
                key = item.optString("key").ifBlank {
                    SimCardConfig.buildKey(
                        item.optInt("subscriptionId", -1),
                        item.optInt("simSlot", -1),
                    )
                },
                subscriptionId = item.optInt("subscriptionId", -1),
                simSlot = item.optInt("simSlot", -1),
                displayName = item.optString("displayName"),
                carrierName = item.optString("carrierName"),
                phoneNumber = item.optString("phoneNumber"),
                forwardEnabled = item.optBoolean("forwardEnabled", true),
                keepAliveEnabled = item.optBoolean("keepAliveEnabled", false),
                keepAliveMode = item.optString("keepAliveMode", "countdown"),
                keepAliveDays = item.optInt("keepAliveDays", 100).takeIf { it > 0 } ?: 100,
                keepAliveNotifyThresholdDays = item.optInt("keepAliveNotifyThresholdDays", 3)
                    .takeIf { it > 0 } ?: 3,
                keepAliveNotifyChannels = item.optJSONArray("keepAliveNotifyChannels")
                    ?.let { array ->
                        List(array.length()) { channelIndex -> array.optString(channelIndex) }
                            .filter { it.isNotBlank() }
                    }
                    ?: emptyList(),
            )
        }.associateBy { it.key }
    }

    private fun loadRecords(): List<Map<String, Any?>> {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        val array = JSONArray(prefs.getString(SmsConfig.KEY_RECORDS, "[]"))
        return List(array.length()) { index ->
            val item = array.getJSONObject(index)
            mapOf(
                "event" to "sms",
                "id" to item.optString("id"),
                "sender" to item.optString("sender"),
                "body" to item.optString("body"),
                "date" to item.optLong("date"),
                "type" to item.optInt("type"),
                "forwardOk" to item.optBoolean("forwardOk"),
                "subscriptionId" to item.optInt("subscriptionId", -1),
                "simSlot" to item.optInt("simSlot", -1),
                "simDisplayName" to item.optString("simDisplayName"),
                "fingerprint" to item.optString("fingerprint"),
            )
        }
    }

    private fun loadSentSmsRecords(): List<Map<String, Any?>> {
        if (!hasSmsPermission()) {
            SmsLogger.log("读取已发送短信失败：READ_SMS 未授权")
            return emptyList()
        }
        val records = mutableListOf<Map<String, Any?>>()
        return try {
            contentResolver.query(
                Telephony.Sms.Sent.CONTENT_URI,
                null,
                null,
                null,
                "${Telephony.Sms.DATE} DESC",
            )?.use { cursor ->
                while (cursor.moveToNext() && records.size < MAX_SENT_SMS_RECORDS) {
                    records.add(cursor.toSentSmsRecord())
                }
            }
            SmsLogger.log("已发送短信读取完成：${records.size} 条")
            records
        } catch (error: Exception) {
            SmsLogger.error("读取已发送短信异常：${error.message ?: error.javaClass.simpleName}", error)
            emptyList()
        }
    }

    private fun checkKeepAliveNotifications(): Int {
        val simConfigs = readSavedSimConfigs().values
            .filter {
                it.keepAliveEnabled &&
                    it.keepAliveNotifyThresholdDays > 0 &&
                    it.keepAliveNotifyChannels.isNotEmpty()
            }
        if (simConfigs.isEmpty()) {
            return 0
        }
        val sentRecords = loadSentSmsRecords()
        if (sentRecords.isEmpty()) {
            SmsLogger.log("保号提醒检查：没有已发送短信记录，跳过通知")
            return 0
        }
        var sentCount = 0
        val forwarder = SmsForwarder(this)
        simConfigs.forEach { sim ->
            val record = sentRecords.firstOrNull { sentRecord -> sentRecord.matchesSim(sim) }
                ?: return@forEach
            val date = record["date"] as? Long ?: return@forEach
            val count = keepAliveCount(sim, date)
            val triggered = if (sim.keepAliveMode == "elapsed") {
                count >= sim.keepAliveNotifyThresholdDays
            } else {
                count <= sim.keepAliveNotifyThresholdDays
            }
            if (!triggered) {
                return@forEach
            }
            val dedupeKey = keepAliveDedupeKey(sim, date)
            if (hasSentKeepAliveNotification(dedupeKey)) {
                return@forEach
            }
            val text = buildKeepAliveNotificationText(sim, record, count)
            if (forwarder.sendKeepAliveReminder(text, sim.keepAliveNotifyChannels)) {
                saveKeepAliveNotification(dedupeKey)
                sentCount += 1
            }
        }
        if (sentCount > 0) {
            SmsLogger.log("保号提醒通知已发送：$sentCount 条")
        }
        return sentCount
    }

    private fun testKeepAliveNotification(simKey: String): Map<String, Any?> {
        val sim = readSavedSimConfigs()[simKey]
            ?: return mapOf("ok" to false, "message" to "未找到该 SIM 配置，请先保存配置")
        val validationMessage = validateKeepAliveNotificationConfig(sim)
        if (validationMessage != null) {
            return mapOf("ok" to false, "message" to validationMessage)
        }
        val sentRecord = loadSentSmsRecords().firstOrNull { it.matchesSim(sim) }
        val text = if (sentRecord == null) {
            "保号提醒测试\nSIM：${sim.label}\n手机号：${sim.phoneNumber.ifBlank { "未配置手机号" }}\n当前没有读取到该 SIM 的已发送短信记录"
        } else {
            val date = sentRecord["date"] as? Long ?: System.currentTimeMillis()
            val count = keepAliveCount(sim, date)
            "保号提醒测试\n" + buildKeepAliveNotificationText(sim, sentRecord, count)
        }
        val ok = SmsForwarder(this).sendKeepAliveReminder(text, sim.keepAliveNotifyChannels)
        return mapOf(
            "ok" to ok,
            "message" to if (ok) "保号提醒测试消息已发送" else "测试消息发送失败，请检查所选通道 Webhook 配置",
        )
    }

    private fun validateKeepAliveNotificationConfig(sim: SimCardConfig): String? {
        if (!sim.keepAliveEnabled) {
            return "请先启用该 SIM 的保号提示"
        }
        if (sim.keepAliveNotifyThresholdDays <= 0) {
            return "请填写大于 0 的通知阈值"
        }
        if (sim.keepAliveNotifyChannels.isEmpty()) {
            return "请选择至少一个保号通知通道"
        }
        val enabledChannels = readSavedChannelConfigs()
            .filter { it.enabled && it.webhookUrl.isNotBlank() }
            .map { it.channel }
            .toSet()
        if (sim.keepAliveNotifyChannels.any { !enabledChannels.contains(it) }) {
            return "选择的保号通知通道尚未启用或未配置 Webhook"
        }
        return null
    }

    private fun Map<String, Any?>.matchesSim(sim: SimCardConfig): Boolean {
        val subscriptionId = this["subscriptionId"] as? Int ?: -1
        val simSlot = this["simSlot"] as? Int ?: -1
        val simDisplayName = this["simDisplayName"] as? String ?: ""
        return (sim.subscriptionId >= 0 && sim.subscriptionId == subscriptionId) ||
            (sim.simSlot >= 0 && sim.simSlot == simSlot) ||
            (sim.displayName.isNotBlank() && sim.displayName == simDisplayName)
    }

    private fun keepAliveCount(sim: SimCardConfig, sentAtMillis: Long): Int {
        val today = startOfDay(System.currentTimeMillis())
        val sentDay = startOfDay(sentAtMillis)
        val elapsed = TimeUnit.MILLISECONDS.toDays(today - sentDay).toInt().coerceAtLeast(0)
        return if (sim.keepAliveMode == "elapsed") {
            elapsed + 1
        } else {
            sim.keepAliveDays - elapsed
        }
    }

    private fun buildKeepAliveNotificationText(
        sim: SimCardConfig,
        record: Map<String, Any?>,
        count: Int,
    ): String {
        val modeLabel = if (sim.keepAliveMode == "elapsed") "累计天数" else "倒计天数"
        val countLabel = if (sim.keepAliveMode == "elapsed") "累计${count}天" else "倒计${count}天"
        val phone = sim.phoneNumber.ifBlank { "未配置手机号" }
        val body = (record["body"] as? String).orEmpty().ifBlank { "无短信内容" }
        val sentAt = record["date"] as? Long ?: 0L
        return "保号提醒\n" +
            "SIM：${sim.label}\n" +
            "手机号：$phone\n" +
            "触发模式：$modeLabel，阈值 ${sim.keepAliveNotifyThresholdDays} 天，当前 $countLabel\n" +
            "最近发送：${formatTime(sentAt)}\n" +
            "短信内容：$body"
    }

    private fun keepAliveDedupeKey(sim: SimCardConfig, sentAtMillis: Long): String {
        return "${sim.key}|${sim.keepAliveMode}|${dateKey(System.currentTimeMillis())}|${startOfDay(sentAtMillis)}"
    }

    private fun hasSentKeepAliveNotification(key: String): Boolean {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getStringSet(SmsConfig.KEY_KEEP_ALIVE_NOTIFIED, emptySet()).orEmpty().contains(key)
    }

    private fun saveKeepAliveNotification(key: String) {
        val prefs = getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        val keys = prefs.getStringSet(SmsConfig.KEY_KEEP_ALIVE_NOTIFIED, emptySet()).orEmpty()
            .filter { it.contains(dateKey(System.currentTimeMillis())) }
            .toMutableSet()
        keys.add(key)
        prefs.edit().putStringSet(SmsConfig.KEY_KEEP_ALIVE_NOTIFIED, keys).apply()
    }

    private fun startOfDay(millis: Long): Long {
        return Calendar.getInstance().apply {
            timeInMillis = millis
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }

    private fun dateKey(millis: Long): String {
        return SimpleDateFormat("yyyyMMdd", Locale.US).format(Date(millis))
    }

    private fun formatTime(millis: Long): String {
        if (millis <= 0L) {
            return "未知时间"
        }
        return SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.CHINA).format(Date(millis))
    }

    private fun Cursor.toSentSmsRecord(): Map<String, Any?> {
        val id = getString(getColumnIndexOrThrow(Telephony.Sms._ID))
        val address = getString(getColumnIndexOrThrow(Telephony.Sms.ADDRESS)) ?: "未知收件人"
        val body = getString(getColumnIndexOrThrow(Telephony.Sms.BODY)) ?: ""
        val date = getLong(getColumnIndexOrThrow(Telephony.Sms.DATE))
        val subscriptionId = optionalInt("sub_id")
            ?: optionalInt("subscription_id")
            ?: optionalInt("sim_id")
        val simSlot = optionalInt("sim_slot")
            ?: optionalInt("slot")
            ?: optionalInt("phone_id")
        return mapOf(
            "id" to id,
            "address" to address,
            "body" to body,
            "date" to date,
            "subscriptionId" to (subscriptionId ?: -1),
            "simSlot" to (simSlot ?: -1),
            "simDisplayName" to resolveSimDisplayName(subscriptionId, simSlot).orEmpty(),
        )
    }

    private fun Cursor.optionalInt(columnName: String): Int? {
        val index = getColumnIndex(columnName)
        if (index < 0 || isNull(index)) {
            return null
        }
        return getInt(index).takeIf { it >= 0 }
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

    companion object {
        private const val SMS_PERMISSION_REQUEST = 2901
        private const val MAX_SENT_SMS_RECORDS = 200
    }
}

object SmsBridge {
    const val METHOD_CHANNEL = "sms_forward/methods"
    private const val EVENT_CHANNEL = "sms_forward/events"

    var activity: Activity? = null
    private var eventSink: EventChannel.EventSink? = null

    fun attachEventChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    fun emit(event: Map<String, Any?>) {
        activity?.runOnUiThread {
            eventSink?.success(event)
        }
    }
}

object SmsLogger {
    private const val TAG = "SmsForward"

    fun log(message: String) {
        Log.i(TAG, message)
        SmsBridge.emit(
            mapOf(
                "event" to "log",
                "message" to message,
            ),
        )
    }

    fun error(message: String, throwable: Throwable? = null) {
        Log.e(TAG, message, throwable)
        SmsBridge.emit(
            mapOf(
                "event" to "log",
                "message" to message,
            ),
        )
    }
}

object SmsConfig {
    const val PREFS_NAME = "sms_forward_config"
    const val KEY_PHONE_NUMBER = "phoneNumber"
    const val KEY_DEVICE_NAME = "deviceName"
    const val KEY_CHANNEL = "channel"
    const val KEY_WEBHOOK_URL = "webhookUrl"
    const val KEY_SECRET = "secret"
    const val KEY_RECORDS = "records"
    const val KEY_SIM_CONFIGS = "simConfigs"
    const val KEY_CHANNEL_CONFIGS = "channelConfigs"
    const val KEY_LAST_SEEN_SMS_DATE = "lastSeenSmsDate"
    const val KEY_KEEP_ALIVE_NOTIFIED = "keepAliveNotified"
}

data class ForwardChannelConfig(
    val channel: String,
    val enabled: Boolean,
    val webhookUrl: String,
    val secret: String,
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "channel" to channel,
            "enabled" to enabled,
            "webhookUrl" to webhookUrl,
            "secret" to secret,
        )
    }
}

data class SimCardConfig(
    val key: String,
    val subscriptionId: Int,
    val simSlot: Int,
    val displayName: String,
    val carrierName: String,
    val phoneNumber: String,
    val forwardEnabled: Boolean,
    val keepAliveEnabled: Boolean,
    val keepAliveMode: String,
    val keepAliveDays: Int,
    val keepAliveNotifyThresholdDays: Int,
    val keepAliveNotifyChannels: List<String>,
) {
    val label: String
        get() {
            val slot = if (simSlot >= 0) "SIM${simSlot + 1}" else ""
            return listOf(displayName, carrierName, slot, if (subscriptionId >= 0) "subId=$subscriptionId" else "")
                .filter { it.isNotBlank() }
                .distinct()
                .joinToString(" / ")
                .ifBlank { "未知SIM" }
        }

    fun toMap(): Map<String, Any?> {
        return mapOf(
            "key" to key,
            "subscriptionId" to subscriptionId,
            "simSlot" to simSlot,
            "displayName" to displayName,
            "carrierName" to carrierName,
            "phoneNumber" to phoneNumber,
            "forwardEnabled" to forwardEnabled,
            "keepAliveEnabled" to keepAliveEnabled,
            "keepAliveMode" to keepAliveMode,
            "keepAliveDays" to keepAliveDays,
            "keepAliveNotifyThresholdDays" to keepAliveNotifyThresholdDays,
            "keepAliveNotifyChannels" to keepAliveNotifyChannels,
        )
    }

    companion object {
        fun buildKey(subscriptionId: Int, simSlot: Int): String {
            return when {
                subscriptionId >= 0 -> "sub_$subscriptionId"
                simSlot >= 0 -> "slot_$simSlot"
                else -> "unknown"
            }
        }
    }
}
