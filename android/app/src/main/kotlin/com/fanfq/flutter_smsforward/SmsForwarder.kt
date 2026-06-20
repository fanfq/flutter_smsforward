package com.fanfq.flutter_smsforward

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class SmsForwarder(private val context: Context) {
    fun forwardSms(sms: SmsMessage): Boolean {
        val config = readConfig()
        val simConfig = config.findSimConfig(sms)
        if (simConfig?.forwardEnabled == false) {
            SmsLogger.log("当前 SIM 已关闭转发：${sms.simLabel}, phone=${simConfig.phoneNumber.ifBlank { "未配置" }}")
            return false
        }
        val enabledChannels = config.enabledChannels()
        if (enabledChannels.isEmpty()) {
            SmsLogger.log("未配置启用的转发通道，短信未转发")
            return false
        }
        val text = buildSmsText(config, sms, simConfig)
        val results = enabledChannels.map { channel -> post(channel, config, text) }
        return results.any { it }
    }

    fun sendTestMessage(): Boolean {
        val config = readConfig()
        val enabledChannels = config.enabledChannels()
        if (enabledChannels.isEmpty()) {
            SmsLogger.log("未配置启用的转发通道，测试消息未发送")
            return false
        }
        val device = config.deviceName.ifBlank { "未命名设备" }
        val enabledSims = config.simCards
            .filter { it.forwardEnabled }
            .joinToString("；") { "${it.label}=${it.phoneNumber.ifBlank { "未配置手机号" }}" }
            .ifBlank { "未配置 SIM" }
        val channelNames = enabledChannels.joinToString("、") { it.label }
        val text = "短信转发助手测试消息\n设备：$device\n通道：$channelNames\n已启用SIM：$enabledSims"
        val results = enabledChannels.map { channel -> post(channel, config, text) }
        return results.any { it }
    }

    fun sendKeepAliveReminder(text: String, channelKeys: List<String>): Boolean {
        val config = readConfig()
        val enabledChannels = config.enabledChannels()
            .filter { channel -> channelKeys.contains(channel.channel) }
        if (enabledChannels.isEmpty()) {
            SmsLogger.log("未配置可用的保号通知通道，保号提醒未发送")
            return false
        }
        val results = enabledChannels.map { channel -> post(channel, config, text) }
        return results.any { it }
    }

    private fun post(channel: WebhookChannelConfig, config: ForwardConfig, text: String): Boolean {
        return try {
            val targetUrl = buildTargetUrl(channel)
            val payload = buildPayload(channel, config, text)
            SmsLogger.log("准备请求 Webhook：channel=${channel.label}, url=${targetUrl.maskSecret()}")
            val connection = URL(targetUrl).openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            OutputStreamWriter(connection.outputStream, Charsets.UTF_8).use { writer ->
                writer.write(payload.toString())
            }
            val code = connection.responseCode
            val ok = code in 200..299
            SmsLogger.log(if (ok) "${channel.label} 转发成功：HTTP $code" else "${channel.label} 转发失败：HTTP $code")
            connection.disconnect()
            ok
        } catch (error: Exception) {
            SmsLogger.error("${channel.label} 转发异常：${error.message ?: error.javaClass.simpleName}", error)
            false
        }
    }

    private fun buildSmsText(
        config: ForwardConfig,
        sms: SmsMessage,
        simConfig: SimForwardConfig?,
    ): String {
        val device = config.deviceName.ifBlank { "未命名设备" }
        val phone = simConfig?.phoneNumber?.ifBlank { null }
            ?: config.phoneNumber.ifBlank { "未设置" }
        val simLabel = simConfig?.label?.ifBlank { null } ?: sms.simLabel
        return "新短信\n设备：$device\n接收手机号：$phone\nSIM：$simLabel\n发件人：${sms.sender}\n内容：${sms.body}"
    }

    private fun buildPayload(
        channel: WebhookChannelConfig,
        config: ForwardConfig,
        text: String,
    ): JSONObject {
        return when (channel.channel) {
            "dingtalk" -> JSONObject()
                .put("msgtype", "text")
                .put("text", JSONObject().put("content", text))
            "generic" -> JSONObject()
                .put("source", "sms_forward")
                .put("text", text)
                .put("deviceName", config.deviceName)
                .put("phoneNumber", config.defaultPhoneNumber())
            else -> {
                val payload = JSONObject()
                    .put("msg_type", "text")
                    .put("content", JSONObject().put("text", text))
                if (channel.secret.isNotBlank()) {
                    val timestamp = (System.currentTimeMillis() / 1000).toString()
                    payload.put("timestamp", timestamp)
                    payload.put("sign", feishuSign(timestamp, channel.secret))
                }
                payload
            }
        }
    }

    private fun buildTargetUrl(channel: WebhookChannelConfig): String {
        if (channel.channel != "dingtalk" || channel.secret.isBlank()) {
            return channel.webhookUrl
        }
        val timestamp = System.currentTimeMillis().toString()
        val sign = hmacBase64("$timestamp\n${channel.secret}", channel.secret)
        val separator = if (channel.webhookUrl.contains("?")) "&" else "?"
        return channel.webhookUrl + separator +
            "timestamp=$timestamp&sign=${URLEncoder.encode(sign, "UTF-8")}"
    }

    private fun feishuSign(timestamp: String, secret: String): String {
        return hmacBase64("", "$timestamp\n$secret")
    }

    private fun hmacBase64(content: String, secret: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        val bytes = mac.doFinal(content.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    private fun readConfig(): ForwardConfig {
        val prefs = context.getSharedPreferences(SmsConfig.PREFS_NAME, Context.MODE_PRIVATE)
        return ForwardConfig(
            phoneNumber = prefs.getString(SmsConfig.KEY_PHONE_NUMBER, "").orEmpty(),
            deviceName = prefs.getString(SmsConfig.KEY_DEVICE_NAME, "").orEmpty(),
            channels = readChannelConfigs(prefs),
            simCards = readSimConfigs(prefs.getString(SmsConfig.KEY_SIM_CONFIGS, "[]").orEmpty()),
        )
    }

    private fun readChannelConfigs(
        prefs: android.content.SharedPreferences,
    ): List<WebhookChannelConfig> {
        val array = JSONArray(prefs.getString(SmsConfig.KEY_CHANNEL_CONFIGS, "[]").orEmpty().ifBlank { "[]" })
        val channels = List(array.length()) { index ->
            val item = array.getJSONObject(index)
            WebhookChannelConfig(
                channel = item.optString("channel", "feishu"),
                enabled = item.optBoolean("enabled", false),
                webhookUrl = item.optString("webhookUrl"),
                secret = item.optString("secret"),
            )
        }
        if (channels.isNotEmpty()) {
            return channels
        }
        val legacyWebhook = prefs.getString(SmsConfig.KEY_WEBHOOK_URL, "").orEmpty()
        return listOf(
            WebhookChannelConfig(
                channel = prefs.getString(SmsConfig.KEY_CHANNEL, "feishu").orEmpty().ifBlank { "feishu" },
                enabled = legacyWebhook.isNotBlank(),
                webhookUrl = legacyWebhook,
                secret = prefs.getString(SmsConfig.KEY_SECRET, "").orEmpty(),
            ),
        )
    }

    private fun readSimConfigs(raw: String): List<SimForwardConfig> {
        val array = org.json.JSONArray(raw.ifBlank { "[]" })
        return List(array.length()) { index ->
            val item = array.getJSONObject(index)
            SimForwardConfig(
                key = item.optString("key"),
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
        }
    }

    private fun String.maskSecret(): String {
        return replace(Regex("(?i)(secret|sign|access_token)=([^&]+)"), "$1=***")
    }
}

data class ForwardConfig(
    val phoneNumber: String,
    val deviceName: String,
    val channels: List<WebhookChannelConfig>,
    val simCards: List<SimForwardConfig>,
) {
    fun findSimConfig(sms: SmsMessage): SimForwardConfig? {
        return simCards.firstOrNull { config ->
            config.subscriptionId >= 0 && config.subscriptionId == sms.subscriptionId
        } ?: simCards.firstOrNull { config ->
            config.simSlot >= 0 && config.simSlot == sms.simSlot
        } ?: simCards.firstOrNull { config ->
            sms.simDisplayName != null && config.displayName == sms.simDisplayName
        }
    }

    fun defaultPhoneNumber(): String {
        return simCards.firstOrNull { it.forwardEnabled && it.phoneNumber.isNotBlank() }?.phoneNumber
            ?: phoneNumber
    }

    fun enabledChannels(): List<WebhookChannelConfig> {
        return channels.filter { it.enabled && it.webhookUrl.isNotBlank() }
    }
}

data class WebhookChannelConfig(
    val channel: String,
    val enabled: Boolean,
    val webhookUrl: String,
    val secret: String,
) {
    val label: String
        get() = when (channel) {
            "dingtalk" -> "钉钉"
            "generic" -> "通用"
            else -> "飞书"
        }
}

data class SimForwardConfig(
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
        }
}
