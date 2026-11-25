/// 站源订阅：用户填写一个远程配置（JSON）链接，应用定期 / 手动拉取并合并进站源列表。
///
/// 与「当前配置来源」（URL / 本地文件）正交：订阅是叠加在它之上的额外站源池，
/// 便于社区共享站源、一键更新，降低手动维护门槛。
class SiteSubscription {
  /// 订阅唯一标识（生成后不变，用作缓存键与合并关联）。
  final String id;

  /// 远程配置链接（JSON / Base64 / Depot 清单均可，复用配置解析链路）。
  final String url;

  /// 订阅展示名（缺省取链接）。
  final String name;

  /// 是否启用（关闭后不参与合并，也不自动刷新）。
  final bool enabled;

  /// 自动刷新间隔（分钟），范围 30 ~ 10080（7 天）。
  final int refreshIntervalMinutes;

  /// 上次成功拉取的版本标记（来自配置 `warning` / 自定义字段，可为空）。
  final String? lastVersion;

  /// 上次成功拉取得到的影视站源数。
  final int? lastSiteCount;

  /// 上次成功拉取得到的直播源数。
  final int? lastLiveCount;

  /// 上次拉取的错误信息（成功时为 null）。
  final String? lastError;

  /// 上次拉取时间。
  final DateTime? lastUpdatedAt;

  const SiteSubscription({
    required this.id,
    required this.url,
    required this.name,
    this.enabled = true,
    this.refreshIntervalMinutes = 360,
    this.lastVersion,
    this.lastSiteCount,
    this.lastLiveCount,
    this.lastError,
    this.lastUpdatedAt,
  });

  /// 新建一条订阅（生成 id 与默认值）。
  factory SiteSubscription.create({
    required String url,
    required String name,
    int refreshIntervalMinutes = 360,
  }) {
    final id =
        'sub_${url.hashCode.abs().toRadixString(36)}_${DateTime.now().microsecondsSinceEpoch}';
    return SiteSubscription(
      id: id,
      url: url,
      name: name.isEmpty ? url : name,
      refreshIntervalMinutes: _clampInterval(refreshIntervalMinutes),
    );
  }

  factory SiteSubscription.fromJson(Map<String, dynamic> json) {
    final interval = (json['refreshIntervalMinutes'] as num?)?.toInt() ?? 360;
    return SiteSubscription(
      id: (json['id']?.toString().isNotEmpty == true)
          ? json['id'].toString()
          : 'sub_${(json['url']?.toString() ?? '').hashCode.abs().toRadixString(36)}_'
              '${DateTime.now().microsecondsSinceEpoch}',
      url: json['url']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      enabled: json['enabled'] != false,
      refreshIntervalMinutes: _clampInterval(interval),
      lastVersion: json['lastVersion']?.toString(),
      lastSiteCount: json['lastSiteCount'] as int?,
      lastLiveCount: json['lastLiveCount'] as int?,
      lastError: json['lastError']?.toString(),
      lastUpdatedAt: json['lastUpdatedAt'] != null
          ? DateTime.tryParse(json['lastUpdatedAt'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'url': url,
        'name': name,
        'enabled': enabled,
        'refreshIntervalMinutes': refreshIntervalMinutes,
        'lastVersion': lastVersion,
        'lastSiteCount': lastSiteCount,
        'lastLiveCount': lastLiveCount,
        'lastError': lastError,
        'lastUpdatedAt': lastUpdatedAt?.toIso8601String(),
      };

  SiteSubscription copyWith({
    String? url,
    String? name,
    bool? enabled,
    int? refreshIntervalMinutes,
    String? lastVersion,
    int? lastSiteCount,
    int? lastLiveCount,
    String? lastError,
    DateTime? lastUpdatedAt,
    bool clearError = false,
  }) =>
      SiteSubscription(
        id: id,
        url: url ?? this.url,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        refreshIntervalMinutes: refreshIntervalMinutes ?? this.refreshIntervalMinutes,
        lastVersion: lastVersion ?? this.lastVersion,
        lastSiteCount: lastSiteCount ?? this.lastSiteCount,
        lastLiveCount: lastLiveCount ?? this.lastLiveCount,
        lastError: clearError ? null : (lastError ?? this.lastError),
        lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
      );

  static int _clampInterval(int value) =>
      value.clamp(30, 10080);
}
