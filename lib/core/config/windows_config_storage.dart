import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../api/models/vod_models.dart';
import '../storage/data_directory_manager.dart';
import '../storage/data_restore_guard.dart';
import 'config_credentials.dart';
import 'models/desktop_window_config.dart';
import 'models/config_snapshot.dart';
import 'models/history_record.dart';
import 'models/home_site_preference.dart';
import 'models/vod_config.dart';
import 'package:xiugou_tv/core/settings/models/site_subscription.dart';
import 'package:xiugou_tv/core/follow/follow_record.dart';

/// Windows 平台本地持久化文件存储驱动
class WindowsConfigStorage {
  static const String _windowConfigFileName = 'desktop_window.json';
  static const String _vodConfigCacheFileName = 'cached_vod_config.json';
  static const String _historyFileName = 'history.json';
  static const String _favoritesFileName = 'favorites.json';

  /// 配置源凭据（按主机）：与订阅地址分开存，换地址不影响已记住的账号。
  static const String _configCredentialsFileName = 'config_credentials.json';

  /// 直播收藏单独落盘（§33）：与点播收藏刻意不共用文件 —— 两者的模型、失效判定
  /// 和点击行为都不同（点播要点详情，直播要直接起播），混存会让任一侧的格式演进
  /// 变成另一侧的迁移风险。
  static const String _liveFavoritesFileName = 'live_favorites.json';

  /// 站源订阅（§新功能）：用户维护的远程配置订阅列表。
  static const String _siteSubscriptionsFileName = 'site_subscriptions.json';

  /// 订阅拉取结果的本地缓存：订阅 id → 配置原文，离线 / 启动期合并时使用。
  static const String _subscriptionConfigsCacheFileName =
      'cached_subscription_configs.json';

  /// 追剧记录（§新功能）：关注的剧集列表与已知集数。
  static const String _followsFileName = 'follows.json';

  Directory? _baseDir;

  /// 存储目录路径（同步计算，不触盘）。
  ///
  /// 便携版默认是安装目录下的 `user_data`（安装目录不可写时回退 `%APPDATA%/XiugouTV`），
  /// 若用户在设置里选择了自定义目录，则由 [DataDirectoryManager] 在启动时解析并返回。
  /// 供不便等待异步 IO 的诊断展示等场景使用。
  static String storageDirectoryPath() => DataDirectoryManager.currentPath;

  /// 获取或初始化数据目录（便携版为 `<exe>/user_data`，只读安装目录回退 `%APPDATA%/XiugouTV`）
  Future<Directory> getStorageDirectory() async {
    if (_baseDir != null) return _baseDir!;

    final dir = Directory(storageDirectoryPath());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _baseDir = dir;
    return dir;
  }

  /// 读取 Windows 桌面窗口配置
  Future<DesktopWindowConfig> readWindowConfig() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _windowConfigFileName));
      if (!await file.exists()) {
        return const DesktopWindowConfig();
      }

      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        return const DesktopWindowConfig();
      }

      final map = jsonDecode(content) as Map<String, dynamic>;
      return DesktopWindowConfig.fromJson(map);
    } catch (_) {
      return const DesktopWindowConfig();
    }
  }

  /// 保存 Windows 桌面窗口配置（原子写入）
  Future<void> saveWindowConfig(DesktopWindowConfig config) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _windowConfigFileName);
    await _atomicWrite(targetPath, jsonEncode(config.toJson()));
  }

  /// 读取本地缓存的影视配置 (VodConfig)
  Future<VodConfig?> readCachedVodConfig() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _vodConfigCacheFileName));
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      return VodConfig.parseRawString(content);
    } catch (_) {
      return null;
    }
  }

  /// 读取本地缓存的影视配置原文（用于导出；不存在时返回 null）
  Future<String?> readCachedVodConfigRaw() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _vodConfigCacheFileName));
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return content.trim().isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  /// 缓存影视配置到本地文件
  Future<void> saveCachedVodConfig(String rawConfigContent) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _vodConfigCacheFileName);
    await _atomicWrite(targetPath, rawConfigContent);
  }

  /// 仅文件不存在时回退旧格式；读取失败不能将旧订阅误判为当前来源。
  Future<ConfigSnapshot?> readCurrentConfig() async {
    final dir = await getStorageDirectory();
    final file = File(p.join(dir.path, 'current_config.json'));
    if (!await file.exists()) return null;
    return ConfigSnapshot.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  /// 删除当前配置快照与旧版缓存（卸载配置时用；文件不存在视为成功）
  Future<void> deleteCurrentConfig() async {
    final dir = await getStorageDirectory();
    for (final name in ['current_config.json', _vodConfigCacheFileName]) {
      final file = File(p.join(dir.path, name));
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> saveCurrentConfig(ConfigSnapshot snapshot) async {
    final dir = await getStorageDirectory();
    await _atomicWrite(
        p.join(dir.path, 'current_config.json'), jsonEncode(snapshot.toJson()));
  }

  /// 读取配置源凭据（按主机）。
  ///
  /// 坏条目跳过、整份损坏时返回空表：凭据缺失只影响下一次加载需要重新输入，
  /// 不该让启动失败。
  Future<List<ConfigCredentials>> readConfigCredentials() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _configCredentialsFileName));
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return decoded
          .map(ConfigCredentials.tryFromJson)
          .whereType<ConfigCredentials>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveConfigCredentials(
      List<ConfigCredentials> credentials) async {
    final dir = await getStorageDirectory();
    await _atomicWrite(
        p.join(dir.path, _configCredentialsFileName),
        jsonEncode(credentials.map((entry) => entry.toJson()).toList()));
  }

  Future<Map<String, HomeSitePreference>> readHomeSitePreferences() async {
    final dir = await getStorageDirectory();
    final file = File(p.join(dir.path, 'home_site_preferences.json'));
    if (!await file.exists()) return {};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['sources'] is! Map) {
      throw const FormatException('首页站源偏好格式无效');
    }
    final preferences = <String, HomeSitePreference>{};
    for (final entry in (decoded['sources'] as Map).entries) {
      final identity = entry.key;
      final preference = HomeSitePreference.tryFromJson(entry.value);
      if (identity is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(identity) ||
          preference == null) {
        throw const FormatException('首页站源偏好条目无效');
      }
      preferences[identity] = preference;
    }
    return preferences;
  }

  Future<void> saveHomeSitePreferences(
      Map<String, HomeSitePreference> preferences) async {
    final dir = await getStorageDirectory();
    await _atomicWrite(
        p.join(dir.path, 'home_site_preferences.json'),
        jsonEncode({
          'version': 1,
          'sources':
              preferences.map((key, value) => MapEntry(key, value.toJson())),
        }),
        throwWhenBlocked: true);
  }

  /// 本次运行中「没能读成功」的数据文件名。
  ///
  /// 读失败时内存里只能得到空表，而调用方并不知道自己拿到的是空表还是真表 ——
  /// 于是下一次落盘会把空表写回磁盘，把**本来还能手工修的原文件彻底抹掉**。
  /// 这里记下文件名，由 [_atomicWrite] 拒绝覆盖（与 [dataRestorePendingRestart]
  /// 同一类保护），UI 通过 [unreadableDataFiles] 如实告知用户。
  final Set<String> _unreadableFiles = <String>{};

  /// 结构损坏因而本轮禁止覆盖写的数据文件名（如 history.json）。
  Set<String> get unreadableDataFiles => Set<String>.unmodifiable(_unreadableFiles);

  /// 撤销 history.json 的覆盖保护。
  ///
  /// 只给「清空历史」这种**用户明确要求把文件抹掉**的动作使用：此时覆盖正是意图，
  /// 不是数据事故；其余写入（后台进度落盘等）一律保持保护。
  void allowHistoryOverwrite() => _unreadableFiles.remove(_historyFileName);

  /// 读取「顶层是数组」的持久化文件，逐条容错。
  ///
  /// 口径与偏好文件一致：文件不存在 / 内容为空 = 正常空表；其余任何读取或解析
  /// 失败都视为「这份文件不可信」，返回空表但把它登记进 [unreadableDataFiles]，
  /// 后续禁止覆盖写。单条坏数据只丢那一条，不牵连整表。
  ///
  /// [isMeaningful] 用来丢掉「解析成功但没法用」的条目（例如缺 id 的记录：
  /// 既定位不到影片，也会让去重/取消收藏这类按 id 查找的操作互相打架）。
  Future<List<T>> _readTolerantList<T>(
    String fileName,
    T Function(Map<String, dynamic> json) fromJson, {
    bool Function(T item)? isMeaningful,
  }) async {
    List<dynamic>? decoded;
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, fileName));
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];
      final raw = jsonDecode(content);
      if (raw is! List) throw const FormatException('顶层结构不是数组');
      decoded = raw;
    } catch (_) {
      _unreadableFiles.add(fileName);
      return [];
    }
    final items = <T>[];
    for (final entry in decoded.whereType<Map<String, dynamic>>()) {
      try {
        final item = fromJson(entry);
        if (isMeaningful == null || isMeaningful(item)) items.add(item);
      } catch (_) {
        // 单条坏数据不影响其余。
      }
    }
    return items;
  }

  /// 读取播放历史记录列表
  Future<List<HistoryRecord>> readHistory() => _readTolerantList(
        _historyFileName,
        HistoryRecord.fromJson,
        // id 是「同影片同选集共用一条」的键；空 id 既续不了播也删不掉。
        isMeaningful: (record) => record.id.isNotEmpty,
      );

  /// 保存播放历史记录列表
  Future<void> saveHistory(List<HistoryRecord> records) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _historyFileName);
    final jsonList = records.map((e) => e.toJson()).toList();
    // 历史是纯后台写入、丢了最多回退一个节流周期，没必要每次强制刷盘。
    // 原子性由「写 tmp + rename」保证，与 flush 无关（rename 在 Windows 上
    // 走 MOVEFILE_REPLACE_EXISTING，不会写出半截文件）。
    await _atomicWrite(targetPath, jsonEncode(jsonList), flush: false);
  }

  /// 读取收藏列表
  Future<List<VodItem>> readFavorites() => _readTolerantList(
        _favoritesFileName,
        VodItem.fromJson,
        // 收藏按 id 判重与取消（isFavorite / toggleFavorite），空 id 会互相打架。
        isMeaningful: (item) => item.id.isNotEmpty,
      );

  /// 保存收藏列表
  Future<void> saveFavorites(List<VodItem> items) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _favoritesFileName);
    final jsonList = items.map((e) => e.toJson()).toList();
    await _atomicWrite(targetPath, jsonEncode(jsonList),
        throwWhenBlocked: true);
  }

  /// 读取直播收藏（§33）。
  ///
  /// 坏条目跳过而不是整份丢弃：直播源换地址很常见，一条残缺记录不该让
  /// 其余收藏一起消失。缺 `url` 的条目直接判无效（点它必然播放失败）。
  Future<List<Live>> readLiveFavorites() => _readTolerantList(
        _liveFavoritesFileName,
        Live.fromJson,
        // 缺 url 的频道点下去必然播放失败，判为无效。
        isMeaningful: (live) => live.url.isNotEmpty,
      );

  /// 保存直播收藏。
  Future<void> saveLiveFavorites(List<Live> items) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _liveFavoritesFileName);
    final jsonList = items.map((e) => e.toJson()).toList();
    await _atomicWrite(targetPath, jsonEncode(jsonList),
        throwWhenBlocked: true);
  }

  /// 读取站源订阅列表。坏条目跳过（单条订阅格式异常不该让整份丢失）。
  Future<List<SiteSubscription>> readSiteSubscriptions() => _readTolerantList(
        _siteSubscriptionsFileName,
        SiteSubscription.fromJson,
        isMeaningful: (sub) => sub.url.isNotEmpty,
      );

  /// 保存站源订阅列表（用户主动操作，落盘受阻时抛错）。
  Future<void> saveSiteSubscriptions(List<SiteSubscription> items) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _siteSubscriptionsFileName);
    final jsonList = items.map((e) => e.toJson()).toList();
    await _atomicWrite(targetPath, jsonEncode(jsonList), throwWhenBlocked: true);
  }

  /// 读取订阅配置缓存（订阅 id → 配置原文）。
  Future<Map<String, String>> readSubscriptionConfigCache() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _subscriptionConfigsCacheFileName));
      if (!await file.exists()) return {};
      final content = await file.readAsString();
      if (content.trim().isEmpty) return {};
      final decoded = jsonDecode(content);
      if (decoded is! Map) return {};
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key as String] = entry.value as String;
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  /// 保存订阅配置缓存。
  Future<void> saveSubscriptionConfigCache(Map<String, String> cache) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _subscriptionConfigsCacheFileName);
    await _atomicWrite(targetPath, jsonEncode(cache));
  }

  /// 读取追剧记录。
  Future<List<FollowRecord>> readFollows() => _readTolerantList(
        _followsFileName,
        FollowRecord.fromJson,
        // 缺 vodId 的记录查不到剧集更新，留着只会是一条永远不动的条目。
        isMeaningful: (record) => record.vodId.isNotEmpty,
      );

  /// 保存追剧记录（原子写）。
  Future<void> saveFollows(List<FollowRecord> items) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _followsFileName);
    final jsonList = items.map((e) => e.toJson()).toList();
    await _atomicWrite(targetPath, jsonEncode(jsonList), throwWhenBlocked: true);
  }

  static int _temporarySequence = 0;

  Future<void> _atomicWrite(String filePath, String content,
      {bool throwWhenBlocked = false, bool flush = true}) async {
    // 数据恢复完成后禁止落盘，避免旧内存快照覆盖刚恢复的文件；重启后解除。
    // 收藏 / 首页站源是用户主动操作：抛出让调用方提示「本次修改未保存」；
    // 历史 / 窗口属于后台写入，保持静默跳过，不打断播放。
    if (dataRestorePendingRestart) {
      if (throwWhenBlocked) {
        throw const DataRestorePendingRestartException();
      }
      return;
    }
    // 同一类保护：这份文件本轮没能读成功，内存里的空表不代表用户的真实数据，
    // 写下去就是覆盖。后台写静默跳过，用户主动的写抛错、由 UI 如实提示。
    final fileName = p.basename(filePath);
    if (_unreadableFiles.contains(fileName)) {
      if (throwWhenBlocked) {
        throw const DataUnreadableException();
      }
      return;
    }
    final tempFile = File('$filePath.tmp-$pid-${++_temporarySequence}');
    try {
      await tempFile.writeAsString(content, flush: flush);
      await tempFile.rename(filePath);
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {
        // 清理失败不能掩盖原始保存异常。
      }
    }
  }
}

/// 数据文件本轮没能读成功，为保留原文件而拒绝覆盖写。
///
/// 这不是磁盘故障，而是**保护性失败**：内存里那份空表是读失败的产物，
/// 写下去就会把原本还能手工修的文件抹掉。
class DataUnreadableException implements Exception {
  static const String messageText =
      '数据文件没能读成功，为保留原文件已停止写入；请关闭应用后修复或删除该文件再启动';

  const DataUnreadableException();

  String get message => messageText;

  @override
  String toString() => messageText;
}
