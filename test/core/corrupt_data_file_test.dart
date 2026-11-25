import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiugou_tv/core/api/models/vod_models.dart';
import 'package:xiugou_tv/core/config/config_repository.dart';
import 'package:xiugou_tv/core/config/models/history_record.dart';
import 'package:xiugou_tv/core/config/windows_config_storage.dart';

/// 指向临时目录的存储驱动（`getStorageDirectory` 是本项目既有的注入点）。
class _TempStorage extends WindowsConfigStorage {
  _TempStorage(this.dir);

  final Directory dir;

  @override
  Future<Directory> getStorageDirectory() async => dir;
}

HistoryRecord _record(String vodId, {String? id}) => HistoryRecord(
      id: id ?? HistoryRecord.buildId(vodId, '第1集'),
      vodId: vodId,
      vodName: '影片$vodId',
      vodPic: '',
      episodeName: '第1集',
      sourceName: '源',
      playUrl: 'http://example.com/$vodId.mp4',
      timestamp: 1700000000000,
      positionMs: 1000,
    );

void main() {
  late Directory dir;
  late _TempStorage storage;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('corrupt_data');
    storage = _TempStorage(dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  void write(String name, String content) =>
      File(p.join(dir.path, name)).writeAsStringSync(content);

  String read(String name) => File(p.join(dir.path, name)).readAsStringSync();

  group('数据文件结构损坏', () {
    test('读失败的列表文件不会被下一次落盘覆盖', () async {
      // 截断的 JSON：现实里由手工编辑、杀毒软件改写或旧版本格式造成。
      const corrupt = '[{"vodId":"A","id":"A_第1集","vodName":"甲"';
      write('history.json', corrupt);

      final records = await storage.readHistory();

      expect(records, isEmpty);
      expect(storage.unreadableDataFiles, contains('history.json'),
          reason: '必须记住这次没读成功，否则调用方会把空表当成真实状态');

      // 后台写入（历史属于这一类）：静默跳过，但一个字节都不许动原文件。
      await storage.saveHistory([_record('B')]);
      expect(read('history.json'), corrupt,
          reason: '空表落盘会把本可手工修复的历史彻底抹掉');
    });

    test('用户主动的收藏写入如实抛错，而不是假装保存成功', () async {
      write('favorites.json', '{"不是":"数组"}');

      expect(await storage.readFavorites(), isEmpty);
      expect(storage.unreadableDataFiles, contains('favorites.json'));

      await expectLater(
        storage.saveFavorites([const VodItem(id: 'X', name: '乙', pic: '')]),
        throwsA(isA<DataUnreadableException>()),
      );
      expect(read('favorites.json'), '{"不是":"数组"}');
    });

    test('「清空历史」是明确的抹掉意图，可以越过保护', () async {
      write('history.json', '[broken');
      await storage.readHistory();
      final repo = ConfigRepository(storage: storage);

      await repo.clearHistory();

      expect(jsonDecode(read('history.json')), isEmpty,
          reason: '用户要求清空就必须真的写下去，否则下次开机历史又冒出来');
      expect(storage.unreadableDataFiles, isEmpty);
    });

    test('单个坏条目只丢那一条，整表照旧可用', () async {
      write(
        'history.json',
        jsonEncode([
          _record('A').toJson(),
          '不是对象',
          {'id': '', 'vodId': '', 'vodName': ''}, // 解析成功但没法用
          _record('C').toJson(),
        ]),
      );

      final records = await storage.readHistory();

      expect(records.map((e) => e.vodId), ['A', 'C']);
      expect(storage.unreadableDataFiles, isEmpty,
          reason: '逐条容错成功就不是「读失败」，不该禁止落盘');

      // 保护没生效时，落盘照旧进行。
      await storage.saveHistory(records);
      expect((jsonDecode(read('history.json')) as List).length, 2);
    });

    test('文件不存在与内容为空都是正常空表，不触发保护', () async {
      expect(await storage.readHistory(), isEmpty);
      write('favorites.json', '   ');
      expect(await storage.readFavorites(), isEmpty);
      expect(storage.unreadableDataFiles, isEmpty);

      await storage.saveHistory([_record('A')]);
      expect((jsonDecode(read('history.json')) as List).length, 1);
    });
  });
}
