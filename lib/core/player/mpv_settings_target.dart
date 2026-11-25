import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'player_settings_application.dart';

/// 数值化解析 mpv 宽高比取值：支持浮点（`1.777778`）与 `W:H`（`16:9`）。
///
/// 无法构成正比例时（`no` / `auto` / 空串 / 非法格式）返回 null；
/// 实测 mpv v0.36 的回读为 6 位小数字符串（如 `1.777778`）。
double? mpvAspectRatioOf(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final direct = double.tryParse(value);
  if (direct != null) return direct.isFinite && direct > 0 ? direct : null;
  final parts = value.split(':');
  if (parts.length != 2) return null;
  final width = double.tryParse(parts[0].trim());
  final height = double.tryParse(parts[1].trim());
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return width / height;
}

/// media_kit 的原生写入会忽略返回码，必须以回读结果作为确认依据。
class MpvSettingsTarget implements PlayerSettingsTarget {
  final Player _player;
  final NativePlayer _native;

  MpvSettingsTarget(Player player)
      : _player = player,
        _native = _nativePlayer(player);

  static NativePlayer _nativePlayer(Player player) {
    final platform = player.platform;
    if (platform is! NativePlayer) throw UnsupportedError('当前播放器不支持 mpv 参数');
    return platform;
  }

  @override
  Future<void> setProperty(String name, String value) async {
    // 画质增强着色器：Windows 绝对路径含冒号，mpv 会把 `glsl-shaders` 的
    // 字符串按列表分隔符（`:`）误拆，故改用 `change-list ... set <path>`
    // 逐个传入；空串表示清除，无冒号可直接 set。
    if (name == 'glsl-shaders') {
      await _applyGlslShaders(value);
      return;
    }
    await _native.setProperty(name, value);
    final actual = await _native.getProperty(name);
    // mpv 将旧 audio-channels=auto 规范化为 auto-safe。
    if (name == 'audio-channels' && value == 'auto' && actual == 'auto-safe') {
      return;
    }
    // mpv 将宽高比取值规范化为浮点（16:9 → 1.777778）：按数值容差确认。
    if (name == 'video-aspect-override' && value != actual) {
      final expected = mpvAspectRatioOf(value);
      final readBack = mpvAspectRatioOf(actual);
      if (expected != null && readBack != null && (expected - readBack).abs() < 0.001) {
        return;
      }
    }
    _verify(name, value, actual);
  }

  /// 注入 / 清除画质增强着色器。
  ///
  /// mpv 的 `glsl-shaders` 是列表属性，回读为逗号分隔的路径串且会归一化分隔符，
  /// 无法做精确匹配；此处只做「是否生效」的宽松确认。
  Future<void> _applyGlslShaders(String value) async {
    if (value.isEmpty) {
      // 清除：空串无冒号，可直接 set。
      await _native.setProperty('glsl-shaders', '');
      final actual = await _native.getProperty('glsl-shaders');
      if (actual.isNotEmpty) {
        throw StateError('glsl-shaders 未清除（回读 $actual）');
      }
      return;
    }
    // 含绝对路径（带冒号），用 change-list 逐个传入，避开 mpv 的 `:` 列表分隔。
    await _native.command(['change-list', 'glsl-shaders', 'set', value]);
    final actual = await _native.getProperty('glsl-shaders');
    final expectedName = p.basename(value);
    if (actual.isEmpty || !actual.contains(expectedName)) {
      throw StateError('glsl-shaders 未确认（期望含 $expectedName，回读 $actual）');
    }
  }

  @override
  Future<void> setStartupVolume(double value) async {
    await _player.setVolume(value);
    _verify('volume', '$value', await _native.getProperty('volume'));
  }

  @override
  Future<void> setStartupRate(double value) async {
    await _player.setRate(value);
    if (!_native.configuration.pitch) {
      _verify('speed', '$value', await _native.getProperty('speed'));
      return;
    }
    _verify('audio-pitch-correction', 'no',
        await _native.getProperty('audio-pitch-correction'));
    final filters = await _native.getProperty('af');
    // mpv 过滤器字符串会用 %长度% 转义 scale 数值；pitch 模式不通过 speed 控制倍速。
    final scale = RegExp(r'^scaletempo=scale=(?:%\d+%)?([0-9.eE+-]+)$')
        .firstMatch(filters)
        ?.group(1);
    _verify(
        'scaletempo:scale', '${value / _player.state.pitch}', scale ?? filters);
  }

  void _verify(String name, String expected, String actual) {
    if (expected == actual) return;
    final left = double.tryParse(expected);
    final right = double.tryParse(actual);
    if (left != null &&
        right != null &&
        left.isFinite &&
        right.isFinite &&
        (left - right).abs() < 0.000001) {
      return;
    }
    throw StateError(
        '$name 未确认（期望 $expected，回读 ${actual.isEmpty ? '不可用' : actual}）');
  }
}
