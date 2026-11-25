import '../api/models/vod_models.dart';
import '../diagnostics/app_logger.dart';
import '../api/site_api.dart';
import '../config/models/vod_config.dart';
import 'follow_record.dart';

/// 单部剧的探测结果。
class FollowCheckOutcome {
  /// 探测后的记录（含最新 knownEpisodes；无变化时与传入记录等值但刷新 lastCheckedAt）。
  final FollowRecord record;

  /// 本次探测新增的集数（0 表示无更新）。
  final int addedEpisodes;

  /// 探测是否失败（站源失效 / 超时 / 详情为空）。失败的记录原样返回。
  final bool failed;

  const FollowCheckOutcome({
    required this.record,
    this.addedEpisodes = 0,
    this.failed = false,
  });
}

/// 追剧更新探测器：对每部追剧记录跨站拉取详情，比较集数变化。
///
/// 设计要点：
/// - 单剧独立 try/catch + 20 秒超时，一部失效不影响其余；
/// - 并发上限小（3），避免启动期把请求全打出去；
/// - 「总集数」取**最长线路**的集数——部分站源线路只收录部分集。
class FollowUpdateChecker {
  /// 同一批探测内的节流间隔：距上次探测不足该时长时整体跳过。
  static const Duration throttleInterval = Duration(minutes: 30);

  /// 单剧详情拉取超时（与播放侧 `_loadDetailForHistory` 的 20s 口径一致）。
  static const Duration perFollowTimeout = Duration(seconds: 20);

  /// 并发上限。
  static const int concurrency = 3;

  DateTime? _lastRunAt;

  /// 距上次成功探测是否已过节流间隔（[force] 时忽略）。
  bool get shouldRun =>
      _lastRunAt == null ||
      DateTime.now().difference(_lastRunAt!) >= throttleInterval;

  /// 探测全部追剧记录。
  ///
  /// [sites] 为当前配置的全部站源（内部按 key 查找）；
  /// [follows] 为待探测记录；站源已不存在的条目直接按失败返回。
  /// 并发按 [concurrency] 分批，批内并行、批间串行。
  Future<List<FollowCheckOutcome>> checkAll(
    List<Site> sites,
    List<FollowRecord> follows,
    SiteApi siteApi, {
    bool force = false,
  }) async {
    if (follows.isEmpty) return const [];
    if (!force && !shouldRun) return const [];
    _lastRunAt = DateTime.now();

    final siteByKey = {for (final s in sites) s.key: s};
    final results = <FollowCheckOutcome>[];
    for (var i = 0; i < follows.length; i += concurrency) {
      final batch = follows.sublist(
          i, (i + concurrency) > follows.length ? follows.length : i + concurrency);
      await Future.wait(batch
          .map((record) => _checkOne(record, siteByKey, siteApi).then(results.add)));
    }
    return results;
  }

  Future<FollowCheckOutcome> _checkOne(
    FollowRecord record,
    Map<String, Site> siteByKey,
    SiteApi siteApi,
  ) async {
    final siteKey = record.siteKey;
    final site = siteKey == null ? null : siteByKey[siteKey];
    if (site == null) {
      // 站源已移除：标记检查时间但不改集数，UI 层按"源失效"展示。
      return FollowCheckOutcome(
        record: record.copyWith(lastCheckedAt: DateTime.now()),
        failed: true,
      );
    }
    try {
      final detail = await siteApi
          .fetchDetail(site, vodId: record.vodId)
          .timeout(perFollowTimeout);
      var latest = 0;
      for (final source in detail?.sources ?? const <PlayFrom>[]) {
        if (source.episodes.length > latest) latest = source.episodes.length;
      }
      final now = DateTime.now();
      if (latest <= record.knownEpisodes) {
        return FollowCheckOutcome(
          record: record.copyWith(lastCheckedAt: now),
        );
      }
      AppLogger.instance.info(
          'follow', '《${record.vodName}》发现新集：${record.knownEpisodes} → $latest');
      return FollowCheckOutcome(
        record: record.copyWith(
          knownEpisodes: latest,
          lastCheckedAt: now,
          lastUpdatedAt: now,
        ),
        addedEpisodes: latest - record.knownEpisodes,
      );
    } catch (error) {
      AppLogger.instance.warning('follow', '《${record.vodName}》探测失败', error: error);
      return FollowCheckOutcome(
        record: record.copyWith(lastCheckedAt: DateTime.now()),
        failed: true,
      );
    }
  }
}
