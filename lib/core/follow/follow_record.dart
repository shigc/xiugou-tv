/// 追剧记录：用户关注的一部连载剧，用于跨站探测新集更新。
///
/// 与收藏（`VodItem`）的区别：收藏是"这部片我想留着"，追剧是
/// "我在看这部剧，告诉我什么时候更新"。追剧记录额外携带
/// 「已知总集数 / 已看集数」，用于计算"还有几集没看"。
class FollowRecord {
  /// 追剧唯一标识：`siteKey/vodId`（与探测走的站源绑定）。
  final String id;

  final String vodId;
  final String vodName;
  final String vodPic;

  /// 探测更新时使用的站源；站源被移除后该剧会被跳过探测。
  final String? siteKey;
  final String? siteName;

  /// 上次探测到的「最长线路」总集数（同一部剧各线路集数可能不同）。
  final int knownEpisodes;

  /// 已看到的集数：最近一次播放的集在该线路中的序号 + 1；从未播放为 0。
  final int seenEpisodes;

  final DateTime followedAt;

  /// 上次探测时间（无论是否发现更新都会刷新）。
  final DateTime? lastCheckedAt;

  /// 最近一次发现新集的时间；从未更新过为 null。
  final DateTime? lastUpdatedAt;

  const FollowRecord({
    required this.id,
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    this.siteKey,
    this.siteName,
    this.knownEpisodes = 0,
    this.seenEpisodes = 0,
    required this.followedAt,
    this.lastCheckedAt,
    this.lastUpdatedAt,
  });

  /// 追剧身份键：同站同片唯一。
  static String buildId(String? siteKey, String vodId) =>
      '${siteKey ?? ''}/$vodId';

  /// 待看集数 = 已知总集数 − 已看集数（下限 0）。
  int get unseenEpisodes => (knownEpisodes - seenEpisodes).clamp(0, knownEpisodes);

  /// 是否有未看的新集。
  bool get hasUpdate => unseenEpisodes > 0;

  FollowRecord copyWith({
    String? vodName,
    String? vodPic,
    String? siteName,
    int? knownEpisodes,
    int? seenEpisodes,
    DateTime? lastCheckedAt,
    DateTime? lastUpdatedAt,
    bool clearLastUpdatedAt = false,
  }) {
    return FollowRecord(
      id: id,
      vodId: vodId,
      vodName: vodName ?? this.vodName,
      vodPic: vodPic ?? this.vodPic,
      siteKey: siteKey,
      siteName: siteName ?? this.siteName,
      knownEpisodes: knownEpisodes ?? this.knownEpisodes,
      seenEpisodes: seenEpisodes ?? this.seenEpisodes,
      followedAt: followedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      lastUpdatedAt:
          clearLastUpdatedAt ? null : (lastUpdatedAt ?? this.lastUpdatedAt),
    );
  }

  factory FollowRecord.fromJson(Map<String, dynamic> json) {
    return FollowRecord(
      id: json['id']?.toString() ?? '',
      vodId: json['vodId']?.toString() ?? '',
      vodName: json['vodName']?.toString() ?? '',
      vodPic: json['vodPic']?.toString() ?? '',
      siteKey: json['siteKey']?.toString(),
      siteName: json['siteName']?.toString(),
      knownEpisodes: _toInt(json['knownEpisodes']) ?? 0,
      seenEpisodes: _toInt(json['seenEpisodes']) ?? 0,
      followedAt:
          DateTime.tryParse(json['followedAt']?.toString() ?? '') ??
              DateTime.now(),
      lastCheckedAt: _date(json['lastCheckedAt']),
      lastUpdatedAt: _date(json['lastUpdatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'vodId': vodId,
        'vodName': vodName,
        'vodPic': vodPic,
        if (siteKey != null) 'siteKey': siteKey,
        if (siteName != null) 'siteName': siteName,
        'knownEpisodes': knownEpisodes,
        'seenEpisodes': seenEpisodes,
        'followedAt': followedAt.toIso8601String(),
        if (lastCheckedAt != null) 'lastCheckedAt': lastCheckedAt!.toIso8601String(),
        if (lastUpdatedAt != null) 'lastUpdatedAt': lastUpdatedAt!.toIso8601String(),
      };

  static DateTime? _date(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static int? _toInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
