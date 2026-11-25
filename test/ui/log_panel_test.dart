import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiugou_tv/core/diagnostics/app_logger.dart';
import 'package:xiugou_tv/ui/desktop/settings/log_panel.dart';
import 'package:xiugou_tv/ui/theme/app_palette.dart';
import 'package:xiugou_tv/ui/theme/app_theme.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('log_panel_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('日志面板支持按级别筛选', (tester) async {
    final logger = AppLogger(
      pathOverride: p.join(tempDir.path, 'app.log'),
      consoleMinLevel: AppLogLevel.fatal,
    );
    logger.info('test', '这是一条 INFO 日志');
    logger.error('test', '这是一条 ERROR 日志');

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(brightness: Brightness.light, palette: AppPalette.light),
      home: Scaffold(body: LogPanel(log: logger)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('这是一条 INFO 日志'), findsOneWidget);
    expect(find.text('这是一条 ERROR 日志'), findsOneWidget);

    // 级别下拉：当前值为 null 的那个就是「全部级别」
    await tester.tap(find.byWidgetPredicate(
        (widget) => widget is DropdownButton && widget.value == null));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('log-level-ERROR')));
    await tester.pumpAndSettle();

    expect(find.text('这是一条 INFO 日志'), findsNothing);
    expect(find.text('这是一条 ERROR 日志'), findsOneWidget);
  });
}
