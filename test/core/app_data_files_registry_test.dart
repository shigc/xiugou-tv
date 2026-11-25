import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiugou_tv/core/storage/app_data_files.dart';
import 'package:xiugou_tv/core/storage/data_backup_service.dart';
import 'package:xiugou_tv/core/storage/models/data_backup.dart';

/// 刻意不登记进注册表的名字，以及为什么可以不登记。
const Set<String> _notDataDirFiles = {
  // 自定义数据目录指针：按设计只存在于默认目录，迁移它们等于自我引用。
  'data_location.json',
  'data_location_pending.json',
  // 「下次启动清空」的一次性标记，用完即删。
  'reset_pending.json',
  // 视频缓存任务目录内的分片元数据，不在数据目录根上。
  'meta.json',
};

/// 扫描 lib/ 里出现过的 `*.json` 字面量。
///
/// 之所以用源码扫描而不是抄一份名单：注册表漏登记**不会报错**，只会让文件
/// 悄悄掉出「数据目录迁移 / 孤儿临时文件清理 / 备份白名单」之外
/// （2026-11-03 就是这么漏掉了 follows.json、site_subscriptions.json 等 8 个文件）。
Set<String> _persistedJsonNames() {
  final lib = Directory('lib');
  if (!lib.existsSync()) return {};
  final pattern = RegExp(r"'([a-z0-9_]+\.json)'");
  final registry = p.joinAll(['lib', 'core', 'storage', 'app_data_files.dart']);
  final names = <String>{};
  for (final entity in lib.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    // 注册表自身不算：它抄一遍名字不能证明「这个文件真的会落盘」，
    // 写错的条目反而会因为自己的字面量而通过检查。
    if (p.equals(p.normalize(entity.path), p.normalize(registry))) continue;
    for (final match in pattern.allMatches(entity.readAsStringSync())) {
      names.add(match.group(1)!);
    }
  }
  return names;
}

void main() {
  group('数据文件注册表', () {
    test('lib 里落盘的 json 文件都必须登记（或明确说明为何不登记）', () {
      final names = _persistedJsonNames();
      if (names.isEmpty) {
        markTestSkipped('需要在包根目录运行（找不到 lib/）');
        return;
      }
      final missing = names
          .where((name) =>
              !appDataFileNames.contains(name) &&
              !_notDataDirFiles.contains(name))
          .toList()
        ..sort();
      expect(missing, isEmpty,
          reason: '这些文件会掉出迁移与备份白名单：$missing');
    });

    test('注册表里没有凭名字推测出来的条目', () {
      final names = _persistedJsonNames();
      if (names.isEmpty) {
        markTestSkipped('需要在包根目录运行（找不到 lib/）');
        return;
      }
      // 名字写错进不了备份也进不了迁移，而扫描能发现「代码里根本没有这个文件」。
      final ghosts = appDataFileNames.difference(names).toList()..sort();
      expect(ghosts, isEmpty, reason: '注册表里的名字在 lib/ 中找不到：$ghosts');
    });

    test('可再生缓存与窗口 / 外观不进备份，用户清单必须进', () {
      final backedUp = backupAppDataFiles.map((file) => file.name).toSet();
      expect(backedUp, isNot(contains('desktop_window.json')));
      expect(backedUp, isNot(contains('appearance_preferences.json')));
      expect(backedUp, isNot(contains('cached_subscription_configs.json')));
      expect(backedUp, isNot(contains('update_cache.json')));
      expect(backedUp, isNot(contains('update_mirror_health.json')));
      for (final name in [
        'follows.json',
        'site_subscriptions.json',
        'live_last.json',
        'video_cache_preferences.json',
        'update_preferences.json',
      ]) {
        expect(backedUp, contains(name),
            reason: '$name 是用户留下的东西，换机后要在');
      }
    });
  });

  group('备份校验', () {
    test('每个备份白名单文件都有自己的校验分支', () async {
      final dir = await Directory.systemTemp.createTemp('data_files_backup');
      addTearDown(() => dir.delete(recursive: true));
      final service = DataBackupService(directory: () async => dir);

      // 用空内容喂给校验器：每个 case 都会拒绝它（解析不出对象、或本身判空），
      // 唯独「没有对应 case」会报「不允许的备份文件」。
      // 后者会让用户导出成功、换机时整份备份被拒，所以这条必须钉住。
      const blank = '';
      final entry = {
        'size': utf8.encode(blank).length,
        'sha256': sha256.convert(utf8.encode(blank)).toString(),
        'content': blank,
      };

      for (final file in backupAppDataFiles) {
        final backupFile = File(p.join(dir.path, '${file.name}.backup.json'));
        await backupFile.writeAsString(jsonEncode({
          'format': DataBackup.format,
          'version': DataBackup.version,
          'createdAt': DateTime.utc(2026, 11, 3).toIso8601String(),
          'files': {file.name: entry},
        }));

        Object? caught;
        try {
          await service.readBackupFile(backupFile.path);
        } catch (error) {
          caught = error;
        }
        expect(caught, isA<DataBackupException>(),
            reason: '${file.name} 的坏内容应当被拒');
        final message = (caught as DataBackupException).message;
        expect(message, isNot(contains('不允许的备份文件')),
            reason: '${file.name} 在 _validateEntry 里没有对应 case：$message');
      }
    });
  });
}
