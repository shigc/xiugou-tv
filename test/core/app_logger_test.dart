import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiugou_tv/core/diagnostics/app_logger.dart';

AppLogger makeLogger(String path, {int maxFileBytes = AppLogger.defaultMaxBytes}) =>
    AppLogger(
      pathOverride: path,
      consoleMinLevel: AppLogLevel.fatal, // 测试里不刷控制台
      maxFileBytes: maxFileBytes,
      now: () => DateTime(2026, 11, 25, 22, 55, 29, 123),
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('app_logger_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('级别按严重程度排序，标签可反查', () {
    expect(AppLogLevel.debug.priority, lessThan(AppLogLevel.info.priority));
    expect(AppLogLevel.info.includes(AppLogLevel.error), isTrue);
    expect(AppLogLevel.warning.includes(AppLogLevel.info), isFalse);
    expect(AppLogLevel.fromLabel('WARN'), AppLogLevel.warning);
    expect(AppLogLevel.fromLabel('NOPE'), isNull);
  });

  test('各级别都进内存，按级别可筛选，超出上限丢最旧', () {
    final logger = makeLogger(p.join(tempDir.path, 'app.log'));
    // 用注入的小上限重新建一个实例（上限是构造参数）
    final limited = AppLogger(
      pathOverride: p.join(tempDir.path, 'limited.log'),
      consoleMinLevel: AppLogLevel.fatal,
      maxMemoryEntries: 3,
    );
    limited.debug('test', 'd');
    limited.info('test', 'i');
    limited.warning('test', 'w');
    limited.error('test', 'e');

    expect(limited.entries.length, 3);
    expect(limited.entries.map((e) => e.message), ['i', 'w', 'e']);
    expect(
      limited.entries.where((e) => e.level == AppLogLevel.error).length,
      1,
    );
    expect(logger.isEmpty, isTrue);
  });

  test('写文件、读文件与脱敏：URL 查询串和凭据不落盘', () {
    final path = p.join(tempDir.path, 'app.log');
    final logger = makeLogger(path);
    logger.info('api', 'GET https://example.com/vod?id=1');
    logger.error(
      'auth',
      'token=abcdef123456 失败',
      detail: 'Authorization: Bearer secret-value',
    );

    final file = File(path);
    expect(file.existsSync(), isTrue);
    final raw = file.readAsStringSync();
    expect(raw, contains('[INFO ] [api] GET https://example.com/vod?…'));
    expect(raw, contains('token=…'));
    expect(raw, contains('Authorization: …'));
    expect(raw, isNot(contains('abcdef123456')));
    expect(raw, isNot(contains('secret-value')));

    final loaded = logger.readFile();
    expect(loaded.length, 2);
    expect(loaded.first.level, AppLogLevel.info);
    expect(loaded.last.level, AppLogLevel.error);
    expect(loaded.last.detail, contains('Authorization: …'));
  });

  test('文件超过上限时滚动到 .1，读取仍能看到两代日志', () {
    final path = p.join(tempDir.path, 'app.log');
    final logger = makeLogger(path, maxFileBytes: 300);
    for (var i = 0; i < 12; i++) {
      logger.info('rotate', '第 $i 条日志，内容足够长以触发滚动滚动滚动');
    }

    expect(File(path).existsSync(), isTrue);
    expect(File('$path.1').existsSync(), isTrue);
    expect(File(path).lengthSync(), lessThanOrEqualTo(300 + 200));
    final loaded = logger.readFile();
    expect(loaded.length, greaterThanOrEqualTo(4));
    expect(loaded.every((e) => e.message.startsWith('第 ')), isTrue);
  });

  test('clear 只清内存，clearFile 连文件与备份一起清', () {
    final path = p.join(tempDir.path, 'app.log');
    final logger = makeLogger(path, maxFileBytes: 300);
    for (var i = 0; i < 12; i++) {
      logger.info('clear', '日志 $i 内容长一点长一点长一点长一点');
    }
    logger.clear();
    expect(logger.isEmpty, isTrue);
    expect(File(path).existsSync(), isTrue);

    expect(logger.clearFile(), isTrue);
    expect(File(path).readAsStringSync(), isEmpty);
    expect(File('$path.1').existsSync(), isFalse);
    expect(logger.readFile(), isEmpty);
  });
}
