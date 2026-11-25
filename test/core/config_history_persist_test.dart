import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiugou_tv/core/config/config_repository.dart';
import 'package:xiugou_tv/core/config/models/history_record.dart';
import 'package:xiugou_tv/core/config/windows_config_storage.dart';

/// 可控落盘：第一次 `saveHistory` 卡住，用来构造「写入在途时又来改动」的窗口。
class _GatedStorage extends WindowsConfigStorage {
  _GatedStorage(this.dir);

  final Directory dir;
  final Completer<void> gate = Completer<void>();
  int saves = 0;

  @override
  Future<Directory> getStorageDirectory() async => dir;

  @override
  Future<void> saveHistory(List<HistoryRecord> records) async {
    saves++;
    if (saves == 1) await gate.future;
    await super.saveHistory(records);
  }
}

HistoryRecord _record(String vodId, int positionMs) => HistoryRecord(
      id: HistoryRecord.buildId(vodId, '第1集'),
      vodId: vodId,
      vodName: '影片$vodId',
      vodPic: '',
      episodeName: '第1集',
      sourceName: '源',
      playUrl: 'http://example.com/$vodId.mp4',
      siteKey: 'site',
      timestamp: 1700000000000,
      positionMs: positionMs,
    );

void main() {
  group('ConfigRepository 历史落盘', () {
    test('写入在途时到达的改动会被补写，不被旧快照吃掉', () async {
      final dir = await Directory.systemTemp.createTemp('cfg_history');
      addTearDown(() => dir.delete(recursive: true));
      final storage = _GatedStorage(dir);
      final repo = ConfigRepository(storage: storage);

      final first = repo.addHistory(_record('A', 1000));
      // 让第一次写入真的取到快照并进入在途状态。
      await Future<void>.delayed(Duration.zero);
      final second = repo.addHistory(_record('B', 2000));
      storage.gate.complete();
      await first;
      await second;

      final file = File(p.join(dir.path, 'history.json'));
      final onDisk = jsonDecode(file.readAsStringSync()) as List;
      expect(onDisk.map((e) => (e as Map)['vodId']), containsAll(['A', 'B']),
          reason: 'B 落在 A 的写入期间；复用旧快照就等于把 B 丢了');

      // 合并语义不能退化成「每次改动排一次队」：静置后的连续操作仍应各自落盘。
      expect(storage.saves, greaterThanOrEqualTo(2));
    });

    test('等待方拿到的是最终落盘结果，中途失败会如实抛出', () async {
      final dir = await Directory.systemTemp.createTemp('cfg_history_fail');
      addTearDown(() => dir.delete(recursive: true));
      final storage = _ThrowingStorage(dir);
      final repo = ConfigRepository(storage: storage);

      await expectLater(
        repo.addHistory(_record('A', 1000)),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}

class _ThrowingStorage extends WindowsConfigStorage {
  _ThrowingStorage(this.dir);

  final Directory dir;

  @override
  Future<Directory> getStorageDirectory() async => dir;

  @override
  Future<void> saveHistory(List<HistoryRecord> records) async {
    throw const FileSystemException('磁盘已满');
  }
}
