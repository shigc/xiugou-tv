import 'package:flutter/material.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 生产构建下的 widget 崩溃占位（替代 Flutter 默认的红屏）。
///
/// 桌面端影音应用里，红色错误页既刺眼又对用户毫无帮助——用户看不懂堆栈，
/// 也不知道该怎么办。这里只给一句人话 + 去哪看日志。
///
/// 这是最后一道防线，所以它自己绝不能再抛异常：颜色一律从主题取，
/// 取不到就用中性回退色，也不碰任何可能为空的上下文。
class AppCrashPlaceholder extends StatelessWidget {
  const AppCrashPlaceholder({super.key, this.details});

  /// 框架给的原始错误信息（当前只用于调试，不展示给用户）。
  final FlutterErrorDetails? details;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>();
    final background = palette?.panel ?? const Color(0xFF16181D);
    final title = palette?.textMain ?? const Color(0xFFE8EAED);
    final sub = palette?.textSub ?? const Color(0xFF9AA0AA);
    final accent = palette?.danger ?? const Color(0xFFE5484D);
    return Container(
      color: background,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 26, color: accent),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '这个界面出了点问题',
            style: TextStyle(
              color: title,
              fontSize: AppType.body,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '已记入「设置 → 关于 → 错误日志」',
            textAlign: TextAlign.center,
            style: TextStyle(color: sub, fontSize: AppType.caption),
          ),
        ],
      ),
    );
  }
}
