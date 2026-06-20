import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const SmsForwardApp());
}

class SmsForwardApp extends StatelessWidget {
  const SmsForwardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '短信转发助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00897B),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.white,
          titleTextStyle: TextStyle(
            color: Color(0xFF151B1A),
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFE3E8E5)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8FAF9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFDCE4E0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFDCE4E0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF00897B), width: 1.4),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const _method = MethodChannel('sms_forward/methods');
  static const _events = EventChannel('sms_forward/events');

  final _deviceController = TextEditingController();
  final Map<String, TextEditingController> _simPhoneControllers = {};
  final Map<ForwardChannel, TextEditingController> _webhookControllers = {};
  final Map<ForwardChannel, TextEditingController> _secretControllers = {};

  StreamSubscription<dynamic>? _smsSubscription;
  bool _hasSmsPermission = false;
  bool _isRunning = false;
  bool _saving = false;
  bool _testing = false;
  List<SimCardInfo> _simCards = [];
  List<SentSmsRecord> _sentSmsRecords = [];
  Map<ForwardChannel, ForwardChannelConfig> _forwardChannels = {
    for (final channel in ForwardChannel.values)
      channel: ForwardChannelConfig(channel: channel),
  };
  final List<SmsRecord> _records = <SmsRecord>[];
  final List<String> _logs = <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
    _smsSubscription = _events.receiveBroadcastStream().listen(_handleEvent);
  }

  Future<void> _bootstrap() async {
    await Future.wait(<Future<void>>[
      _loadConfig(),
      _loadRecords(),
      _loadSentSmsRecords(),
      _refreshPermission(),
      _refreshServiceState(),
    ]);
    unawaited(_checkKeepAliveNotifications());
  }

  Future<void> _loadConfig() async {
    final result = await _method.invokeMapMethod<String, dynamic>('getConfig');
    if (!mounted || result == null) {
      return;
    }
    setState(() {
      _deviceController.text = result['deviceName'] as String? ?? '';
    });
    _setForwardChannels(result);
    _setSimCards(result['simCards'] as List<dynamic>? ?? const []);
  }

  Future<void> _loadRecords() async {
    final records = await _method.invokeListMethod<dynamic>('getRecords');
    if (!mounted || records == null) {
      return;
    }
    setState(() {
      _records
        ..clear()
        ..addAll(
          records
              .whereType<Map<dynamic, dynamic>>()
              .map(SmsRecord.fromMap)
              .take(100),
        );
    });
  }

  Future<void> _loadSentSmsRecords() async {
    final records = await _method.invokeListMethod<dynamic>(
      'getSentSmsRecords',
    );
    if (!mounted || records == null) {
      return;
    }
    setState(() {
      _sentSmsRecords = records
          .whereType<Map<dynamic, dynamic>>()
          .map(SentSmsRecord.fromMap)
          .toList();
    });
  }

  Future<void> _refreshKeepAliveState() async {
    if (!mounted) {
      return;
    }
    setState(() {});
    await _loadSentSmsRecords();
    unawaited(_checkKeepAliveNotifications());
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _checkKeepAliveNotifications() async {
    try {
      await _method.invokeMethod<int>('checkKeepAliveNotifications');
    } on PlatformException catch (error) {
      _addLog('保号通知检查失败：${error.message ?? error.code}');
    }
  }

  Future<void> _refreshPermission() async {
    final granted =
        await _method.invokeMethod<bool>('hasSmsPermission') ?? false;
    if (mounted) {
      setState(() => _hasSmsPermission = granted);
    }
  }

  Future<void> _refreshServiceState() async {
    final running =
        await _method.invokeMethod<bool>('isServiceRunning') ?? false;
    if (mounted) {
      setState(() => _isRunning = running);
    }
  }

  Future<void> _requestPermission() async {
    final granted =
        await _method.invokeMethod<bool>('requestSmsPermission') ?? false;
    if (mounted) {
      setState(() => _hasSmsPermission = granted);
      _addLog(granted ? '短信权限已授权' : '短信权限未授权');
    }
    if (granted) {
      await _refreshKeepAliveState();
    }
  }

  Future<void> _requestBatteryWhitelist() async {
    await _method.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    _addLog('已打开电池优化设置');
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    try {
      await _method.invokeMethod<void>('saveConfig', _configPayload());
      await _refreshSimCards();
      await _loadSentSmsRecords();
      unawaited(_checkKeepAliveNotifications());
      _addLog('配置已保存');
    } on PlatformException catch (error) {
      _addLog('配置保存失败：${error.message ?? error.code}');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _testForward() async {
    await _saveConfig();
    setState(() => _testing = true);
    try {
      final ok = await _method.invokeMethod<bool>('testForward') ?? false;
      _addLog(ok ? '测试消息发送成功' : '测试消息发送失败');
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _startService() async {
    await _saveConfig();
    if (!_hasSmsPermission) {
      await _requestPermission();
    }
    final ok = await _method.invokeMethod<bool>('startService') ?? false;
    if (mounted) {
      setState(() => _isRunning = ok);
      _addLog(ok ? '监听服务已启动' : '监听服务启动失败，请检查权限');
    }
  }

  Future<void> _stopService() async {
    await _method.invokeMethod<void>('stopService');
    if (mounted) {
      setState(() => _isRunning = false);
      _addLog('监听服务已停止');
    }
  }

  Map<String, Object?> _configPayload() {
    return <String, Object?>{
      'phoneNumber': _simCards
          .map((sim) => _simPhoneControllers[sim.key]?.text.trim() ?? '')
          .firstWhere((phone) => phone.isNotEmpty, orElse: () => ''),
      'deviceName': _deviceController.text.trim(),
      'channels': ForwardChannel.values.map(_channelPayload).toList(),
      'simCards': _simCards.map(_simPayload).toList(),
    };
  }

  Map<String, Object?> _channelPayload(ForwardChannel channel) {
    final config =
        _forwardChannels[channel] ?? ForwardChannelConfig(channel: channel);
    return config
        .copyWith(
          webhookUrl: _webhookControllers[channel]?.text.trim(),
          secret: _secretControllers[channel]?.text.trim(),
        )
        .toPayload();
  }

  Map<String, Object?> _simPayload(SimCardInfo sim) {
    return sim
        .copyWith(phoneNumber: _simPhoneControllers[sim.key]?.text.trim())
        .toPayload();
  }

  Future<void> _refreshSimCards() async {
    final cards = await _method.invokeListMethod<dynamic>('getSimCards');
    if (!mounted || cards == null) {
      return;
    }
    _setSimCards(cards);
  }

  void _setSimCards(List<dynamic> rawCards) {
    final cards = rawCards
        .whereType<Map<dynamic, dynamic>>()
        .map(SimCardInfo.fromMap)
        .toList();
    setState(() {
      _simCards = cards;
      for (final sim in cards) {
        final controller = _simPhoneControllers.putIfAbsent(
          sim.key,
          () => TextEditingController(),
        );
        controller.text = sim.phoneNumber;
      }
      final activeKeys = cards.map((sim) => sim.key).toSet();
      final staleKeys = _simPhoneControllers.keys
          .where((key) => !activeKeys.contains(key))
          .toList();
      for (final key in staleKeys) {
        _simPhoneControllers.remove(key)?.dispose();
      }
    });
  }

  void _setForwardChannels(Map<String, dynamic> result) {
    final rawChannels = result['channels'] as List<dynamic>? ?? const [];
    final next = {
      for (final channel in ForwardChannel.values)
        channel: ForwardChannelConfig(channel: channel),
    };
    if (rawChannels.isEmpty) {
      final legacyChannel = ForwardChannel.fromValue(
        result['channel'] as String? ?? ForwardChannel.feishu.value,
      );
      final legacyWebhook = result['webhookUrl'] as String? ?? '';
      final legacySecret = result['secret'] as String? ?? '';
      next[legacyChannel] = ForwardChannelConfig(
        channel: legacyChannel,
        enabled: legacyWebhook.trim().isNotEmpty,
        webhookUrl: legacyWebhook,
        secret: legacySecret,
      );
    } else {
      for (final item in rawChannels.whereType<Map<dynamic, dynamic>>()) {
        final config = ForwardChannelConfig.fromMap(item);
        next[config.channel] = config;
      }
    }
    setState(() {
      _forwardChannels = next;
      for (final channel in ForwardChannel.values) {
        final config = next[channel]!;
        _webhookControllers
                .putIfAbsent(channel, () => TextEditingController())
                .text =
            config.webhookUrl;
        _secretControllers
                .putIfAbsent(channel, () => TextEditingController())
                .text =
            config.secret;
      }
    });
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) {
      return;
    }
    final type = event['event'] as String? ?? 'sms';
    if (type == 'log') {
      _addLog(event['message'] as String? ?? '收到服务日志');
      return;
    }
    final record = SmsRecord.fromMap(event);
    setState(() {
      _records.removeWhere((item) => item.id == record.id);
      _records.insert(0, record);
      if (_records.length > 100) {
        _records.removeLast();
      }
    });
    _addLog('${record.forwardStatusLabel}: ${record.sender}');
  }

  void _addLog(String message) {
    if (!mounted) {
      return;
    }
    final time = TimeOfDay.now().format(context);
    setState(() {
      _logs.insert(0, '$time  $message');
      if (_logs.length > 80) {
        _logs.removeLast();
      }
    });
  }

  @override
  void dispose() {
    _smsSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in _simPhoneControllers.values) {
      controller.dispose();
    }
    _deviceController.dispose();
    for (final controller in _webhookControllers.values) {
      controller.dispose();
    }
    for (final controller in _secretControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _refreshKeepAliveState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('短信转发助手')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          children: [
            _StatusPanel(
              isRunning: _isRunning,
              deviceName: _deviceController.text,
              simPhoneSummary: _configuredPhoneSummary,
              hasConfiguredSimPhone: _hasConfiguredSimPhone,
              onOpenDevice: _openDevicePage,
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 58,
              child: FilledButton.icon(
                onPressed: _isRunning ? _stopService : _startService,
                icon: Icon(
                  _isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  size: 24,
                ),
                label: Text(_isRunning ? '停止监听' : '启动监听'),
                style: FilledButton.styleFrom(
                  backgroundColor: _isRunning
                      ? Colors.redAccent
                      : const Color(0xFF008D7F),
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            if (_keepAliveSims.isNotEmpty) ...[
              const SizedBox(height: 18),
              _KeepAlivePanel(
                items: _keepAliveSims
                    .map(
                      (sim) => _KeepAliveReminder(
                        sim: sim,
                        record: _latestSentRecordFor(sim),
                      ),
                    )
                    .toList(),
                onRefresh: _refreshKeepAliveState,
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _QuickStatusCard(
                    icon: Icons.shield_outlined,
                    title: '短信权限',
                    value: _hasSmsPermission ? '已授权' : '未授权',
                    healthy: _hasSmsPermission,
                    onTap: _requestPermission,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _QuickStatusCard(
                    icon: Icons.battery_charging_full_outlined,
                    title: '电池优化',
                    value: '去设置',
                    healthy: true,
                    onTap: _requestBatteryWhitelist,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '功能设置',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: const Color(0xFF6B7471),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            _SettingsList(
              children: [
                _HomeEntryTile(
                  icon: Icons.phone_android_outlined,
                  title: '设备信息',
                  subtitle: '查看设备与系统信息',
                  onTap: _openDevicePage,
                ),
                _HomeEntryTile(
                  icon: Icons.hub_outlined,
                  title: '转发通道',
                  subtitle: '管理转发方式与接收地址',
                  onTap: _openForwardPage,
                ),
                _HomeEntryTile(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: '短信记录',
                  subtitle: '查看短信收发记录',
                  onTap: _openRecordsPage,
                ),
                _HomeEntryTile(
                  icon: Icons.receipt_long_outlined,
                  title: '转发日志',
                  subtitle: '查看转发任务执行日志',
                  showDivider: false,
                  onTap: _openLogsPage,
                ),
              ],
            ),
            const SizedBox(height: 34),
            Text(
              '所有功能仅在本机运行，数据安全有保障\n版本：1.0.1',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF717B78),
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _configuredPhoneSummary {
    final phones = _simCards
        .map((sim) {
          final controllerText = _simPhoneControllers[sim.key]?.text.trim();
          if (controllerText != null && controllerText.isNotEmpty) {
            return controllerText;
          }
          return sim.phoneNumber.trim();
        })
        .where((phone) => phone.isNotEmpty)
        .toSet()
        .toList();
    if (phones.isEmpty) {
      return '未设置';
    }
    return phones.join('、');
  }

  bool get _hasConfiguredSimPhone => _configuredPhoneSummary != '未设置';

  List<SimCardInfo> get _keepAliveSims {
    return _simCards.where((sim) => sim.keepAliveEnabled).toList();
  }

  List<ForwardChannelConfig> get _availableKeepAliveChannels {
    return ForwardChannel.values
        .map((channel) {
          final config = _forwardChannels[channel];
          if (config == null) {
            return null;
          }
          return config.copyWith(
            webhookUrl:
                _webhookControllers[channel]?.text.trim() ?? config.webhookUrl,
            secret: _secretControllers[channel]?.text.trim() ?? config.secret,
          );
        })
        .whereType<ForwardChannelConfig>()
        .where(
          (config) => config.enabled && config.webhookUrl.trim().isNotEmpty,
        )
        .toList();
  }

  SentSmsRecord? _latestSentRecordFor(SimCardInfo sim) {
    for (final record in _sentSmsRecords) {
      final sameSubscription =
          sim.subscriptionId >= 0 &&
          record.subscriptionId == sim.subscriptionId;
      final sameSlot = sim.simSlot >= 0 && record.simSlot == sim.simSlot;
      final sameName =
          sim.displayName.trim().isNotEmpty &&
          sim.displayName.trim() == record.simDisplayName.trim();
      if (sameSubscription || sameSlot || sameName) {
        return record;
      }
    }
    return null;
  }

  Future<void> _testKeepAliveNotification(SimCardInfo sim) async {
    final message = _keepAliveTestValidationMessage(sim);
    if (message != null) {
      _showInfoDialog('无法测试发送', message);
      return;
    }
    await _saveConfig();
    try {
      final result = await _method.invokeMapMethod<String, dynamic>(
        'testKeepAliveNotification',
        <String, Object?>{'simKey': sim.key},
      );
      final ok = result?['ok'] as bool? ?? false;
      final resultMessage =
          result?['message'] as String? ?? (ok ? '测试消息发送成功' : '测试消息发送失败');
      _showInfoDialog(ok ? '测试发送成功' : '无法测试发送', resultMessage);
    } on PlatformException catch (error) {
      _showInfoDialog('无法测试发送', error.message ?? error.code);
    }
  }

  String? _keepAliveTestValidationMessage(SimCardInfo sim) {
    if (!sim.keepAliveEnabled) {
      return '请先启用该 SIM 的保号提示';
    }
    if (sim.keepAliveNotifyThresholdDays <= 0) {
      return '请填写大于 0 的通知阈值';
    }
    if (sim.keepAliveNotifyChannels.isEmpty) {
      return '请选择至少一个保号通知通道';
    }
    final available = _availableKeepAliveChannels
        .map((config) => config.channel)
        .toSet();
    final missing = sim.keepAliveNotifyChannels
        .where((channel) => !available.contains(channel))
        .toList();
    if (missing.isNotEmpty) {
      return '选择的保号通知通道尚未启用或未配置 Webhook';
    }
    return null;
  }

  void _showInfoDialog(String title, String message) {
    if (!mounted) {
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _openDevicePage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => StatefulBuilder(
          builder: (context, pageSetState) => _DetailPage(
            title: '设备信息',
            actions: [
              IconButton(
                onPressed: () async {
                  await _saveConfig();
                  pageSetState(() {});
                },
                tooltip: '保存配置',
                icon: const Icon(Icons.save_outlined),
              ),
            ],
            child: Column(
              children: [
                TextField(
                  controller: _deviceController,
                  decoration: const InputDecoration(
                    labelText: '设备名称',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  onChanged: (_) {
                    setState(() {});
                    pageSetState(() {});
                  },
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await _refreshSimCards();
                      pageSetState(() {});
                    },
                    icon: const Icon(Icons.sim_card_outlined),
                    label: const Text('获取当前SIM卡'),
                  ),
                ),
                const SizedBox(height: 12),
                if (_simCards.isEmpty)
                  const _EmptyState(text: '未读取到 SIM 卡信息，请先授权电话状态权限')
                else
                  Column(
                    children: _simCards
                        .map(
                          (sim) => _SimCardEditor(
                            sim: sim,
                            phoneController: _simPhoneControllers[sim.key]!,
                            availableChannels: _availableKeepAliveChannels,
                            onTestSend: () => _testKeepAliveNotification(sim),
                            onChanged: (nextSim) {
                              setState(() {
                                final index = _simCards.indexWhere(
                                  (item) => item.key == sim.key,
                                );
                                if (index >= 0) {
                                  _simCards[index] = nextSim;
                                }
                              });
                              pageSetState(() {});
                            },
                          ),
                        )
                        .toList(),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving
                        ? null
                        : () async {
                            await _saveConfig();
                            pageSetState(() {});
                          },
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving ? '保存中' : '保存配置'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openForwardPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => StatefulBuilder(
          builder: (context, pageSetState) => _DetailPage(
            title: '转发通道',
            child: Column(
              children: [
                ...ForwardChannel.values.map(
                  (channel) => _ForwardChannelEditor(
                    config: _forwardChannels[channel]!,
                    webhookController: _webhookControllers[channel]!,
                    secretController: _secretControllers[channel]!,
                    onEnabledChanged: (enabled) {
                      setState(() {
                        _forwardChannels[channel] = _forwardChannels[channel]!
                            .copyWith(enabled: enabled);
                      });
                      pageSetState(() {});
                    },
                    onChanged: () {
                      setState(() {
                        _forwardChannels[channel] = _forwardChannels[channel]!
                            .copyWith(
                              webhookUrl: _webhookControllers[channel]?.text
                                  .trim(),
                              secret: _secretControllers[channel]?.text.trim(),
                            );
                      });
                      pageSetState(() {});
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _saving
                            ? null
                            : () async {
                                await _saveConfig();
                                pageSetState(() {});
                              },
                        icon: const Icon(Icons.save_outlined),
                        label: Text(_saving ? '保存中' : '保存配置'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testing
                            ? null
                            : () async {
                                await _testForward();
                                pageSetState(() {});
                              },
                        icon: const Icon(Icons.send_outlined),
                        label: Text(_testing ? '发送中' : '测试发送'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openRecordsPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _DetailPage(
          title: '短信记录',
          actions: [
            IconButton(
              onPressed: _loadRecords,
              tooltip: '刷新记录',
              icon: const Icon(Icons.refresh),
            ),
          ],
          child: _records.isEmpty
              ? const _EmptyState(text: '还没有收到短信事件')
              : Column(
                  children: _records
                      .take(100)
                      .map((record) => _SmsTile(record: record))
                      .toList(),
                ),
        ),
      ),
    );
  }

  void _openLogsPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _DetailPage(
          title: '转发日志',
          child: _logs.isEmpty
              ? const _EmptyState(text: '服务日志会显示在这里')
              : Column(
                  children: _logs
                      .map(
                        (log) => Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(log),
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.isRunning,
    required this.deviceName,
    required this.simPhoneSummary,
    required this.hasConfiguredSimPhone,
    required this.onOpenDevice,
  });

  final bool isRunning;
  final String deviceName;
  final String simPhoneSummary;
  final bool hasConfiguredSimPhone;
  final VoidCallback onOpenDevice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = isRunning
        ? const Color(0xFF00897B)
        : const Color(0xFF7B8582);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF0FAF8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFCDE7E2)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 66,
                  height: 66,
                  decoration: const BoxDecoration(
                    color: Color(0xFFDDF2EF),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chat_bubble_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRunning ? '监听中' : '未监听',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: statusColor,
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isRunning ? '服务运行正常，正在监听短信' : '服务未运行，启动后开始监听短信',
                        softWrap: true,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF4F5956),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFCFE2DE)),
            const SizedBox(height: 8),

            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    _StatusInfoItem(
                      icon: Icons.badge_outlined,
                      label: '设备名称：',
                      value: deviceName.trim().isEmpty
                          ? '未设置'
                          : deviceName.trim(),
                      healthy: deviceName.trim().isNotEmpty,
                    ),
                    const SizedBox(height: 6),
                    _StatusInfoItem(
                      icon: Icons.sim_card_outlined,
                      label: 'SIM 卡：',
                      value: simPhoneSummary,
                      healthy: hasConfiguredSimPhone,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeepAlivePanel extends StatelessWidget {
  const _KeepAlivePanel({required this.items, required this.onRefresh});

  final List<_KeepAliveReminder> items;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBF1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF1DCA3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.notifications_active_outlined,
                  color: Color(0xFF9B6A00),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '保号提醒',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF4F3A05),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onRefresh,
                  tooltip: '刷新已发送短信',
                  icon: const Icon(Icons.refresh, color: Color(0xFF725000)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ...items.map((item) => _KeepAliveReminderTile(item: item)),
          ],
        ),
      ),
    );
  }
}

class _KeepAliveReminderTile extends StatelessWidget {
  const _KeepAliveReminderTile({required this.item});

  final _KeepAliveReminder item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = item.record;
    final headline = record == null ? '未发现发送记录' : item.counterText;
    final headlineColor = record == null || item.isOverdue
        ? const Color(0xFFC62828)
        : const Color(0xFF00897B);
    final detail = record == null
        ? '请尽快用 ${item.sim.shortLabel} 发送一条短信'
        : '${record.timeText} · ${record.body}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            record == null ? Icons.warning_amber_rounded : Icons.sim_card,
            color: headlineColor,
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item.sim.shortLabel} · $headline',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: headlineColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF5F5440),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KeepAliveReminder {
  const _KeepAliveReminder({required this.sim, required this.record});

  final SimCardInfo sim;
  final SentSmsRecord? record;

  bool get isOverdue {
    if (record == null || sim.keepAliveMode != KeepAliveMode.countdown) {
      return false;
    }
    return _daysElapsed >= sim.keepAliveDays;
  }

  String get counterText {
    if (record == null) {
      return '未发现发送记录';
    }
    if (sim.keepAliveMode == KeepAliveMode.elapsed) {
      return '累计${_daysElapsed + 1}天';
    }
    final remaining = sim.keepAliveDays - _daysElapsed;
    if (remaining >= 0) {
      return '倒计$remaining天';
    }
    return '已超期${remaining.abs()}天';
  }

  int get _daysElapsed {
    final sentAt = record?.sentAt;
    if (sentAt == null) {
      return 0;
    }
    final today = DateUtils.dateOnly(DateTime.now());
    final sentDay = DateUtils.dateOnly(sentAt);
    return today.difference(sentDay).inDays.clamp(0, 99999);
  }
}

class _StatusInfoItem extends StatelessWidget {
  const _StatusInfoItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.healthy,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool healthy;

  @override
  Widget build(BuildContext context) {
    final valueColor = healthy
        ? const Color(0xFF00897B)
        : const Color(0xFFC62828);
    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, color: const Color(0xFF00897B), size: 24),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.left,
            text: TextSpan(
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF3D4744),
                fontSize: 15,
              ),
              children: [
                TextSpan(text: label),
                TextSpan(
                  text: value,
                  style: TextStyle(
                    color: valueColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _QuickStatusCard extends StatelessWidget {
  const _QuickStatusCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.healthy,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool healthy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final valueColor = healthy
        ? const Color(0xFF00897B)
        : const Color(0xFFC62828);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE1E5E8)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: const Color(0xFF00897B), size: 28),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: valueColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: Color(0xFF7B8582),
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsList extends StatelessWidget {
  const _SettingsList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE1E5E8)),
      ),
      child: Column(children: children),
    );
  }
}

class _HomeEntryTile extends StatelessWidget {
  const _HomeEntryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showDivider = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          // contentPadding: const EdgeInsets.symmetric(
          //   horizontal: 16,
          //   vertical: 0,
          // ),
          leading: Icon(icon, color: const Color(0xFF00897B), size: 26),
          title: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF151B1A),
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF697370)),
          ),
          trailing: const Icon(
            Icons.chevron_right,
            color: Color(0xFF7B8582),
            size: 20,
          ),
          onTap: onTap,
        ),
        if (showDivider)
          const Divider(height: 0.1, indent: 0, color: Color(0xFFE1E5E8)),
      ],
    );
  }
}

class _DetailPage extends StatelessWidget {
  const _DetailPage({required this.title, required this.child, this.actions});

  final String title;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [child]),
      ),
    );
  }
}

class _SmsTile extends StatelessWidget {
  const _SmsTile({required this.record});

  final SmsRecord record;

  @override
  Widget build(BuildContext context) {
    final statusColor = record.forwardOk
        ? const Color(0xFF00897B)
        : const Color(0xFFD32F2F);
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: record.forwardOk
            ? const Color(0xFFE3F4F0)
            : const Color(0xFFFDECEC),
        child: Icon(Icons.sms_outlined, color: statusColor, size: 20),
      ),
      title: Text(
        record.sender,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${record.body}\n${record.timeText} · ${record.simLabel}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(
            record.forwardStatusLabel,
            style: TextStyle(color: statusColor, fontWeight: FontWeight.w600),
          ),
          const Icon(Icons.chevron_right, color: Color(0xFF7B8582)),
        ],
      ),
      onTap: () {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(record.sender),
            content: SingleChildScrollView(
              child: Text(
                '${record.timeText}\n${record.simLabel}\n\n${record.body}',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      },
    );
    return tile;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SimCardEditor extends StatelessWidget {
  const _SimCardEditor({
    required this.sim,
    required this.phoneController,
    required this.availableChannels,
    required this.onTestSend,
    required this.onChanged,
  });

  final SimCardInfo sim;
  final TextEditingController phoneController;
  final List<ForwardChannelConfig> availableChannels;
  final VoidCallback onTestSend;
  final ValueChanged<SimCardInfo> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAF9),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE1E6E3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.sim_card_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sim.label,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Switch(
                    value: sim.forwardEnabled,
                    onChanged: (enabled) {
                      onChanged(sim.copyWith(forwardEnabled: enabled));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: '该SIM对应手机号',
                  prefixIcon: Icon(Icons.phone_android),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                sim.forwardEnabled ? '该号码收到短信时会转发' : '该号码收到短信时不会转发',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: Color(0xFFE1E6E3)),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.notifications_active_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('保号提示', style: theme.textTheme.titleSmall),
                  ),
                  Switch(
                    value: sim.keepAliveEnabled,
                    onChanged: (enabled) {
                      onChanged(sim.copyWith(keepAliveEnabled: enabled));
                    },
                  ),
                ],
              ),
              if (sim.keepAliveEnabled) ...[
                const SizedBox(height: 8),
                SegmentedButton<KeepAliveMode>(
                  segments: const [
                    ButtonSegment<KeepAliveMode>(
                      value: KeepAliveMode.countdown,
                      icon: Icon(Icons.hourglass_bottom_outlined),
                      label: Text('倒计天数'),
                    ),
                    ButtonSegment<KeepAliveMode>(
                      value: KeepAliveMode.elapsed,
                      icon: Icon(Icons.calendar_month_outlined),
                      label: Text('累计天数'),
                    ),
                  ],
                  selected: {sim.keepAliveMode},
                  onSelectionChanged: (selection) {
                    onChanged(sim.copyWith(keepAliveMode: selection.first));
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  initialValue: sim.keepAliveDays.toString(),
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: sim.keepAliveMode == KeepAliveMode.countdown
                        ? '倒计提醒天数'
                        : '累计提醒参考天数',
                    prefixIcon: const Icon(Icons.timer_outlined),
                  ),
                  onChanged: (value) {
                    final days = int.tryParse(value.trim());
                    if (days == null || days <= 0) {
                      return;
                    }
                    onChanged(sim.copyWith(keepAliveDays: days));
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  sim.keepAliveMode == KeepAliveMode.countdown
                      ? '首页会从最近发送日开始倒计'
                      : '首页会从最近发送日开始累计',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Text(
                  '保号通知通道',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                if (availableChannels.isEmpty)
                  Text(
                    '暂无可用转发通道，请先在转发通道中启用 Webhook',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFC62828),
                    ),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: availableChannels.map((config) {
                      final selected = sim.keepAliveNotifyChannels.contains(
                        config.channel,
                      );
                      return FilterChip(
                        avatar: Icon(config.channel.icon, size: 18),
                        label: Text(config.channel.label),
                        selected: selected,
                        onSelected: (enabled) {
                          final channels = sim.keepAliveNotifyChannels.toSet();
                          if (enabled) {
                            channels.add(config.channel);
                          } else {
                            channels.remove(config.channel);
                          }
                          onChanged(
                            sim.copyWith(
                              keepAliveNotifyChannels: channels.toList(),
                            ),
                          );
                        },
                      );
                    }).toList(),
                  ),
                const SizedBox(height: 10),
                TextFormField(
                  initialValue: sim.keepAliveNotifyThresholdDays.toString(),
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '通知阈值',
                    prefixIcon: const Icon(Icons.notification_important),
                    helperText: sim.keepAliveMode == KeepAliveMode.countdown
                        ? '倒计天数小于等于该值时通知'
                        : '累计天数大于等于该值时通知',
                  ),
                  onChanged: (value) {
                    final days = int.tryParse(value.trim());
                    if (days == null || days <= 0) {
                      return;
                    }
                    onChanged(sim.copyWith(keepAliveNotifyThresholdDays: days));
                  },
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: onTestSend,
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('测试发送'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ForwardChannelEditor extends StatelessWidget {
  const _ForwardChannelEditor({
    required this.config,
    required this.webhookController,
    required this.secretController,
    required this.onEnabledChanged,
    required this.onChanged,
  });

  final ForwardChannelConfig config;
  final TextEditingController webhookController;
  final TextEditingController secretController;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE1E6E3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(config.channel.icon),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      config.channel.label,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Switch(value: config.enabled, onChanged: onEnabledChanged),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: webhookController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: '${config.channel.label} Webhook 地址',
                  prefixIcon: const Icon(Icons.link),
                ),
                onChanged: (_) => onChanged(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: secretController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '加签密钥（可选）',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
                onChanged: (_) => onChanged(),
              ),
              const SizedBox(height: 6),
              Text(
                config.enabled ? '该通道已启用' : '该通道未启用',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum ForwardChannel {
  feishu('feishu'),
  dingtalk('dingtalk'),
  generic('generic');

  const ForwardChannel(this.value);

  final String value;
  String get label {
    return switch (this) {
      ForwardChannel.feishu => '飞书',
      ForwardChannel.dingtalk => '钉钉',
      ForwardChannel.generic => '通用',
    };
  }

  IconData get icon {
    return switch (this) {
      ForwardChannel.feishu => Icons.forum_outlined,
      ForwardChannel.dingtalk => Icons.chat_bubble_outline,
      ForwardChannel.generic => Icons.webhook,
    };
  }

  static ForwardChannel fromValue(String value) {
    return ForwardChannel.values.firstWhere(
      (item) => item.value == value,
      orElse: () => ForwardChannel.feishu,
    );
  }
}

enum KeepAliveMode {
  countdown('countdown'),
  elapsed('elapsed');

  const KeepAliveMode(this.value);

  final String value;

  static KeepAliveMode fromValue(String value) {
    return KeepAliveMode.values.firstWhere(
      (item) => item.value == value,
      orElse: () => KeepAliveMode.countdown,
    );
  }
}

class ForwardChannelConfig {
  const ForwardChannelConfig({
    required this.channel,
    this.enabled = false,
    this.webhookUrl = '',
    this.secret = '',
  });

  final ForwardChannel channel;
  final bool enabled;
  final String webhookUrl;
  final String secret;

  ForwardChannelConfig copyWith({
    bool? enabled,
    String? webhookUrl,
    String? secret,
  }) {
    return ForwardChannelConfig(
      channel: channel,
      enabled: enabled ?? this.enabled,
      webhookUrl: webhookUrl ?? this.webhookUrl,
      secret: secret ?? this.secret,
    );
  }

  Map<String, Object?> toPayload() {
    return <String, Object?>{
      'channel': channel.value,
      'enabled': enabled,
      'webhookUrl': webhookUrl,
      'secret': secret,
    };
  }

  factory ForwardChannelConfig.fromMap(Map<dynamic, dynamic> map) {
    return ForwardChannelConfig(
      channel: ForwardChannel.fromValue(
        map['channel'] as String? ?? ForwardChannel.feishu.value,
      ),
      enabled: map['enabled'] as bool? ?? false,
      webhookUrl: map['webhookUrl'] as String? ?? '',
      secret: map['secret'] as String? ?? '',
    );
  }
}

class SimCardInfo {
  const SimCardInfo({
    required this.key,
    required this.subscriptionId,
    required this.simSlot,
    required this.displayName,
    required this.carrierName,
    required this.phoneNumber,
    required this.forwardEnabled,
    required this.keepAliveEnabled,
    required this.keepAliveMode,
    required this.keepAliveDays,
    required this.keepAliveNotifyThresholdDays,
    required this.keepAliveNotifyChannels,
  });

  final String key;
  final int subscriptionId;
  final int simSlot;
  final String displayName;
  final String carrierName;
  final String phoneNumber;
  final bool forwardEnabled;
  final bool keepAliveEnabled;
  final KeepAliveMode keepAliveMode;
  final int keepAliveDays;
  final int keepAliveNotifyThresholdDays;
  final List<ForwardChannel> keepAliveNotifyChannels;

  String get shortLabel {
    if (simSlot >= 0) {
      return 'SIM${simSlot + 1}';
    }
    if (displayName.trim().isNotEmpty) {
      return displayName.trim();
    }
    return '未知SIM';
  }

  String get label {
    final parts = <String>[
      if (displayName.trim().isNotEmpty) displayName.trim(),
      if (carrierName.trim().isNotEmpty) carrierName.trim(),
      if (simSlot >= 0) 'SIM${simSlot + 1}',
      if (subscriptionId >= 0) 'subId=$subscriptionId',
    ];
    final label = parts.toSet().join(' / ');
    return label.isEmpty ? '未知SIM' : label;
  }

  SimCardInfo copyWith({
    String? phoneNumber,
    bool? forwardEnabled,
    bool? keepAliveEnabled,
    KeepAliveMode? keepAliveMode,
    int? keepAliveDays,
    int? keepAliveNotifyThresholdDays,
    List<ForwardChannel>? keepAliveNotifyChannels,
  }) {
    return SimCardInfo(
      key: key,
      subscriptionId: subscriptionId,
      simSlot: simSlot,
      displayName: displayName,
      carrierName: carrierName,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      forwardEnabled: forwardEnabled ?? this.forwardEnabled,
      keepAliveEnabled: keepAliveEnabled ?? this.keepAliveEnabled,
      keepAliveMode: keepAliveMode ?? this.keepAliveMode,
      keepAliveDays: keepAliveDays ?? this.keepAliveDays,
      keepAliveNotifyThresholdDays:
          keepAliveNotifyThresholdDays ?? this.keepAliveNotifyThresholdDays,
      keepAliveNotifyChannels:
          keepAliveNotifyChannels ?? this.keepAliveNotifyChannels,
    );
  }

  Map<String, Object?> toPayload() {
    return <String, Object?>{
      'key': key,
      'subscriptionId': subscriptionId,
      'simSlot': simSlot,
      'displayName': displayName,
      'carrierName': carrierName,
      'phoneNumber': phoneNumber,
      'forwardEnabled': forwardEnabled,
      'keepAliveEnabled': keepAliveEnabled,
      'keepAliveMode': keepAliveMode.value,
      'keepAliveDays': keepAliveDays,
      'keepAliveNotifyThresholdDays': keepAliveNotifyThresholdDays,
      'keepAliveNotifyChannels': keepAliveNotifyChannels
          .map((channel) => channel.value)
          .toList(),
    };
  }

  factory SimCardInfo.fromMap(Map<dynamic, dynamic> map) {
    final subscriptionId = map['subscriptionId'] as int? ?? -1;
    final simSlot = map['simSlot'] as int? ?? -1;
    return SimCardInfo(
      key:
          map['key'] as String? ??
          (subscriptionId >= 0 ? 'sub_$subscriptionId' : 'slot_$simSlot'),
      subscriptionId: subscriptionId,
      simSlot: simSlot,
      displayName: map['displayName'] as String? ?? '',
      carrierName: map['carrierName'] as String? ?? '',
      phoneNumber: map['phoneNumber'] as String? ?? '',
      forwardEnabled: map['forwardEnabled'] as bool? ?? true,
      keepAliveEnabled: map['keepAliveEnabled'] as bool? ?? false,
      keepAliveMode: KeepAliveMode.fromValue(
        map['keepAliveMode'] as String? ?? KeepAliveMode.countdown.value,
      ),
      keepAliveDays: map['keepAliveDays'] as int? ?? 100,
      keepAliveNotifyThresholdDays:
          map['keepAliveNotifyThresholdDays'] as int? ?? 3,
      keepAliveNotifyChannels:
          (map['keepAliveNotifyChannels'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .map(ForwardChannel.fromValue)
              .toList(),
    );
  }
}

class SentSmsRecord {
  const SentSmsRecord({
    required this.id,
    required this.address,
    required this.body,
    required this.sentAt,
    required this.timeText,
    required this.subscriptionId,
    required this.simSlot,
    required this.simDisplayName,
  });

  final String id;
  final String address;
  final String body;
  final DateTime sentAt;
  final String timeText;
  final int subscriptionId;
  final int simSlot;
  final String simDisplayName;

  factory SentSmsRecord.fromMap(Map<dynamic, dynamic> map) {
    final timestamp =
        map['date'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final minute = time.minute.toString().padLeft(2, '0');
    return SentSmsRecord(
      id: '${map['id'] ?? timestamp}',
      address: map['address'] as String? ?? '未知收件人',
      body: map['body'] as String? ?? '',
      sentAt: time,
      timeText:
          '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour}:$minute',
      subscriptionId: map['subscriptionId'] as int? ?? -1,
      simSlot: map['simSlot'] as int? ?? -1,
      simDisplayName: map['simDisplayName'] as String? ?? '',
    );
  }
}

class SmsRecord {
  const SmsRecord({
    required this.id,
    required this.sender,
    required this.body,
    required this.timeText,
    required this.forwardOk,
    required this.subscriptionId,
    required this.simSlot,
    required this.simDisplayName,
  });

  final String id;
  final String sender;
  final String body;
  final String timeText;
  final bool forwardOk;
  final int subscriptionId;
  final int simSlot;
  final String simDisplayName;

  String get forwardStatusLabel => forwardOk ? '已转发' : '转发失败';
  String get simLabel {
    final parts = <String>[
      if (simDisplayName.trim().isNotEmpty) simDisplayName.trim(),
      if (simSlot >= 0) 'SIM${simSlot + 1}',
      if (subscriptionId >= 0) 'subId=$subscriptionId',
    ];
    final label = parts.toSet().join(' / ');
    return label.isEmpty ? '未知SIM' : label;
  }

  factory SmsRecord.fromMap(Map<dynamic, dynamic> map) {
    final timestamp =
        map['date'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final minute = time.minute.toString().padLeft(2, '0');
    return SmsRecord(
      id: '${map['id'] ?? timestamp}',
      sender: map['sender'] as String? ?? '未知发件人',
      body: map['body'] as String? ?? '',
      timeText:
          '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour}:$minute',
      forwardOk: map['forwardOk'] as bool? ?? false,
      subscriptionId: map['subscriptionId'] as int? ?? -1,
      simSlot: map['simSlot'] as int? ?? -1,
      simDisplayName: map['simDisplayName'] as String? ?? '',
    );
  }
}
