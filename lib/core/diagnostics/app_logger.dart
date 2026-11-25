import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../storage/data_directory_manager.dart';
import 'log_redaction.dart';

/// 日志级别；数值越大越严重，[minLevel] / UI 筛选都按这个顺序比较。
enum AppLogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warning(2, 'WARN'),
  error(3, 'ERROR'),
  fatal(4, 'FATAL');

  const AppLogLevel(this.priority, this.label);

  final int priority;
  final String label;

  bool includes(AppLogLevel other) => other.priority >= priority;

  static AppLogLevel? fromLabel(String label) {
    for (final level in AppLogLevel.values) {
      if (level.label == label) return level;
    }
    return null;
  }
}

/// 一条结构化日志。
class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.detail,
  });

  final DateTime time;
  final AppLogLevel level;
  final String tag;
  final String message;
  final String? detail;

  String get timeText {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${three(time.millisecond)}';
  }

  /// 文件 / 复制用的单行摘要。
  String get summary => '[${level.label.padRight(5)}] [$tag] $message';

  @override
  String toString() => '${time.toIso8601String()} $summary'
      '${detail == null || detail!.isEmpty ? '' : '\n${detail!.split('\n').map((l) => '    $l').join('\n')}'}';
}

/// 应用统一日志：分级 + 内存环形缓冲 + 文件落盘。
///
/// 设计约束（与 `CompanionLog` 一致）：
/// - 日志永远不能影响主流程：所有 IO 异常静默吞掉；
/// - 每行先过 [redact] 脱敏，URL 查询串 / token / Cookie / 密码不落盘；
/// - 文件放在 [DataDirectoryManager.currentPath]/app.log，单文件上限 2 MB，
///   超出滚动成 `app.log.1`，总占用有界；
/// - 内存中最多保留 [maxMemoryEntries] 条，设置页「日志」用 [ListenableBuilder] 实时刷新。
///
/// `app.log` 是诊断缓存（和 `companion.log` 一样可再生），刻意不进
/// `appDataFiles` 注册表，也不进备份白名单；路径每次动态读取，用户改数据目录后重启生效。
class AppLogger extends ChangeNotifier {
  AppLogger({
    this.pathOverride,
    this.maxMemoryEntries = 1000,
    this.maxFileBytes = defaultMaxBytes,
    this.maxLineLength = 4000,
    this.maxStackLines = 20,
    this.consoleMinLevel = AppLogLevel.info,
    String Function(String text)? redact,
    DateTime Function()? now,
  })  : _redact = redact ?? redactLogText,
        _now = now ?? DateTime.now;

  /// 应用生命周期内一份；与 ErrorLog / CompanionLog 的单例风格保持一致。
  static final AppLogger instance = AppLogger();

  static const int defaultMaxBytes = 2 * 1024 * 1024;

  static const String fileName = 'app.log';

  static String defaultPath() => p.join(DataDirectoryManager.currentPath, fileName);

  final String? pathOverride;
  final int maxMemoryEntries;
  final int maxFileBytes;
  final int maxLineLength;
  final int maxStackLines;

  /// 仍然镜像到控制台的最低级别（debug 只进内存 / 文件，避免刷屏）。
  final AppLogLevel consoleMinLevel;

  final String Function(String text) _redact;
  final DateTime Function() _now;
  final List<AppLogEntry> _entries = [];

  static final RegExp _linePattern = RegExp(
      r'^(\S+)\s+\[(DEBUG|INFO|WARN|ERROR|FATAL)\s*\]\s+\[([^\]]*)\]\s(.*)$');

  /// 实际文件路径（每次读取，用户改数据目录重启后自动生效）。
  String get path => pathOverride ?? defaultPath();
  String get rotatedPath => '$path.1';

  List<AppLogEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;

  int get sizeBytes {
    try {
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  void debug(String tag, String message, {Object? error, StackTrace? stack, String? detail}) =>
      log(AppLogLevel.debug, tag, message, error: error, stack: stack, detail: detail);

  void info(String tag, String message, {Object? error, StackTrace? stack, String? detail}) =>
      log(AppLogLevel.info, tag, message, error: error, stack: stack, detail: detail);

  void warning(String tag, String message, {Object? error, StackTrace? stack, String? detail}) =>
      log(AppLogLevel.warning, tag, message, error: error, stack: stack, detail: detail);

  void error(String tag, String message, {Object? error, StackTrace? stack, String? detail}) =>
      log(AppLogLevel.error, tag, message, error: error, stack: stack, detail: detail);

  void fatal(String tag, String message, {Object? error, StackTrace? stack, String? detail}) =>
      log(AppLogLevel.fatal, tag, message, error: error, stack: stack, detail: detail);

  void log(
    AppLogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
    String? detail,
  }) {
    final text = _redact(message.trim());
    if (text.isEmpty) return;

    final entry = AppLogEntry(
      time: _now(),
      level: level,
      tag: tag,
      message: text,
      detail: _buildDetail(detail, error, stack),
    );

    _entries.add(entry);
    if (_entries.length > maxMemoryEntries) {
      _entries.removeRange(0, _entries.length - maxMemoryEntries);
    }
    notifyListeners();

    if (consoleMinLevel.includes(level)) {
      debugPrint(entry.toString());
    }
    _write(entry);
  }

  String? _buildDetail(String? detail, Object? error, StackTrace? stack) {
    final parts = <String>[];
    if (detail != null && detail.trim().isNotEmpty) parts.add(detail.trimRight());
    if (error != null) parts.add('异常：$error');
    if (stack != null) {
      final lines = '$stack'.trimRight().split('\n').where((l) => l.trim().isNotEmpty).toList();
      parts.add([
        ...lines.take(maxStackLines).map((l) => l.trimRight()),
        if (lines.length > maxStackLines) '…（其余 ${lines.length - maxStackLines} 行已省略）',
      ].join('\n'));
    }
    if (parts.isEmpty) return null;
    return _redact(parts.join('\n'));
  }

  String _formatEntry(AppLogEntry entry) {
    final buffer = StringBuffer(entry.toString());
    if (!buffer.toString().endsWith('\n')) buffer.writeln();
    return buffer.toString();
  }

  void _write(AppLogEntry entry) {
    try {
      final text = _formatEntry(entry);
      final file = File(path);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      _rotateIfNeeded(utf8.encode(text).length);
      file.writeAsStringSync(text, mode: FileMode.append, flush: false);
    } catch (_) {
      // 只读盘 / 目录被占用 / 权限不足：日志失败不影响播放与登录
    }
  }

  void _rotateIfNeeded(int incomingBytes) {
    if (incomingBytes <= 0) return;
    final size = sizeBytes;
    if (size == 0 || size + incomingBytes <= maxFileBytes) return;
    final file = File(path);
    final backup = File(rotatedPath);
    try {
      if (backup.existsSync()) backup.deleteSync();
      file.renameSync(backup.path);
    } catch (_) {
      try {
        file.writeAsStringSync('', flush: false);
      } catch (_) {}
    }
  }

  /// 从文件读取日志（含上一份 `.1`），按时间从旧到新，最多 [maxEntries] 条。
  List<AppLogEntry> readFile({int maxEntries = 500}) {
    final lines = <String>[];
    for (final file in [File(rotatedPath), File(path)]) {
      try {
        if (file.existsSync()) lines.addAll(file.readAsLinesSync());
      } catch (_) {}
    }

    final result = <AppLogEntry>[];
    DateTime? time;
    AppLogLevel? level;
    String? tag;
    String? message;
    final detail = <String>[];

    void flush() {
      if (time == null || level == null || tag == null || message == null) return;
      result.add(AppLogEntry(
        time: time!,
        level: level!,
        tag: tag!,
        message: message!,
        detail: detail.isEmpty ? null : detail.join('\n'),
      ));
      time = null;
      level = null;
      tag = null;
      message = null;
      detail.clear();
    }

    for (final line in lines) {
      final match = _linePattern.firstMatch(line);
      if (match != null) {
        flush();
        time = DateTime.tryParse(match.group(1)!) ?? DateTime.now();
        level = AppLogLevel.fromLabel(match.group(2)!.trim());
        tag = match.group(3);
        message = match.group(4);
        continue;
      }
      if (message != null && line.trim().isNotEmpty) detail.add(line.trimLeft());
    }
    flush();
    if (result.length <= maxEntries) return List.unmodifiable(result);
    return List.unmodifiable(result.getRange(result.length - maxEntries, result.length));
  }

  /// 清空内存日志（文件保留；要连文件一起清用 [clearFile]）。
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// 清空落盘日志（含滚动备份），返回是否成功。
  bool clearFile() {
    try {
      final backup = File(rotatedPath);
      if (backup.existsSync()) backup.deleteSync();
      final file = File(path);
      if (file.existsSync()) file.writeAsStringSync('', flush: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 复制 / 导出用的多行文本。
  static String formatEntries(Iterable<AppLogEntry> entries) =>
      entries.map((e) => e.toString()).join('\n');
}
