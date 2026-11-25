/// 日志脱敏：所有落盘 / 展示的日志文本都必须先过这里。
///
/// 独立成文件是为了让 [AppLogger] 与 `ErrorLog` / `CompanionLog` 共用同一套规则，
/// 又不在诊断类之间形成循环依赖（ErrorLog.redact 保留为兼容入口，转调这里）。
library;

final RegExp _urlQuery = RegExp(r'(https?://[^\s?#"]+)\?[^\s"]*');

final RegExp _credential = RegExp(
  r'((?:token|authorization|cookie|password|passwd|secret)\s*[=:]\s*)(?:(?:bearer|basic)\s+)?[^\s,;&]+',
  caseSensitive: false,
);

/// 抹掉 URL 查询串与常见凭据字段，避免令牌 / Cookie / 密码进日志。
String redactLogText(String text) => text
    .replaceAllMapped(_urlQuery, (m) => '${m[1]}?…')
    .replaceAllMapped(_credential, (m) => '${m[1]}…');
