import 'dart:async';

import '../companion/companion_spider_api.dart';

/// 起播失败原因的口径：把底层异常翻译成人话，并保证「companion 进程故障」
/// 不再和「这个源本来就没地址」共用同一句文案。
///
/// 完整异常（含 companion 的 `detail`）由调用方写进 `[resolve]` 日志，
/// 这里只产出失败面板放得下的部分。
String describePlaybackFailure(Object error) {
  if (error is CompanionRpcException) {
    final stage = error.stage;
    return (stage == null || stage.isEmpty)
        ? error.message
        : '${error.message}（$stage）';
  }
  if (error is TimeoutException) {
    final seconds = error.duration?.inSeconds;
    return seconds == null ? '解析超时' : '解析超时（${seconds}s）';
  }
  final text = error is FormatException ? error.message : error.toString();
  return clipFailureReason(text);
}

/// 截断单条原因，避免长异常文本把面板挤满。
String clipFailureReason(String text, {int maxChars = 80}) =>
    text.length > maxChars ? '${text.substring(0, maxChars)}…' : text;

/// 多条线路的失败原因去重后最多列两条（面板只有两行），其余折成「共 N 类原因」。
String joinFailureReasons(Iterable<String> reasons) {
  if (reasons.isEmpty) return '';
  final text = clipFailureReason(reasons.take(2).join('；'), maxChars: 60);
  return reasons.length > 2 ? '$text（共 ${reasons.length} 类原因）' : text;
}
