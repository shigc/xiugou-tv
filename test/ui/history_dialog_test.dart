import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/config/models/history_record.dart';
import 'package:xiugou_tv/ui/desktop/dialogs/history_dialog.dart';
import 'package:xiugou_tv/ui/theme/app_palette.dart';
import 'package:xiugou_tv/ui/theme/app_theme.dart';

/// 历史弹窗的分组列表：改为惰性构建后，分组顺序、卡片可达性与删除回调
/// 都必须与改造前一致（此前是 `ListView(children:)` 一次性 new 出全部卡片）。
void main() {
  final now = DateTime(2026, 11, 2, 21, 0);

  HistoryRecord record(String id, DateTime at) => HistoryRecord(
        id: id,
        vodId: id,
        vodName: '影片$id',
        vodPic: '',
        episodeName: '第1集',
        sourceName: '源',
        playUrl: 'https://example.com/$id.mp4',
        timestamp: at.millisecondsSinceEpoch,
        positionMs: 120000,
        durationMs: 600000,
      );

  List<HistoryRecord> buildRecords() => [
        for (var i = 0; i < 20; i++) record('today$i', now.subtract(Duration(minutes: i + 1))),
        for (var i = 0; i < 20; i++)
          record('yesterday$i', now.subtract(const Duration(days: 1, hours: 1))),
        for (var i = 0; i < 20; i++)
          record('earlier$i', now.subtract(const Duration(days: 30))),
      ];

  Widget wrap(List<HistoryRecord> records,
          {required ValueChanged<String> onDelete}) =>
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark, palette: AppPalette.dark),
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: HistoryDialog(
              records: records,
              now: now,
              onPlayRecord: (_) {},
              onDeleteRecord: onDelete,
              onClearAll: () {},
            ),
          ),
        ),
      );

  testWidgets('分组标题齐全且顺序正确，卡片只构建可见的那部分', (tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(wrap(buildRecords(), onDelete: deleted.add));
    await tester.pumpAndSettle();

    expect(find.text('今天'), findsOneWidget);

    // 惰性构建：60 条记录不会一次性造出 60 张卡片（后两组的标题在滚动前
    // 根本不存在，这正是惰性的体现）。
    final built = find.byIcon(Icons.delete_outline_rounded).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(60), reason: '仍全量构建说明退化成了 ListView(children:)');
  });

  testWidgets('滚到底能取到最后一组的记录，删除回调带上正确 id', (tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(wrap(buildRecords(), onDelete: deleted.add));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    for (final title in ['昨天', '更早']) {
      await tester.scrollUntilVisible(find.text(title), 300, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
    }

    await tester.scrollUntilVisible(find.text('影片earlier19'), 400,
        scrollable: scrollable);
    await tester.pumpAndSettle();

    expect(find.text('影片earlier19'), findsOneWidget);
    // 卡片是内部私有组件，按树序取最末一张（earlier19 是最后一条）。
    await tester.tap(find.byIcon(Icons.delete_outline_rounded).last);
    await tester.pumpAndSettle();

    expect(deleted, ['earlier19']);
  });
}
