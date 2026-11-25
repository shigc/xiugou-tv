import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiugou_tv/core/cache/video_cache_store.dart';
import 'package:xiugou_tv/core/player/models/player_state.dart';
import 'package:xiugou_tv/core/settings/models/video_cache_preferences.dart';

/// S2 回归：缓存容量上限必须真的能生效。
///
/// 此前 `_lastKnownSizeBytes` 恒为 0（没有任何调用方喂过真实占用），于是
/// 「超限淘汰」和「超限停止写入」两条路径永远不触发：上限形同虚设，缓存能
/// 无上限地涨。修法是让下载器在任务开始时自己量一次真实占用。
void main() {
  group('VideoCacheStore 容量上限（本地 HttpServer）', () {
    late Directory tempDir;
    late HttpServer server;
    late VideoCacheStore store;
    late String url;
    late List<String> requested;
    var segCount = 2;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cache_test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'http://127.0.0.1:${server.port}/index.m3u8';
      store = VideoCacheStore();
      requested = [];
      segCount = 2;
      final segPattern = RegExp(r'^/seg(\d+)\.ts$');
      server.listen((req) async {
        final path = req.uri.path;
        final segMatch = segPattern.firstMatch(path);
        if (path == '/index.m3u8') {
          final segNames =
              List.generate(segCount, (i) => '#EXTINF:5.0,\nseg$i.ts\n').join();
          req.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          req.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:5\n'
              '$segNames#EXT-X-ENDLIST\n');
          await req.response.close();
        } else if (segMatch != null &&
            int.parse(segMatch.group(1)!) < segCount) {
          requested.add(path);
          req.response.add(List.generate(32, (i) => i));
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
    });

    tearDown(() async {
      await store.dispose();
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// 造一个只有元数据大小的稀疏文件（NTFS 上 truncate 是纯元数据操作），
    /// 让单测能廉价地逼近 GB 级的真实上限。
    Future<void> seed(String path, int bytes, {DateTime? modified}) async {
      final file = File(path);
      await file.create(recursive: true);
      final raf = await file.open(mode: FileMode.write);
      await raf.truncate(bytes);
      await raf.close();
      if (modified != null) await file.setLastModified(modified);
    }

    String taskDir(String sourceUrl) => p.join(
        tempDir.path, crypto.sha1.convert(utf8.encode(sourceUrl)).toString());

    /// 起任务并等它落到终态（完成 / 出错）；start() 是后台任务，没有可 await 的句柄。
    Future<VideoCacheProgress> run({Duration? startPosition}) async {
      await store.applyPreferences(
        const VideoCachePreferences(maxSizeGb: 1),
        defaultRoot: tempDir.path,
      );
      final done = Completer<VideoCacheProgress>();
      final sub = store.progressStream.listen((progress) {
        if (!done.isCompleted && (progress.done || progress.error != null)) {
          done.complete(progress);
        }
      });
      await store.start(
          MediaPlaySpec(url: url, title: '测试片', startPosition: startPosition),
          defaultRoot: tempDir.path);
      final progress = await done.future.timeout(const Duration(seconds: 15));
      await sub.cancel();
      return progress;
    }

    test('超上限的老任务会被淘汰，新视频照常缓存', () async {
      const oldUrl = 'http://127.0.0.1:1/gone.m3u8';
      // 1.1 GiB 的旧剧集，已越过 1 GiB 上限；mtime 很旧。
      await seed(p.join(taskDir(oldUrl), 'old.ts'), 1181116006,
          modified: DateTime(2020));

      final progress = await run();

      expect(progress.done, isTrue, reason: '被上限拦住就不该算完成');
      expect(Directory(taskDir(oldUrl)).existsSync(), isFalse,
          reason: '超出上限的老任务必须被淘汰，否则新视频永远存不进来');
      expect(File(p.join(taskDir(url), 'seg_000000.ts')).lengthSync(), 32);
    });

    test('腾不出空间时如实停在「已达上限」，而不是无上限地写下去', () async {
      // 把 1.1 GiB 塞进**当前任务自己的目录**：它不参与淘汰，所以这次腾不出空间。
      await seed(p.join(taskDir(url), 'junk.ts'), 1181116006);

      final progress = await run();

      expect(progress.error, contains('上限'));
      expect(File(p.join(taskDir(url), 'seg_000000.ts')).existsSync(), isFalse,
          reason: '超限后不能再写入新分片');
    });

    test('起播位置在中间时，先下起播点之后、再回头补前缀', () async {
      // 引擎拖动后会用新的 startPosition 重新起任务（_reanchorCacheAfterSeek）。
      // 这里锁住 store 侧的契约：锚点必须跟着走，不能仍从片头一段段爬——
      // 那样用户拖到的位置一直在走网络，看起来就像「缓存开着却没生效」。
      segCount = 4;

      final progress = await run(startPosition: const Duration(seconds: 15));

      expect(progress.done, isTrue);
      expect(requested, ['/seg3.ts', '/seg0.ts', '/seg1.ts', '/seg2.ts'],
          reason: '15s 起播 = 第 4 片开始，前 3 片延后回填');
      expect(File(p.join(taskDir(url), 'seg_000003.ts')).lengthSync(), 32);
    });
  });
}
