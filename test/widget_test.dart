import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_smsforward/main.dart';

void main() {
  testWidgets('home page renders sms forward controls', (tester) async {
    final sentAt = DateTime.now().subtract(const Duration(days: 98));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('sms_forward/methods'), (
          call,
        ) async {
          return switch (call.method) {
            'getConfig' => <String, Object?>{
              'simCards': <Map<String, Object?>>[
                <String, Object?>{
                  'key': 'sub_1',
                  'subscriptionId': 1,
                  'simSlot': 0,
                  'displayName': 'SIM 1',
                  'carrierName': '中国移动',
                  'phoneNumber': '13800000000',
                  'forwardEnabled': true,
                  'keepAliveEnabled': true,
                  'keepAliveMode': 'countdown',
                  'keepAliveDays': 100,
                  'keepAliveNotifyThresholdDays': 3,
                  'keepAliveNotifyChannels': <String>['feishu'],
                },
              ],
              'channels': <Map<String, Object?>>[
                <String, Object?>{
                  'channel': 'feishu',
                  'enabled': true,
                  'webhookUrl': 'https://example.com/hook',
                  'secret': '',
                },
              ],
            },
            'getRecords' => <Map<String, Object?>>[],
            'getSentSmsRecords' => <Map<String, Object?>>[
              <String, Object?>{
                'id': 'sent-1',
                'address': '10086',
                'body': '保号短信',
                'date': sentAt.millisecondsSinceEpoch,
                'subscriptionId': 1,
                'simSlot': 0,
                'simDisplayName': 'SIM 1',
              },
            ],
            'hasSmsPermission' => false,
            'isServiceRunning' => false,
            'checkKeepAliveNotifications' => 0,
            _ => null,
          };
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('sms_forward/events', (message) async {
          return const StandardMethodCodec().encodeSuccessEnvelope(null);
        });

    await tester.pumpWidget(const SmsForwardApp());
    await tester.pumpAndSettle();

    expect(find.text('短信转发助手'), findsWidgets);
    expect(find.text('未监听'), findsOneWidget);
    expect(find.text('启动监听'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('SIM 卡：13800000000'),
      ),
      findsOneWidget,
    );
    expect(find.text('保号提醒'), findsOneWidget);
    expect(find.textContaining('SIM1'), findsWidgets);
    expect(find.textContaining('倒计2天'), findsOneWidget);
    expect(find.textContaining('保号短信'), findsOneWidget);
    expect(find.text('短信权限'), findsOneWidget);
    expect(find.text('电池优化'), findsOneWidget);
    expect(find.text('功能设置'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();

    expect(find.text('设备信息'), findsOneWidget);
    expect(find.text('转发通道'), findsOneWidget);
    expect(find.text('短信记录'), findsOneWidget);
    expect(find.text('转发日志'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();

    expect(find.text('所有功能仅在本机运行，数据安全有保障\n版本：1.0.1'), findsOneWidget);
  });

  testWidgets('sim editor renders keep alive notification settings', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('sms_forward/methods'), (
          call,
        ) async {
          return switch (call.method) {
            'getConfig' => <String, Object?>{
              'simCards': <Map<String, Object?>>[
                <String, Object?>{
                  'key': 'sub_1',
                  'subscriptionId': 1,
                  'simSlot': 0,
                  'displayName': 'SIM 1',
                  'carrierName': '中国移动',
                  'phoneNumber': '13800000000',
                  'forwardEnabled': true,
                  'keepAliveEnabled': true,
                  'keepAliveMode': 'countdown',
                  'keepAliveDays': 100,
                  'keepAliveNotifyThresholdDays': 3,
                  'keepAliveNotifyChannels': <String>['feishu'],
                },
              ],
              'channels': <Map<String, Object?>>[
                <String, Object?>{
                  'channel': 'feishu',
                  'enabled': true,
                  'webhookUrl': 'https://example.com/hook',
                  'secret': '',
                },
              ],
            },
            'getRecords' => <Map<String, Object?>>[],
            'getSentSmsRecords' => <Map<String, Object?>>[],
            'hasSmsPermission' => false,
            'isServiceRunning' => false,
            'checkKeepAliveNotifications' => 0,
            _ => null,
          };
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('sms_forward/events', (message) async {
          return const StandardMethodCodec().encodeSuccessEnvelope(null);
        });

    await tester.pumpWidget(const SmsForwardApp());
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设备信息'));
    await tester.pumpAndSettle();

    expect(find.text('保号通知通道'), findsOneWidget);
    expect(find.text('飞书'), findsWidgets);
    expect(find.text('通知阈值'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
    expect(find.text('测试发送'), findsOneWidget);
  });

  testWidgets('keep alive test send shows validation dialog', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('sms_forward/methods'), (
          call,
        ) async {
          return switch (call.method) {
            'getConfig' => <String, Object?>{
              'simCards': <Map<String, Object?>>[
                <String, Object?>{
                  'key': 'sub_1',
                  'subscriptionId': 1,
                  'simSlot': 0,
                  'displayName': 'SIM 1',
                  'carrierName': '中国移动',
                  'phoneNumber': '13800000000',
                  'forwardEnabled': true,
                  'keepAliveEnabled': true,
                  'keepAliveMode': 'countdown',
                  'keepAliveDays': 100,
                  'keepAliveNotifyThresholdDays': 3,
                  'keepAliveNotifyChannels': <String>[],
                },
              ],
              'channels': <Map<String, Object?>>[
                <String, Object?>{
                  'channel': 'feishu',
                  'enabled': true,
                  'webhookUrl': 'https://example.com/hook',
                  'secret': '',
                },
              ],
            },
            'getRecords' => <Map<String, Object?>>[],
            'getSentSmsRecords' => <Map<String, Object?>>[],
            'hasSmsPermission' => false,
            'isServiceRunning' => false,
            'checkKeepAliveNotifications' => 0,
            _ => null,
          };
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('sms_forward/events', (message) async {
          return const StandardMethodCodec().encodeSuccessEnvelope(null);
        });

    await tester.pumpWidget(const SmsForwardApp());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设备信息'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试发送'));
    await tester.pumpAndSettle();

    expect(find.text('无法测试发送'), findsOneWidget);
    expect(find.textContaining('请选择至少一个保号通知通道'), findsOneWidget);
  });

  testWidgets('keep alive channel list reflects newly typed webhook', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('sms_forward/methods'), (
          call,
        ) async {
          return switch (call.method) {
            'getConfig' => <String, Object?>{
              'simCards': <Map<String, Object?>>[
                <String, Object?>{
                  'key': 'sub_1',
                  'subscriptionId': 1,
                  'simSlot': 0,
                  'displayName': 'SIM 1',
                  'carrierName': '中国移动',
                  'phoneNumber': '13800000000',
                  'forwardEnabled': true,
                  'keepAliveEnabled': true,
                  'keepAliveMode': 'countdown',
                  'keepAliveDays': 100,
                  'keepAliveNotifyThresholdDays': 3,
                  'keepAliveNotifyChannels': <String>[],
                },
              ],
              'channels': <Map<String, Object?>>[
                <String, Object?>{
                  'channel': 'feishu',
                  'enabled': true,
                  'webhookUrl': '',
                  'secret': '',
                },
              ],
            },
            'getRecords' => <Map<String, Object?>>[],
            'getSentSmsRecords' => <Map<String, Object?>>[],
            'hasSmsPermission' => false,
            'isServiceRunning' => false,
            'checkKeepAliveNotifications' => 0,
            'saveConfig' => null,
            _ => null,
          };
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('sms_forward/events', (message) async {
          return const StandardMethodCodec().encodeSuccessEnvelope(null);
        });

    await tester.pumpWidget(const SmsForwardApp());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转发通道'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '飞书 Webhook 地址'),
      'https://example.com/hook',
    );
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('设备信息'));
    await tester.pumpAndSettle();

    expect(find.text('保号通知通道'), findsOneWidget);
    expect(find.text('飞书'), findsWidgets);
  });
}
