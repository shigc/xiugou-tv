import 'package:flutter/material.dart';

/// 应用语义调色板。
///
/// UI 层不再直接写 `Color(0x…)`：所有颜色都从这里取，切换主题时整棵树一起变。
/// 深色表取现有界面的实际色值（同一语义的多个近似值已归并到最常见的一个）；
/// 浅色表是新增的一套中性灰 + 品牌暖橙。
///
/// **品牌色 2026-10-19 二轮：冷色两级**（backlog §11 / `docs/ACCENT_COLOR_PLAN.md` §11）。
/// 深色填充 `#414A5B` / 前景 `#94A3B8`；浅色填充 `#D8E3F8`（浅蓝）/ 前景 `#334155`。
///
/// 规则：**填充用 `accent`，前景（图标 / 文字 / 进度条 / 选中描边）用 `accentInk`。**
/// 冷色填充两头都不能当文字：深色 `#414A5B` 在深底上只有 2.23:1（看不见），
/// 浅色 `#D8E3F8` 在浅底上只有 1.29:1（同样看不见）——所以前景必须单独一层。
/// 压在填充上的文字走 `colorScheme.onPrimary`：深色主题白（8.92:1）、浅色主题深蓝灰
/// `#2A3550`（9.44:1，浅底深字）。`onAccent` 即浅色主题下压在填充上的文字色，
/// 随预设色相变化（经典蓝灰为 `#2A3550`）。
/// 红只保留给「危险」与「直播中」（复用 `danger`），海报角标等装饰性标签与品牌色解耦。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  /// 窗口 / 页面底色
  final Color background;

  /// 分区面板底（设置页左栏、页面容器）
  final Color panel;

  /// 卡片底
  final Color card;

  /// 比卡片更高一层的浮起块（输入框、列表项）
  final Color raised;

  /// 边框
  final Color border;

  /// 更强的分隔线 / 选中描边
  final Color borderStrong;

  /// 细分割线
  final Color divider;

  /// 标题文字（白）
  final Color textTitle;

  /// 正文主色
  final Color textMain;

  /// 次级正文
  final Color textBody;

  /// 说明文字
  final Color textSub;

  /// 弱提示（v1.0.6 起与其它文字色一样在 background/panel/card/raised 上 ≥4.5:1，
  /// 由 test/palette_contrast_test.dart 守门）
  final Color textDim;

  /// 品牌色（**填充**用）：主按钮底、选中胶囊底、播放按钮底
  final Color accent;

  /// 品牌色（**前景**用）：图标 / 链接 / 进度条 / 选中描边
  ///
  /// 冷灰填充太暗（深色下 `#414A5B` 在页面底上只有 2.23:1），当文字/图标会直接消失，
  /// 所以品牌色分两级：填充 [`accent`] + 前景 [`accentInk`]（同一色相、亮一档）。
  final Color accentInk;

  /// 品牌底色纹（选中行背景 / 图标块）
  final Color accentWash;

  /// 持久选中态，与中性悬停底色区分。
  final Color selectionFill;
  final Color selectionInk;
  final Color onSelectionInk;

  /// 配置源编辑框的实色选区，与输入框底色区分，同时保留正文的字色。
  final Color sourceInputSelection;

  /// 危险 / 错误
  final Color danger;

  /// 成功
  final Color success;

  /// 警告
  final Color warning;

  /// hover 底
  final Color hover;

  /// 按下 / 选中底
  final Color pressed;

  /// 壁纸遮罩（深色黑 / 浅色白）
  final Color scrim;

  /// 播放器 OSD 面板
  final Color playerChrome;

  /// 播放器 OSD 文字
  final Color playerText;

  /// 浅色主题下，压在 `accent` 填充上的文字色（即 `colorScheme.onPrimary` 的浅色档）。
  ///
  /// 深色主题下压在填充上的永远是白色；浅色主题则取此值（深一档的同色相），
  /// 以保证白字压浅填充（如 `#D8E3F8`）1.2:1 不可读的硬伤不再出现。
  final Color onAccent;

  const AppPalette({
    required this.background,
    required this.panel,
    required this.card,
    required this.raised,
    required this.border,
    required this.borderStrong,
    required this.divider,
    required this.textTitle,
    required this.textMain,
    required this.textBody,
    required this.textSub,
    required this.textDim,
    required this.accent,
    required this.accentInk,
    required this.accentWash,
    required this.selectionFill,
    required this.selectionInk,
    required this.onSelectionInk,
    required this.sourceInputSelection,
    required this.danger,
    required this.success,
    required this.warning,
    required this.hover,
    required this.pressed,
    required this.scrim,
    required this.playerChrome,
    required this.playerText,
    required this.onAccent,
  });

  /// 经典蓝灰（改造前的默认观感，保持逐字节一致）。
  static const AppPalette dark = AppPalette(
    background: Color(0xFF101014),
    panel: Color(0xFF15151E),
    card: Color(0xFF1B1B25),
    raised: Color(0xFF202026),
    border: Color(0xFF262634),
    borderStrong: Color(0xFF2E2E3C),
    divider: Color(0xFF242430),
    textTitle: Color(0xFFFFFFFF),
    textMain: Color(0xFFE6E6F0),
    textBody: Color(0xFFBCBCCA),
    textSub: Color(0xFFA2A2B0),
    textDim: Color(0xFF9292A0),
    accent: Color(0xFF414A5B),
    accentInk: Color(0xFF94A3B8),
    accentWash: Color(0xFF232632),
    selectionFill: Color(0xFF163A60),
    selectionInk: Color(0xFF83C4FF),
    onSelectionInk: Color(0xFF101014),
    sourceInputSelection: Color(0xFF3568AD),
    danger: Color(0xFFF05252),
    success: Color(0xFF4CAF50),
    warning: Color(0xFFFFB300),
    hover: Color(0xFF2A2A38),
    pressed: Color(0xFF323242),
    scrim: Color(0x8C000000),
    playerChrome: Color(0xCC000000),
    playerText: Color(0xFFFFFFFF),
    onAccent: Color(0xFF2A3550),
  );

  /// 经典蓝灰（浅色）。
  static const AppPalette light = AppPalette(
    background: Color(0xFFF5F5F8),
    panel: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    raised: Color(0xFFF0F0F5),
    border: Color(0xFFE2E2EA),
    borderStrong: Color(0xFFD2D2DC),
    divider: Color(0xFFE8E8EF),
    textTitle: Color(0xFF14141A),
    textMain: Color(0xFF1B1B22),
    textBody: Color(0xFF3A3A46),
    textSub: Color(0xFF5B5B6C),
    textDim: Color(0xFF6A6A7C),
    accent: Color(0xFFD8E3F8),
    accentInk: Color(0xFF334155),
    accentWash: Color(0xFFE4EBFA),
    selectionFill: Color(0xFFC5D9F8),
    selectionInk: Color(0xFF1D4ED8),
    onSelectionInk: Color(0xFFFFFFFF),
    sourceInputSelection: Color(0xFF6688CC),
    danger: Color(0xFFC62828),
    success: Color(0xFF2E7D32),
    warning: Color(0xFF925800),
    hover: Color(0xFFEDEDF3),
    pressed: Color(0xFFE3E3EC),
    scrim: Color(0x8CFFFFFF),
    playerChrome: Color(0xE6FFFFFF),
    playerText: Color(0xFF1B1B22),
    onAccent: Color(0xFF2A3550),
  );

  /// 用一组「中性底 + 品牌色」旋钮生成一套调色板；文字 / 状态色随明暗自动推导，
  /// 保证各预设在可读性与语义上保持一致，只换「底色倾向」与「品牌色相」。
  ///
  /// 非 const 工厂：用于除经典外的预设，结果存入 [themePresets]（运行时 final 列表）。
  static AppPalette preset({
    required bool dark,
    required Color background,
    required Color panel,
    required Color card,
    required Color raised,
    required Color border,
    required Color borderStrong,
    required Color divider,
    required Color accent,
    required Color accentInk,
    required Color accentWash,
    required Color onAccent,
    required Color scrim,
    required Color playerChrome,
    required Color playerText,
  }) {
    return AppPalette(
      background: background,
      panel: panel,
      card: card,
      raised: raised,
      border: border,
      borderStrong: borderStrong,
      divider: divider,
      textTitle: dark ? Colors.white : const Color(0xFF14141A),
      textMain: dark ? const Color(0xFFE6E6F0) : const Color(0xFF1B1B22),
      textBody: dark ? const Color(0xFFB0B0C0) : const Color(0xFF3A3A46),
      textSub: dark ? const Color(0xFF888898) : const Color(0xFF5B5B6C),
      textDim: dark ? const Color(0xFF66667A) : const Color(0xFF8A8A9A),
      accent: accent,
      accentInk: accentInk,
      accentWash: accentWash,
      danger: dark ? const Color(0xFFEF4444) : const Color(0xFFC62828),
      success: dark ? const Color(0xFF4CAF50) : const Color(0xFF2E7D32),
      warning: dark ? const Color(0xFFFFB300) : const Color(0xFFB26A00),
      hover: dark ? const Color(0xFF2A2A38) : const Color(0xFFEDEDF3),
      pressed: dark ? const Color(0xFF323242) : const Color(0xFFE3E3EC),
      scrim: scrim,
      playerChrome: playerChrome,
      playerText: playerText,
      onAccent: onAccent,
      selectionFill: dark ? const Color(0xFF163A60) : const Color(0xFFC5D9F8),
      selectionInk: dark ? const Color(0xFF83C4FF) : const Color(0xFF1D4ED8),
      onSelectionInk: dark ? const Color(0xFF101014) : const Color(0xFFFFFFFF),
      sourceInputSelection:
          dark ? const Color(0xFF3568AD) : const Color(0xFF6688CC),
    );
  }

  /// 取当前主题的调色板；没有注入时回退深色（避免测试与半初始化场景崩溃）。
  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? dark;

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      background: mix(background, other.background),
      panel: mix(panel, other.panel),
      card: mix(card, other.card),
      raised: mix(raised, other.raised),
      border: mix(border, other.border),
      borderStrong: mix(borderStrong, other.borderStrong),
      divider: mix(divider, other.divider),
      textTitle: mix(textTitle, other.textTitle),
      textMain: mix(textMain, other.textMain),
      textBody: mix(textBody, other.textBody),
      textSub: mix(textSub, other.textSub),
      textDim: mix(textDim, other.textDim),
      accent: mix(accent, other.accent),
      accentInk: mix(accentInk, other.accentInk),
      accentWash: mix(accentWash, other.accentWash),
      selectionFill: mix(selectionFill, other.selectionFill),
      selectionInk: mix(selectionInk, other.selectionInk),
      onSelectionInk: mix(onSelectionInk, other.onSelectionInk),
      sourceInputSelection: mix(sourceInputSelection, other.sourceInputSelection),
      danger: mix(danger, other.danger),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      hover: mix(hover, other.hover),
      pressed: mix(pressed, other.pressed),
      scrim: mix(scrim, other.scrim),
      playerChrome: mix(playerChrome, other.playerChrome),
      playerText: mix(playerText, other.playerText),
      onAccent: mix(onAccent, other.onAccent),
    );
  }
}

/// 一套可切换的「配色主题」预设：自带深色与浅色两套调色板，
/// 明暗由 `AppThemeMode` 决定，预设只决定色相与底色倾向。
class AppThemePreset {
  /// 持久化键（写入 `appearance_preferences.json` 的 `themePreset`）。
  final String name;

  /// 设置页展示名。
  final String label;

  /// 深色调色板。
  final AppPalette dark;

  /// 浅色调色板。
  final AppPalette light;

  const AppThemePreset({
    required this.name,
    required this.label,
    required this.dark,
    required this.light,
  });
}

/// 全部配色预设；顺序即设置页展示顺序。首项为默认（经典蓝灰）。
final List<AppThemePreset> themePresets = [
  const AppThemePreset(
      name: 'classic', label: '经典蓝灰', dark: AppPalette.dark, light: AppPalette.light),
  AppThemePreset(
    name: 'midnight',
    label: '午夜紫',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF0E0E16),
      panel: const Color(0xFF141420),
      card: const Color(0xFF1A1A2A),
      raised: const Color(0xFF21212F),
      border: const Color(0xFF2A2A3A),
      borderStrong: const Color(0xFF34344A),
      divider: const Color(0xFF23232F),
      accent: const Color(0xFF5A4FA0),
      accentInk: const Color(0xFFB7A9E8),
      accentWash: const Color(0xFF241F3C),
      onAccent: const Color(0xFF2A2350),
      scrim: const Color(0x8C05050F),
      playerChrome: const Color(0xCC05050F),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFF3F2FA),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFECEAF6),
      border: const Color(0xFFE1DCEF),
      borderStrong: const Color(0xFFD0C9E4),
      divider: const Color(0xFFE8E5F3),
      accent: const Color(0xFFE6E1F7),
      accentInk: const Color(0xFF4A3F87),
      accentWash: const Color(0xFFECE8F8),
      onAccent: const Color(0xFF2A2350),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
  AppThemePreset(
    name: 'sunset',
    label: '暖阳橙',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF15110B),
      panel: const Color(0xFF1C1812),
      card: const Color(0xFF241E16),
      raised: const Color(0xFF2B241A),
      border: const Color(0xFF332B1F),
      borderStrong: const Color(0xFF3D3325),
      divider: const Color(0xFF2A2319),
      accent: const Color(0xFFB5792E),
      accentInk: const Color(0xFFE8B878),
      accentWash: const Color(0xFF33271A),
      onAccent: const Color(0xFF3D2A12),
      scrim: const Color(0x8C0A0703),
      playerChrome: const Color(0xCC0A0703),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFFBF6EF),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFF4ECDD),
      border: const Color(0xFFEADFCB),
      borderStrong: const Color(0xFFDBCBB0),
      divider: const Color(0xFFF2E9DA),
      accent: const Color(0xFFF2E3C8),
      accentInk: const Color(0xFFA8661F),
      accentWash: const Color(0xFFF6ECCF),
      onAccent: const Color(0xFF5A3A14),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
  AppThemePreset(
    name: 'forest',
    label: '森野绿',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF0C130F),
      panel: const Color(0xFF111A14),
      card: const Color(0xFF16211A),
      raised: const Color(0xFF1C2820),
      border: const Color(0xFF243029),
      borderStrong: const Color(0xFF2C3A31),
      divider: const Color(0xFF1A241E),
      accent: const Color(0xFF3E8C5A),
      accentInk: const Color(0xFF8FD4A6),
      accentWash: const Color(0xFF1C3326),
      onAccent: const Color(0xFF123524),
      scrim: const Color(0x8C030806),
      playerChrome: const Color(0xCC030806),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFF1F7F2),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFE5F1E8),
      border: const Color(0xFFD6E6DA),
      borderStrong: const Color(0xFFC2D8C9),
      divider: const Color(0xFFEAF2EC),
      accent: const Color(0xFFDCEFDD),
      accentInk: const Color(0xFF2E7D4F),
      accentWash: const Color(0xFFE4F2E6),
      onAccent: const Color(0xFF123524),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
  AppThemePreset(
    name: 'rose',
    label: '蔷薇粉',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF140C11),
      panel: const Color(0xFF1A1218),
      card: const Color(0xFF211721),
      raised: const Color(0xFF281C28),
      border: const Color(0xFF302230),
      borderStrong: const Color(0xFF3A283A),
      divider: const Color(0xFF231823),
      accent: const Color(0xFFA84A7A),
      accentInk: const Color(0xFFE2A0C4),
      accentWash: const Color(0xFF331F2E),
      onAccent: const Color(0xFF3D1230),
      scrim: const Color(0x8C0A0307),
      playerChrome: const Color(0xCC0A0307),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFFBF2F6),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFF7E8EF),
      border: const Color(0xFFEFD9E2),
      borderStrong: const Color(0xFFE0C3D0),
      divider: const Color(0xFFF4E8EE),
      accent: const Color(0xFFF4DCE7),
      accentInk: const Color(0xFFA23A6E),
      accentWash: const Color(0xFFF8E4EE),
      onAccent: const Color(0xFF5A1438),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
  AppThemePreset(
    name: 'ocean',
    label: '深海青',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF0A1014),
      panel: const Color(0xFF0F181E),
      card: const Color(0xFF14222A),
      raised: const Color(0xFF1A2A33),
      border: const Color(0xFF21323C),
      borderStrong: const Color(0xFF29404C),
      divider: const Color(0xFF18272F),
      accent: const Color(0xFF2E8C9C),
      accentInk: const Color(0xFF8FD6DE),
      accentWash: const Color(0xFF163038),
      onAccent: const Color(0xFF0E333A),
      scrim: const Color(0x8C02080A),
      playerChrome: const Color(0xCC02080A),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFF0F7F9),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFE3F0F3),
      border: const Color(0xFFD2E3E8),
      borderStrong: const Color(0xFFBED4DB),
      divider: const Color(0xFFEAF3F5),
      accent: const Color(0xFFDCEFEF),
      accentInk: const Color(0xFF1F7E8C),
      accentWash: const Color(0xFFE4F3F4),
      onAccent: const Color(0xFF0E333A),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
  AppThemePreset(
    name: 'aurora',
    label: '极光蓝紫',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF08131A),
      panel: const Color(0xFF0D1B25),
      card: const Color(0xFF122634),
      raised: const Color(0xFF19303F),
      border: const Color(0xFF203B4C),
      borderStrong: const Color(0xFF2A4B60),
      divider: const Color(0xFF172C39),
      accent: const Color(0xFF4F6FD8),
      accentInk: const Color(0xFFA5C1FF),
      accentWash: const Color(0xFF1C2B4F),
      onAccent: const Color(0xFF14224A),
      scrim: const Color(0x8C020A10),
      playerChrome: const Color(0xCC020A10),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFF0F6FA),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFE4F0F7),
      border: const Color(0xFFD3E4EE),
      borderStrong: const Color(0xFFBDD4E2),
      divider: const Color(0xFFE7F1F6),
      accent: const Color(0xFFD9E6FF),
      accentInk: const Color(0xFF3157A8),
      accentWash: const Color(0xFFE6EEFF),
      onAccent: const Color(0xFF14224A),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
  AppThemePreset(
    name: 'cocoa',
    label: '摩卡棕',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF120E0B),
      panel: const Color(0xFF19130F),
      card: const Color(0xFF211914),
      raised: const Color(0xFF2A201A),
      border: const Color(0xFF33271F),
      borderStrong: const Color(0xFF3E3026),
      divider: const Color(0xFF291F18),
      accent: const Color(0xFFA9744F),
      accentInk: const Color(0xFFE6B88E),
      accentWash: const Color(0xFF332317),
      onAccent: const Color(0xFF3A2110),
      scrim: const Color(0x8C080502),
      playerChrome: const Color(0xCC080502),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFFAF5EF),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFF3E9DC),
      border: const Color(0xFFE7D8C6),
      borderStrong: const Color(0xFFD7C2A9),
      divider: const Color(0xFFF1E7DB),
      accent: const Color(0xFFF0DFC8),
      accentInk: const Color(0xFF8A542E),
      accentWash: const Color(0xFFF7EADA),
      onAccent: const Color(0xFF3A2110),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
  AppThemePreset(
    name: 'graphite',
    label: '石墨钢蓝',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF0B0E12),
      panel: const Color(0xFF11161C),
      card: const Color(0xFF171E26),
      raised: const Color(0xFF1E2731),
      border: const Color(0xFF28323E),
      borderStrong: const Color(0xFF34404E),
      divider: const Color(0xFF1E2730),
      accent: const Color(0xFF54657A),
      accentInk: const Color(0xFFAEC3DB),
      accentWash: const Color(0xFF222E3B),
      onAccent: const Color(0xFF1C2733),
      scrim: const Color(0x8C020406),
      playerChrome: const Color(0xCC020406),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFF2F4F7),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFE6EAF0),
      border: const Color(0xFFD9DFE7),
      borderStrong: const Color(0xFFC6CFDA),
      divider: const Color(0xFFEBEEF3),
      accent: const Color(0xFFDCE5EF),
      accentInk: const Color(0xFF3B5068),
      accentWash: const Color(0xFFE8EEF5),
      onAccent: const Color(0xFF1C2733),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
  AppThemePreset(
    name: 'neon',
    label: '霓虹电光',
    dark: AppPalette.preset(
      dark: true,
      background: const Color(0xFF070B14),
      panel: const Color(0xFF0C1220),
      card: const Color(0xFF111A2C),
      raised: const Color(0xFF172338),
      border: const Color(0xFF20304A),
      borderStrong: const Color(0xFF2B3F5E),
      divider: const Color(0xFF16233A),
      accent: const Color(0xFFB52BA6),
      accentInk: const Color(0xFFFF8FE6),
      accentWash: const Color(0xFF351234),
      onAccent: const Color(0xFF2A0730),
      scrim: const Color(0x8C050010),
      playerChrome: const Color(0xCC050010),
      playerText: const Color(0xFFFFFFFF),
    ),
    light: AppPalette.preset(
      dark: false,
      background: const Color(0xFFFAF2FA),
      panel: const Color(0xFFFFFFFF),
      card: const Color(0xFFFFFFFF),
      raised: const Color(0xFFF4E4F2),
      border: const Color(0xFFEBD3E7),
      borderStrong: const Color(0xFFDDB4D6),
      divider: const Color(0xFFF4E9F2),
      accent: const Color(0xFFF3D8F0),
      accentInk: const Color(0xFF9B237F),
      accentWash: const Color(0xFFF9E8F6),
      onAccent: const Color(0xFF2A0730),
      scrim: const Color(0x8CFFFFFF),
      playerChrome: const Color(0xE6FFFFFF),
      playerText: const Color(0xFF1B1B22),
    ),
  ),
];

/// 按持久化键取预设；非法 / 缺失时回退默认（经典蓝灰）。
AppThemePreset themePresetByName(String? name) {
  if (name == null) return themePresets.first;
  for (final preset in themePresets) {
    if (preset.name == name) return preset;
  }
  return themePresets.first;
}

/// 取色简写：`context.palette.textMain`。
///
/// 大文件里逐处写 `AppPalette.of(context)` 太长，统一用这个入口；
/// 语义与 [`AppPalette.of`] 完全一致（无注入时回退深色）。
extension AppPaletteContext on BuildContext {
  AppPalette get palette => AppPalette.of(this);

  /// 微透高光边框（Infuse 风格 1px 细线，深色微白透，浅色微黑透）
  Color get glassBorder => Theme.of(this).brightness == Brightness.dark
      ? const Color(0x1FFFFFFF)
      : const Color(0x12000000);

  /// 侧边栏背景（比主窗口背景略显沉静的精致面板色）
  Color get sidebarBackground => Theme.of(this).brightness == Brightness.dark
      ? const Color(0xFF131318)
      : const Color(0xFFFFFFFF);

  /// 磨砂胶囊底色（海报左上角角标/评分胶囊，保持高对比固定半透深底）
  Color get glassPill => const Color(0x99000000);
}
