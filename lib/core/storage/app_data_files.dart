/// 应用数据目录中的持久化文件注册表。
///
/// 单一事实来源：缓存清理（SET-09）用它判断「哪些文件名可以出现在临时文件
/// 白名单里」，数据备份（SET-10）用它生成备份白名单。新增持久化文件时必须
/// 先在这里登记，再决定是否进入备份。
library;

/// 重启操作标记不属于资料文件，不能随迁移复制或随备份导出。
const String appDataResetMarkerFileName = 'reset_pending.json';

/// 数据文件类别。备份默认排除 [AppDataCategory.window]、[AppDataCategory.appearance]
/// 与 [AppDataCategory.cache]。
enum AppDataCategory {
  configSnapshot,
  configSource,
  window,
  favorite,
  history,
  preference,
  live,
  player,
  /// 外观（SET-08）：偏好文件进备份没有意义——壁纸图片本体不在白名单里，
  /// 恢复后只会得到悬空引用；因此与窗口状态一样排除在备份之外。
  appearance,
  /// 仅当前系统用户可解密，不随普通数据备份导出。
  credentials,
  /// 可再生的本地缓存：登记它是为了让数据目录迁移带上它、孤儿临时文件能被清理、
  /// 占用能在设置页被盘点到；但「重新拉一次就有」的东西不进备份。
  cache,
}

class AppDataFile {
  final String name;
  final AppDataCategory category;

  /// 是否可能含订阅地址 / 请求头 / 令牌等敏感内容（用于备份提示）。
  final bool sensitive;

  const AppDataFile(this.name, this.category, {this.sensitive = false});
}

/// 应用数据目录里的持久化文件。
///
/// 2026-11-03 补齐 8 个漏登记的文件：`follows.json`（追剧）、
/// `site_subscriptions.json`（配置订阅）、`cached_subscription_configs.json`（订阅拉取缓存）、
/// `live_last.json`（上次直播频道）、`video_cache_preferences.json`（缓存偏好）、
/// 以及更新模块的 `update_cache.json` / `update_mirror_health.json` / `update_preferences.json`。
/// 漏登记不会报错，但会让这些文件**不参与数据目录迁移**
/// （迁移按本表收集文件，见 `data_directory_manager.dart`）——用户换了数据目录，收藏还在、
/// 追剧和订阅却空了。所以新增落盘文件时必须先登记在这里。
///
/// 刻意不登记：`data_location.json` / `data_location_pending.json`（自定义目录指针，
/// 按设计只存在于默认目录）、`reset_pending.json`（一次性标记）、`runtime/` 与
/// `video_cache/`（可再生内容，见 `migratedSubdirectories`）。
/// `app.log` / `companion.log` 同属可再生的诊断文件：它们动态派生自当前数据目录，
/// 不参与迁移或备份，也不进入本表的 `.json` 校验（见 `AppLogger` / `CompanionLog`）。
const List<AppDataFile> appDataFiles = [
  AppDataFile('appearance_preferences.json', AppDataCategory.appearance),
  AppDataFile('cached_subscription_configs.json', AppDataCategory.cache, sensitive: true),
  AppDataFile('cached_vod_config.json', AppDataCategory.configSnapshot, sensitive: true),
  // 配置源目录 v1：entries + 独立 categories（含空分类）；兼容旧版数组。
  AppDataFile('config_sources.json', AppDataCategory.configSource, sensitive: true),
  AppDataFile('current_config.json', AppDataCategory.configSnapshot, sensitive: true),
  AppDataFile('desktop_window.json', AppDataCategory.window, sensitive: true),
  AppDataFile('favorites.json', AppDataCategory.favorite),
  // 追剧记录与收藏同属「用户主动留下的清单」，模型不同但都进备份。
  AppDataFile('follows.json', AppDataCategory.favorite),
  AppDataFile('history.json', AppDataCategory.history),
  AppDataFile('history_preferences.json', AppDataCategory.preference),
  AppDataFile('home_site_preferences.json', AppDataCategory.preference),
  // 直链播放方式记忆（issue #9-1）：只存主机名 → live / vod，不含路径或令牌。
  AppDataFile('live_direct_modes.json', AppDataCategory.live),
  // §33 直播收藏：与点播收藏分开存（模型不同），但同属「收藏」这一类，
  // 所以跟随 backupAppDataFiles 一起进备份 —— 用户换机后两个收藏都要在。
  AppDataFile('live_favorites.json', AppDataCategory.favorite),
  // 上次直播频道：频道键里含播放地址，按敏感处理。
  AppDataFile('live_last.json', AppDataCategory.live, sensitive: true),
  // 独立直播源（当前项 + 历史 + 独立分类目录）：含订阅地址，按敏感处理。
  AppDataFile('live_source_history.json', AppDataCategory.live,
      sensitive: true),
  AppDataFile('live_sources.json', AppDataCategory.live, sensitive: true),
  // §14 安全 DNS 选择：属于偏好，随备份走
  AppDataFile('network_preferences.json', AppDataCategory.preference),
  AppDataFile('play_skip_preferences.json', AppDataCategory.preference),
  AppDataFile('player_settings.json', AppDataCategory.player),
  AppDataFile('search_preferences.json', AppDataCategory.preference),
  AppDataFile('self_check_preferences.json', AppDataCategory.preference),
  AppDataFile('site_subscriptions.json', AppDataCategory.configSource, sensitive: true),
  AppDataFile('startup_preferences.json', AppDataCategory.preference),
  AppDataFile('webdav_connections.bin', AppDataCategory.credentials, sensitive: true),
  AppDataFile('webdav_connections.lock', AppDataCategory.credentials),
  AppDataFile('update_cache.json', AppDataCategory.cache),
  AppDataFile('update_mirror_health.json', AppDataCategory.cache),
  AppDataFile('update_preferences.json', AppDataCategory.preference),
  AppDataFile('video_cache_preferences.json', AppDataCategory.player),
];

/// 文件名集合，供临时文件基名白名单使用。
final Set<String> appDataFileNames =
    Set<String>.unmodifiable(appDataFiles.map((file) => file.name));

/// 备份白名单：排除窗口状态（恢复其他机器的位置可能把窗口放到不可见区域）、
/// 外观偏好（壁纸图片不在备份内，恢复只会得到失效引用）与可再生缓存。
List<AppDataFile> get backupAppDataFiles => appDataFiles
    .where((file) =>
        file.category != AppDataCategory.window &&
        file.category != AppDataCategory.appearance &&
        file.category != AppDataCategory.credentials &&
        file.category != AppDataCategory.cache)
    .toList(growable: false);

/// 备份白名单文件名集合。
final Set<String> backupAppDataFileNames = Set<String>.unmodifiable(
  backupAppDataFiles.map((file) => file.name),
);

bool isAppDataFileName(String name) => appDataFileNames.contains(name);

bool isBackupAppDataFileName(String name) =>
    backupAppDataFileNames.contains(name);
