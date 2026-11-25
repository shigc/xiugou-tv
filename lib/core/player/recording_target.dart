import 'dart:io';

/// 录制文件目标路径计算（纯逻辑，可单测）。
///
/// mpv 的 `stream-record` 把**解复用前的原始字节流**原样写盘，因此扩展名
/// 必须匹配源容器：HLS（m3u8）实际是 TS 分片流，直链 mp4 是 mp4 字节流。
class RecordingTarget {
  RecordingTarget._();

  /// 根据播放 URL 推断录制文件扩展名。
  static String extensionFor(String url) {
    final path = url.split('?').first.toLowerCase();
    for (final ext in const ['.mp4', '.mkv', '.flv', '.webm', '.ts']) {
      if (path.endsWith(ext)) return ext.substring(1);
    }
    // m3u8 / 未识别来源统一按 MPEG-TS 落盘（绝大多数直播与点播流的实际容器）。
    return 'ts';
  }

  /// 文件名清洗：去路径分隔符与 Windows 非法字符，压空白，保留中文。
  static String sanitizeTitle(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '录制';
    // Windows 路径段上限 255 字符；按 UTF-16 码元保守截断。
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }

  /// 计算录制文件绝对路径：`{root}/xiugou-recordings/{title}_{stamp}.{ext}`。
  ///
  /// 同秒重复录制（罕见）追加序号，绝不覆盖既有文件。
  static String resolve({
    required String root,
    required String title,
    required String url,
    DateTime? now,
  }) {
    final ext = extensionFor(url);
    final safeTitle = sanitizeTitle(title);
    final stamp = formatStamp(now ?? DateTime.now());
    var path = '$root${_sep}xiugou-recordings$_sep$safeTitle-$stamp.$ext';
    var index = 2;
    final existing = File(path);
    if (existing.existsSync()) {
      do {
        path =
            '$root${_sep}xiugou-recordings$_sep$safeTitle-$stamp-$index.$ext';
        index++;
      } while (File(path).existsSync() && index < 100);
    }
    return path;
  }

  /// 时间戳：`yyyyMMdd-HHmmss`（文件名安全）。
  static String formatStamp(DateTime t) => '${t.year}${_two(t.month)}'
      '${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  static String _two(int v) => v.toString().padLeft(2, '0');
}

String get _sep => Platform.pathSeparator;
