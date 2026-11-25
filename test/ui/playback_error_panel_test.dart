import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/player/models/player_state.dart';
import 'package:xiugou_tv/ui/desktop/player/playback_error_panel.dart';
import 'package:xiugou_tv/ui/theme/app_palette.dart';
import 'package:xiugou_tv/ui/theme/app_theme.dart';

void main() {
  Widget buildPanel({VoidCallback? onRetry, String? rawError}) => MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark, palette: AppPalette.dark),
        home: Scaffold(
          body: Center(
            child: PlaybackErrorPanel(
              rawError: rawError ?? 'tcp: ffurl_write returned 0xffffd8ba',
              spec: const MediaPlaySpec(
                  url: 'https://vip.dytt-tvs.com/20261025/42704_e1ee630d/index.m3u8'),
              engineLogs: const ['[error] tcp: ffurl_read returned 0xffffd8ba'],
              onRetry: onRetry,
            ),
          ),
        ),
      );

  testWidgets('错误面板可关闭，且换了新错误会重新弹出', (tester) async {
    await tester.pumpWidget(buildPanel());
    await tester.pumpAndSettle();

    // 面板在
    expect(find.text('详情'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    // 点关闭 → 面板消失
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsNothing);

    // 同一个错误不重复弹出（关掉就是关掉了）
    await tester.pumpWidget(buildPanel());
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsNothing);

    // 换了新错误 → 重新弹出
    await tester.pumpWidget(
        buildPanel(rawError: 'tcp: ffurl_read returned 0xffffd8bb'));
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsOneWidget);
  });

  testWidgets('传了 onRetry 才显示「重试」，点击会触发回调', (tester) async {
    var retried = 0;
    await tester.pumpWidget(buildPanel(onRetry: () => retried++));
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(retried, 1);
  });

  testWidgets('不传 onRetry 时不显示重试按钮', (tester) async {
    await tester.pumpWidget(buildPanel());
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsNothing);
  });
}
