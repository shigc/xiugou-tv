import 'package:flutter/material.dart';
import '../window/desktop_window_manager.dart';
import '../../theme/app_palette.dart';
import 'desktop_title_bar.dart';
import 'media_title_bar.dart';

class DesktopWindowFrame extends StatelessWidget {
  final DesktopWindowManager windowManager;
  final Widget child;
  final String? activeSiteName;
  final String? activeSiteIcon;
  final Map<String, String>? activeSiteHeaders;
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onSiteSelectorPressed;
  final Widget? searchBar;
  final VoidCallback? onRefresh;
  final bool refreshBusy;
  final bool sidebarCollapsed;
  final VoidCallback? onSidebarToggle;
  final VoidCallback? onDetailBack;

  /// 播放页是否处于激活态（含起播准备态）。由上层同步传入，使窗口底色在
  /// 播放页第一帧就铺黑，避免依赖沉浸通知器（microtask 延迟）而闪出白底。
  final bool playerActive;

  const DesktopWindowFrame({
    super.key,
    required this.windowManager,
    required this.child,
    this.activeSiteName,
    this.activeSiteIcon,
    this.activeSiteHeaders,
    this.onSettingsPressed,
    this.onSiteSelectorPressed,
    this.searchBar,
    this.onRefresh,
    this.refreshBusy = false,
    this.sidebarCollapsed = false,
    this.onSidebarToggle,
    this.onDetailBack,
    this.playerActive = false,
  });

  static bool hasDetailBackButton(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DetailBackScope>()?.active ??
      false;

  Widget _titleBar() => DesktopTitleBar(
        windowManager: windowManager,
        activeSiteName: activeSiteName,
        activeSiteIcon: activeSiteIcon,
        activeSiteHeaders: activeSiteHeaders,
        onSettingsPressed: onSettingsPressed,
        onSiteSelectorPressed: onSiteSelectorPressed,
        searchBar: searchBar,
        onRefresh: onRefresh,
        refreshBusy: refreshBusy,
        sidebarCollapsed: sidebarCollapsed,
        onSidebarToggle: onSidebarToggle,
      );

  Widget _detailBar(VoidCallback onBack) {
    return MediaTitleBar(
      key: const ValueKey('detail-top-bar'),
      scope: 'detail',
      onBack: onBack,
      windowManager: windowManager,
      onTitleDoubleTap: windowManager.toggleMaximize,
      actions: [
        ValueListenableBuilder<bool>(
          valueListenable: windowManager.isAlwaysOnTopNotifier,
          builder: (_, pinned, _) => IconButton(
            tooltip: pinned ? '取消置顶' : '窗口置顶',
            icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 17, color: pinned ? AppPalette.dark.selectionInk : Colors.white),
            onPressed: windowManager.toggleAlwaysOnTop,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: windowManager.isPipNotifier,
      builder: (context, pip, _) => ValueListenableBuilder<bool>(
        valueListenable: windowManager.isImmersiveNotifier,
        builder: (context, immersive, _) {
          // §38：PiP 与「沉浸播放」都隐藏自绘标题栏（无边框）。
          //
          // 沉浸期间**不再**用「顶部热区滑出标题栏」：浮出的标题栏正好压在
          // 播放页顶栏的返回按钮上，用户点不到返回（2026-10-27 实机反馈）。
          // 现在标题栏彻底不渲染，窗口三键与拖动由播放页顶栏接管。
          final playing = pip || immersive;
          final hideTitleBar = playing;
          final detailBack = hideTitleBar ? null : onDetailBack;
          // 首帧背景：playerActive 由上层同步传入（不等沉浸通知器的 microtask），
          // 保证进入播放页的那一刻就是黑底，不再闪出浅色主题的白色窗口边框。
          final darkBackground = playing || playerActive;
          return Scaffold(
            // 视频播放期间窗口底色必须是纯黑：浅色主题的 background 会在
            // 视频 letterbox 之外的窗口边缘露出一圈白边（用户截图反馈）。
            backgroundColor:
                darkBackground ? const Color(0xFF000000) : palette.background,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // 固定内容槽位，切换普通顶栏、悬浮顶栏或沉浸模式时不重新挂载页面。
                Column(
                  children: [
                    if (!hideTitleBar && detailBack == null)
                      _titleBar()
                    else
                      const SizedBox.shrink(),
                    Expanded(child: _DetailBackScope(
                      active: detailBack != null, child: child,
                    )),
                  ],
                ),
                if (detailBack != null)
                  Positioned(
                    top: 0, left: 0, right: 0,
                    child: _detailBar(detailBack),
                  ),
                _WindowChromeSync(
                  windowManager: windowManager,
                  playerActive: playerActive,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 正文只在窗口没有接管返回时显示自己的按钮，独立弹窗仍可退出。
class _DetailBackScope extends InheritedWidget {
  const _DetailBackScope({required this.active, required super.child});
  final bool active;

  @override
  bool updateShouldNotify(_DetailBackScope oldWidget) => active != oldWidget.active;
}

/// 把当前主题的窗口底色同步给原生窗口（避免浅色下缩放窗口时闪黑边）。
class _WindowChromeSync extends StatefulWidget {
  final DesktopWindowManager windowManager;
  final bool playerActive;

  const _WindowChromeSync({
    required this.windowManager,
    required this.playerActive,
  });

  @override
  State<_WindowChromeSync> createState() => _WindowChromeSyncState();
}

class _WindowChromeSyncState extends State<_WindowChromeSync> {
  Color? _applied;

  @override
  void initState() {
    super.initState();
    // 沉浸播放 / 画中画切换时重新计算底色，避免浅色主题下窗口边缘透出白边。
    widget.windowManager.isImmersiveNotifier.addListener(_applyBackground);
    widget.windowManager.isPipNotifier.addListener(_applyBackground);
  }

  @override
  void dispose() {
    widget.windowManager.isImmersiveNotifier.removeListener(_applyBackground);
    widget.windowManager.isPipNotifier.removeListener(_applyBackground);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _WindowChromeSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playerActive != widget.playerActive) _applyBackground();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyBackground();
  }

  void _applyBackground() {
    if (!mounted) return;
    // 视频播放期间窗口底色必须是纯黑：浅色主题的 background 会在视频
    // letterbox 之外的窗口边缘露出一圈白边（用户截图反馈）。
    // 退出播放后恢复当前主题的正常底色。
    final playing = widget.playerActive ||
        widget.windowManager.isImmersiveNotifier.value ||
        widget.windowManager.isPipNotifier.value;
    final color = playing
        ? const Color(0xFF000000)
        : AppPalette.of(context).background;
    if (_applied != color) {
      _applied = color;
      widget.windowManager.applyBackgroundColor(color);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
