import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/settings/models/appearance_preferences.dart';
import 'package:xiugou_tv/ui/theme/app_palette.dart';

void main() {
  group('AppearancePreferences 配色预设', () {
    test('切换明暗模式与侧栏折叠时保留已选配色', () {
      const preferences = AppearancePreferences(themePreset: 'aurora');

      expect(preferences.withThemeMode(AppThemeMode.light).themePreset, 'aurora');
      expect(preferences.withSidebarCollapsed(true).themePreset, 'aurora');
    });

    test('序列化往返保留配色预设', () {
      const preferences = AppearancePreferences(
        themeMode: AppThemeMode.light,
        themePreset: 'cocoa',
      );

      final restored = AppearancePreferences.fromJson(preferences.toJson());
      expect(restored.themePreset, 'cocoa');
      expect(restored.themeMode, AppThemeMode.light);
    });

    test('新增预设可查，非法键回退经典', () {
      expect(themePresetByName('aurora').label, '极光蓝紫');
      expect(themePresetByName('cocoa').label, '摩卡棕');
      expect(themePresetByName('graphite').label, '石墨钢蓝');
      expect(themePresetByName('neon').label, '霓虹电光');
      expect(themePresetByName('not-exist').name, 'classic');
      expect(themePresets.length, greaterThanOrEqualTo(10));
    });
  });
}
