import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'app.dart';
import 'core/app_info.dart';
import 'core/companion/companion_playback_lease.dart';
import 'core/companion/companion_process_manager.dart';
import 'core/config/config_repository.dart';
import 'core/config/models/builtin_sites.dart';
import 'core/diagnostics/app_logger.dart';
import 'core/diagnostics/error_log.dart';
import 'core/net/http_client_factory.dart';
import 'core/danmaku/danmaku_api.dart';
import 'core/player/mpv_player_engine.dart';
import 'core/settings/models/appearance_preferences.dart';
import 'core/settings/settings_repository.dart';
import 'core/storage/app_data_reset.dart';
import 'core/storage/data_directory_manager.dart';
import 'ui/desktop/widgets/app_crash_placeholder.dart';
import 'ui/desktop/window/desktop_window_manager.dart';
import 'ui/theme/app_icon_assets.dart';
import 'ui/theme/app_palette.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    final log = AppLogger.instance;
    // ⑥ 内存批：海报 / 台标等网络图解码缓存默认上限 100MB，收紧到 48MB；
    // 超出按 LRU 淘汰、重复浏览会再解码，换取常驻内存下降。
    PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;
    // 版本号读取与数据目录解析互不依赖，并行做掉，缩短 runApp 前的串行等待。
    String? versionLabel;
    await Future.wait<void>([
      () async {
        versionLabel = await loadAppVersionLabel();
      }(),
      () async {
        // 先解析数据目录并执行待定迁移，再创建任何存储（避免运行中双目录写入）。
        // 便携版默认目录是 exe 旁的 user_data，重置标记也放在默认目录，所以必须先解析。
        try {
          await DataDirectoryManager.initialize();
          log.info('startup', '数据目录：${DataDirectoryManager.currentPath}');
        } catch (error) {
          log.error('startup', '数据目录初始化失败', error: error);
        }
      }(),
    ]);
    log.info('startup', '启动，版本 ${versionLabel ?? '未知'}');
    // §43：可选服务是否启用（只记录是否配置，不记录地址 / 令牌）
    log.info('startup', '弹幕服务：${danmakuServiceConfigured ? '已配置' : '未配置（config/app.env）'}');

    // 关于页「重置所有设置」：上次会话安排的全部清空，在创建任何存储之前执行
    try {
      if (await AppDataReset.applyPendingAtStartup()) {
        log.info('startup', '已按上次的「重置所有设置」清空数据目录');
      }
    } catch (error) {
      log.error('startup', '重置所有设置失败', error: error);
    }

    // 关于页「错误日志」：本次运行期间的未捕获异常、框架错误、播放器报错，只放内存（关闭即清空）
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      ErrorLog.instance.record('界面', details.exception, details.stack,
          AppLogLevel.fatal);
      previousOnError?.call(details);
    };
    // FlutterError.onError 只接得住 widget 树内的框架错误。引擎回调、platform
    // channel、isolate 里的异步错误跑在 root zone，连 runZonedGuarded 都接不住——
    // 不挂这一层，最严重的崩溃恰恰是没记录的那批。
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      ErrorLog.instance.record('未捕获异常', error, stack, AppLogLevel.fatal);
      return true;
    };
    // 生产构建下 widget build 崩溃时给一块品牌化占位，而不是刺眼的红屏。
    ErrorWidget.builder = (details) => AppCrashPlaceholder(details: details);

    final configRepository = ConfigRepository(fallbackHomeSite: builtinDoubanSite);
    await configRepository.initialize();
    log.info('config', '配置已加载：${configRepository.currentVodConfig.sites.length} 个站源，'
        '${configRepository.currentVodConfig.lives.length} 个直播源');

    final settingsRepository = SettingsRepository();
    await settingsRepository.initialize(
      legacyHwdec: configRepository.currentWindowConfig.hardwareDecoding,
      legacyConfigUrl: configRepository.currentWindowConfig.lastConfigUrl,
    );
    // 应用生命周期内常驻：成功加载的 URL / 本地文件记入配置源历史
    settingsRepository.bindConfigRepository(configRepository);

    // SET-05：播放历史保留上限从设置同步一次（trim: false——启动不静默裁剪，见方案 §2.2）
    await configRepository.setHistoryLimit(
        settingsRepository.historyPreferences.limit,
        trim: false);
    // §14 无痕浏览：跟随历史偏好（流先给当前值，再推送设置页 / 重新读取后的变更）
    configRepository.setHistoryIncognito(settingsRepository.historyPreferences.incognito);
    settingsRepository.historyPreferencesStream.listen(
        (preferences) => configRepository.setHistoryIncognito(preferences.incognito));
    // §14 安全 DNS：未经工厂创建的 HttpClient（如普通海报 NetworkImage）也接管建连；
    // 选择跟随网络偏好实时切换（读取失败时偏好为默认「关闭」）。
    HttpClientFactory.installGlobalOverrides();
    HttpClientFactory.configureDoh(settingsRepository.networkPreferences.endpoint);
    settingsRepository.networkPreferencesStream.listen(
        (preferences) => HttpClientFactory.configureDoh(preferences.endpoint));

    final companionManager = CompanionProcessManager();
    // §59 站源直连被重置时改走 Windows 系统代理（只在系统代理开启时生效）
    companionManager.fallbackProxy = DanmakuApi.systemProxy;
    // 播放器先于窗口管理器创建：退出钩子要先停播放（窗口已隐藏，声音不能再继续）
    final playerEngine = MpvPlayerEngine();
    // 播放期间持有 companion 租约：网盘直链由本地代理持续传流，没有 RPC 可计时，
    // 旧实现约 30 分钟后把代理进程当空闲停掉，播放中段即断流。
    final playbackLease = CompanionPlaybackLease(
      statusStream: playerEngine.statusStream,
      manager: companionManager,
    );
    final windowManager = DesktopWindowManager(
      configRepository: configRepository,
      beforeClose: () async {
        log.info('startup', '退出清理：停止播放并关闭 companion');
        // 退出前先关掉语义树：窗口隐藏后 overlay portal（滑块 / Tooltip）的锚点会在
        // teardown 中被拆除，若无障碍桥仍开启，孤儿节点会让 AXTree 更新整批失败并刷屏。
        // 只在真正退出时关闭，不影响运行期屏幕阅读器。
        WidgetsBinding.instance.platformDispatcher.setSemanticsTreeEnabled(false);
        try {
          await playerEngine.stop().timeout(const Duration(milliseconds: 500));
        } catch (_) {
          // 停播失败 / 超时不阻断关闭：进程退出时 mpv 随之结束
        }
        await playbackLease.dispose();
        await companionManager.shutdown();
      },
    );
    // 首帧前按已保存主题给原生窗口底色，避免浅色主题启动时闪深色边
    final appearance = settingsRepository.appearancePreferences;
    final initialBrightness = switch (appearance.themeMode) {
      AppThemeMode.dark => Brightness.dark,
      AppThemeMode.light => Brightness.light,
      AppThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    final startupPalette = themePresetByName(appearance.themePreset);
    await windowManager.initialize(
      backgroundColor: initialBrightness == Brightness.dark
          ? startupPalette.dark.background
          : startupPalette.light.background,
      iconPath: appIconFilePath(),
    );
    log.info('startup', '窗口与设置初始化完成');

    // 冷启动有效主入口：启动偏好 +「上次入口」解析（失败按点播首页）
    final startupEntry = settingsRepository.startupPreferences.effectiveEntry;
    log.info('startup', '初始入口：${startupEntry.name}');

    // 初始化时捕获默认音量 / 倍速；之后只更新即时参数，不覆盖当前播放默认值
    unawaited(
        playerEngine.applyPlaybackSettings(settingsRepository.playerSettings));
    playerEngine.errorStream.listen((message) {
      if (message != null && message.trim().isNotEmpty) {
        ErrorLog.instance.record('播放器', message);
      }
    });
    settingsRepository.playerSettingsStream
        .skip(1)
        .listen(playerEngine.applyPlaybackSettings);

    // 视频本地缓存：默认根 = 数据目录/video_cache；偏好变化即时生效（目录 / 上限 / 开关）
    final cacheDefaultRoot =
        p.join(DataDirectoryManager.currentPath, 'video_cache');
    unawaited(playerEngine.applyCachePreferences(
        settingsRepository.videoCachePreferences,
        defaultRoot: cacheDefaultRoot));
    settingsRepository.videoCachePreferencesStream.skip(1).listen((prefs) {
      unawaited(playerEngine.applyCachePreferences(prefs,
          defaultRoot: cacheDefaultRoot));
    });

    runApp(
      ProviderScope(
        overrides: [
          configRepositoryProvider.overrideWithValue(configRepository),
          windowManagerProvider.overrideWithValue(windowManager),
          playerEngineProvider.overrideWithValue(playerEngine),
          settingsRepositoryProvider.overrideWithValue(settingsRepository),
          startupEntryProvider.overrideWithValue(startupEntry),
        ],
        child: const XiugouTvApp(),
      ),
    );

    log.info('player', '播放器初始化开始');
    unawaited(playerEngine.initialize());

    // 起播提速：把 JVM 冷启动挪出点播管线。此前 Spider 站首播要把
    // companion 懒启动（探端口 + 健康检查）整个算进用户等待；
    // 现在首帧渲染后空闲预热，30 分钟无使用仍会自动停用，回落懒启动。
    if (configRepository.currentVodConfig.sites.any((s) => s.usesCompanion)) {
      log.info('companion', '检测到爬虫站源，安排空闲预热');
      Timer(const Duration(milliseconds: 800), () {
        unawaited(companionManager.start());
      });
    }
  }, (error, stack) {
    // ErrorLog.record 会同时写内存与 app.log（fatal 级别），且不会向外抛异常。
    ErrorLog.instance.record('未捕获异常', error, stack, AppLogLevel.fatal);
  });
}
