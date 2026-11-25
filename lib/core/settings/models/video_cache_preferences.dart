/// 视频本地缓存偏好（开关 / 缓存目录 / 容量上限）。
///
/// 持久化于应用数据目录的 `video_cache_preferences.json`（version 1）。
/// 读取规则与其他偏好一致：结构 / 版本 / 字段类型非法视为损坏并抛出
/// [FormatException]（由调用方保留原文件并提示）；数值越界归一化为默认。
///
/// 缓存由播放器的后台下载器写入，与播放状态无关 —— 暂停时同样继续下载，
/// 因此没有单独的「暂停时缓存」开关。
class VideoCachePreferences {
  static const int formatVersion = 1;

  /// 默认开启：用户希望看过的片子留一份本地副本。
  static const bool defaultEnabled = true;

  /// 默认容量上限（GB）
  static const int defaultMaxSizeGb = 20;

  /// 可配置范围：越界视为无效并归一化为默认
  static const int minMaxSizeGb = 1;
  static const int maxMaxSizeGb = 500;

  /// 界面档位（升序）；[defaultMaxSizeGb] 为默认档
  static const List<int> maxSizeOptionsGb = [5, 10, 20, 50, 100, 200];

  final bool enabled;

  /// 缓存根目录；`null` 表示使用默认位置（应用数据目录下的 `video_cache`）。
  final String? directory;

  /// 缓存占用上限（GB）；达到上限后停止新的缓存写入。
  final int maxSizeGb;

  const VideoCachePreferences({
    this.enabled = defaultEnabled,
    this.directory,
    this.maxSizeGb = defaultMaxSizeGb,
  });

  VideoCachePreferences copyWith({
    bool? enabled,
    String? directory,
    bool clearDirectory = false,
    int? maxSizeGb,
  }) =>
      VideoCachePreferences(
        enabled: enabled ?? this.enabled,
        directory: clearDirectory ? null : (directory ?? this.directory),
        maxSizeGb: maxSizeGb ?? this.maxSizeGb,
      );

  /// 数值归一化：超出 [minMaxSizeGb, maxMaxSizeGb] 时回落默认；其余保留原值。
  static int normalizeMaxSizeGb(int value) =>
      (value < minMaxSizeGb || value > maxMaxSizeGb) ? defaultMaxSizeGb : value;

  /// 严格解析：结构 / 版本 / 字段类型非法时抛出 [FormatException]；
  /// 数值越界与非法目录归一化为默认。
  static VideoCachePreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('视频缓存偏好格式无效');
    }
    final rawEnabled = json['enabled'];
    if (rawEnabled != null && rawEnabled is! bool) {
      throw const FormatException('视频缓存偏好格式无效');
    }
    final rawDirectory = json['directory'];
    if (rawDirectory != null && rawDirectory is! String) {
      throw const FormatException('视频缓存偏好格式无效');
    }
    final rawMax = json['maxSizeGb'];
    if (rawMax != null && rawMax is! int) {
      throw const FormatException('视频缓存偏好格式无效');
    }
    final dir = (rawDirectory as String?)?.trim();
    return VideoCachePreferences(
      enabled: rawEnabled as bool? ?? defaultEnabled,
      directory: (dir == null || dir.isEmpty) ? null : dir,
      maxSizeGb: normalizeMaxSizeGb(rawMax as int? ?? defaultMaxSizeGb),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'enabled': enabled,
        'directory': directory,
        'maxSizeGb': maxSizeGb,
      };

  @override
  bool operator ==(Object other) =>
      other is VideoCachePreferences &&
      other.enabled == enabled &&
      other.directory == directory &&
      other.maxSizeGb == maxSizeGb;

  @override
  int get hashCode => Object.hash(enabled, directory, maxSizeGb);

  @override
  String toString() =>
      'VideoCachePreferences(enabled: $enabled, directory: $directory, maxSizeGb: $maxSizeGb)';
}
