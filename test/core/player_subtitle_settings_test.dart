import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/player/models/player_settings.dart';
import 'package:xiugou_tv/core/player/player_settings_application.dart';

/// 记录写入了哪些 mpv 属性，用来验证「设置页改一项 → 引擎收到什么」。
class _RecordingTarget implements PlayerSettingsTarget {
  final Map<String, String> written = <String, String>{};

  @override
  Future<void> setProperty(String name, String value) async =>
      written[name] = value;

  @override
  Future<void> setStartupVolume(double value) async {}

  @override
  Future<void> setStartupRate(double value) async {}
}

PlayerSettings _roundTrip(PlayerSettings settings) =>
    PlayerSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>);

void main() {
  group('字幕首选项', () {
    test('默认值就是随包 libmpv 的出厂值，写出去不改变外观', () {
      const settings = PlayerSettings();
      // 实测 media_kit 自带 mpv-dev-x86_64-20230924：
      // sub-delay=0.000000 / sub-scale=1.000000 / sub-pos=100.000000。
      // 默认值若偏离这组数字，用户没碰过字幕设置也会被改样子。
      expect(settings.subtitleDelayMs, 0);
      expect(settings.subtitleScale, 1.0);
      expect(settings.subtitlePosition, 100);

      final properties = settings.toMpvProperties();
      expect(properties['sub-delay'], '0.000');
      expect(properties['sub-scale'], '1.00');
      expect(properties['sub-pos'], '100');
    });

    test('JSON 往返保留三项，越界值被钳回合法区间', () {
      const settings = PlayerSettings(
        subtitleDelayMs: -2500,
        subtitleScale: 1.4,
        subtitlePosition: 40,
      );
      final restored = _roundTrip(settings);
      expect(restored, settings);
      expect(restored.subtitleDelayMs, -2500);
      expect(restored.subtitleScale, 1.4);
      expect(restored.subtitlePosition, 40);

      final clamped = PlayerSettings.fromJson(<String, dynamic>{
        'subtitleDelayMs': 999999,
        'subtitleScale': -3,
        'subtitlePosition': -50,
      });
      expect(clamped.subtitleDelayMs, PlayerSettings.maxSubtitleDelayMs);
      expect(clamped.subtitleScale, PlayerSettings.minSubtitleScale);
      expect(clamped.subtitlePosition, PlayerSettings.minSubtitlePosition);

      // 文本 / 非数字一类的手工编辑内容回落默认值，不能抛异常
      final garbage = PlayerSettings.fromJson(<String, dynamic>{
        'subtitleDelayMs': '很多',
        'subtitleScale': null,
        'subtitlePosition': <String>[],
      });
      expect(garbage.subtitleDelayMs, 0);
      expect(garbage.subtitleScale, 1.0);
      expect(garbage.subtitlePosition, 100);
    });

    test('旧配置文件缺这三项时按默认值补', () {
      final legacyJson =
          jsonDecode(jsonEncode(PlayerSettings.defaults.toJson()))
              as Map<String, dynamic>
            ..remove('subtitleDelayMs')
            ..remove('subtitleScale')
            ..remove('subtitlePosition');
      final legacy = PlayerSettings.fromJson(legacyJson);
      expect(legacy.subtitleDelayMs, 0);
      expect(legacy.subtitleScale, 1.0);
      expect(legacy.subtitlePosition, 100);
    });

    test('延迟换算成秒并保留三位，与音画同步同一口径', () {
      final properties =
          const PlayerSettings(subtitleDelayMs: 1500).toMpvProperties();
      expect(properties['sub-delay'], '1.500');
      expect(properties['audio-delay'], '0.000');
    });

    test('设置页改动会作为 sub-* 属性下发给播放器', () async {
      final target = _RecordingTarget();
      final application = PlayerSettingsApplication();
      addTearDown(application.dispose);

      await application.attach(target);
      await application.update(const PlayerSettings(
        subtitleDelayMs: 800,
        subtitleScale: 1.5,
        subtitlePosition: 60,
      ));

      expect(target.written['sub-delay'], '0.800');
      expect(target.written['sub-scale'], '1.50');
      expect(target.written['sub-pos'], '60');
      expect(application.state.phase, SettingsApplicationPhase.confirmed);
    });
  });
}
