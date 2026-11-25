import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/player/aes128_cbc.dart';
import 'package:xiugou_tv/core/player/media_recorder.dart';

void main() {
  group('Aes128Cbc（NIST SP 800-38A F.2.5 CBC-AES128 标准向量）', () {
    // Key 2b7e151628aed2a6abf7158809cf4f3c
    // IV  000102030405060708090a0b0c0d0e0f
    final key = _hex('2b7e151628aed2a6abf7158809cf4f3c');
    final iv = _hex('000102030405060708090a0b0c0d0e0f');
    final cipher = _hex(
        '7649abac8119b246cee98e9b12e9197d'
        '5086cb9b507219ee95db113a917678b2'
        '73bed6b8e3c1743b7116e69e22229516'
        '3ff1caa1681fac09120eca307586e1a7');
    final plain = _hex(
        '6bc1bee22e409f96e93d7e117393172a'
        'ae2d8a571e03ac9c9eb76fac45af8e51'
        '30c81c46a35ce411e5fbc1191a0a52ef'
        'f69f2445df4f9b17ad2b417be66c3710');

    test('解密结果与标准明文逐字节一致', () {
      final out = Aes128Cbc(key).decrypt(cipher, iv);
      expect(out, plain);
    });
  });

  group('MediaRecorder HLS 解析', () {
    const base = 'http://example.com/live/';

    test('mediaSegments 提取分片并绝对化相对地址', () {
      const body = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:5.0,
seg0.ts
#EXTINF:5.2,
#EXT-X-BYTERANGE:1000@0
seg1.ts
#EXTINF:4.8,
http://cdn.example.com/other/seg2.ts
''';
      final segments = MediaRecorder.mediaSegments(body, Uri.parse(base));
      expect(segments.length, 3);
      expect(segments[0].toString(), 'http://example.com/live/seg0.ts');
      expect(segments[1].toString(), 'http://example.com/live/seg1.ts');
      expect(segments[2].toString(), 'http://cdn.example.com/other/seg2.ts');
    });

    test('isLivePlaylist：无 ENDLIST 且非 VOD 为直播', () {
      expect(MediaRecorder.isLivePlaylist('#EXTM3U\n#EXTINF:5,\na.ts'), isTrue);
      expect(
          MediaRecorder.isLivePlaylist('#EXTM3U\n#EXT-X-ENDLIST\na.ts'),
          isFalse);
      expect(
          MediaRecorder.isLivePlaylist(
              '#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\na.ts'),
          isFalse);
    });

    test('targetDurationSeconds 读取目标时长', () {
      expect(
          MediaRecorder.targetDurationSeconds('#EXT-X-TARGETDURATION:6'),
          6);
      expect(MediaRecorder.targetDurationSeconds('#EXTM3U'), isNull);
    });

    test('initSegmentUri 解析 fMP4 init 段', () {
      const body = '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:5,\na.m4s';
      expect(
          MediaRecorder.initSegmentUri(body, Uri.parse(base)).toString(),
          'http://example.com/live/init.mp4');
      expect(MediaRecorder.initSegmentUri('#EXTM3U\na.ts', Uri.parse(base)),
          isNull);
    });

    test('variantUris 按带宽降序排列 master 子清单', () {
      const body = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4128000,RESOLUTION=1920x1080
high/index.m3u8
''';
      final variants =
          MediaRecorder.variantUris(body, Uri.parse('http://example.com/m.m3u8'));
      expect(variants.length, 2);
      expect(variants.first.toString(),
          'http://example.com/high/index.m3u8');
      expect(variants.last.toString(), 'http://example.com/low/index.m3u8');
    });

    test('parseSegments 密钥状态对后续分片生效，IV/序号正确解析', () {
      const body = '''
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:20
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102030405060708090a0b0c0d0e0f
seg0.ts
#EXT-X-KEY:METHOD=NONE
seg1.ts
''';
      final base = Uri.parse('http://example.com/live/index.m3u8');
      final entries = MediaRecorder.parseSegments(body, base);
      expect(entries.length, 2);
      expect(entries[0].isEncrypted, isTrue);
      expect(entries[0].keyUri.toString(), 'http://example.com/live/key.bin');
      expect(entries[0].iv, _hex('000102030405060708090a0b0c0d0e0f'));
      expect(entries[0].sequence, 20);
      expect(entries[1].isEncrypted, isFalse);
      expect(entries[1].keyMethod, 'NONE');
      expect(entries[1].sequence, 21);
    });

    test('parseSegments 解析 EXTINF 分片时长', () {
      const body = '#EXTM3U\n#EXTINF:9.5,\na.ts\n#EXTINF:4,\nb.ts\nc.ts\n';
      final entries =
          MediaRecorder.parseSegments(body, Uri.parse('http://x.com/i.m3u8'));
      expect(entries[0].duration, 9.5);
      expect(entries[1].duration, 4.0);
      expect(entries[2].duration, isNull); // 无 EXTINF
    });

    test('segmentStartIndexForOffset 按累计时长定位起始分片', () {
      List<HlsSegment> segs(List<double?> durations) => [
            for (var i = 0; i < durations.length; i++)
              HlsSegment(
                uri: Uri.parse('http://x.com/s$i.ts'),
                sequence: i,
                duration: durations[i],
              ),
          ];

      // 10s × 4 段：偏移 15s 落在第 2 段（10-20s）内 → 从下标 1 起
      // （包含当前位置所在的分片）。
      expect(
          MediaRecorder.segmentStartIndexForOffset(
              segs([10, 10, 10, 10]), const Duration(seconds: 15)),
          1);
      // 偏移 0 → 从头。
      expect(
          MediaRecorder.segmentStartIndexForOffset(
              segs([10, 10, 10, 10]), Duration.zero),
          0);
      // 偏移恰在边界 20s → 第 2 段末尾即 20s（结束时刻 20 ≥ 20）。
      expect(
          MediaRecorder.segmentStartIndexForOffset(
              segs([10, 10, 10, 10]), const Duration(seconds: 20)),
          1);
      // 偏移超出总时长 → 收敛到最后一段（保证有数据可录）。
      expect(
          MediaRecorder.segmentStartIndexForOffset(
              segs([10, 10, 10, 10]), const Duration(seconds: 999)),
          3);
      // 缺 EXTINF 无法定位 → 从头录。
      expect(
          MediaRecorder.segmentStartIndexForOffset(
              segs([null, 10, 10]), const Duration(seconds: 5)),
          0);
      // 空清单 → 0。
      expect(
          MediaRecorder.segmentStartIndexForOffset(
              const [], const Duration(seconds: 5)),
          0);
    });
  });

  group('MediaRecorder 端到端（本地 HttpServer）', () {
    late HttpServer server;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rec_test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDir.delete(recursive: true);
    });

    test('HLS 点播录制：逐分片拼接产物', () async {
      final seg1 = List.generate(64, (i) => i);
      final seg2 = List.generate(64, (i) => 100 + i);
      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/index.m3u8') {
          req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          req.response.write('#EXTM3U\n#EXT-X-ENDLIST\n'
              '#EXTINF:5.0,\nseg1.ts\n#EXTINF:5.0,\nseg2.ts\n');
          await req.response.close();
        } else if (path == '/seg1.ts') {
          req.response.add(seg1);
          await req.response.close();
        } else if (path == '/seg2.ts') {
          req.response.add(seg2);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      final out = '${tempDir.path}${Platform.pathSeparator}out.ts';
      final recorder = MediaRecorder(
        url: 'http://127.0.0.1:${server.port}/index.m3u8',
        outputPath: out,
      );
      await recorder.start();
      await recorder.done; // 等点播清单下载完再收尾
      // 正常下完必须标记 completed：引擎据此提示「录制完成」而不是「源断开」。
      expect(recorder.completed, isTrue);
      await recorder.stop();

      final file = File(out);
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), seg1.length + seg2.length);
    });

    test('AES-128 加密 HLS：取密钥解密后产物为明文', () async {
      // 服务端直接下发 NIST 向量密文；密钥/IV 同向量。
      final plain = _hex(
          '6bc1bee22e409f96e93d7e117393172a'
          'ae2d8a571e03ac9c9eb76fac45af8e51'
          '30c81c46a35ce411e5fbc1191a0a52ef'
          'f69f2445df4f9b17ad2b417be66c3710');
      final key = _hex('2b7e151628aed2a6abf7158809cf4f3c');
      final cipher = _hex(
          '7649abac8119b246cee98e9b12e9197d'
          '5086cb9b507219ee95db113a917678b2'
          '73bed6b8e3c1743b7116e69e22229516'
          '3ff1caa1681fac09120eca307586e1a7');
      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/index.m3u8') {
          req.response.write('#EXTM3U\n#EXT-X-ENDLIST\n'
              '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",'
              'IV=0x000102030405060708090a0b0c0d0e0f\n'
              '#EXTINF:5.0,\nseg0.ts\n');
          await req.response.close();
        } else if (path == '/key.bin') {
          req.response.add(key);
          await req.response.close();
        } else if (path == '/seg0.ts') {
          req.response.add(cipher);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      final out = '${tempDir.path}${Platform.pathSeparator}enc.ts';
      final recorder = MediaRecorder(
        url: 'http://127.0.0.1:${server.port}/index.m3u8',
        outputPath: out,
      );
      await recorder.start();
      await recorder.done;
      await recorder.stop();

      expect(File(out).readAsBytesSync(), plain);
    });

    test('HLS 点播带偏移：跳过偏移前分片，从当前观看位置开始录', () async {
      final segs = [
        for (var i = 0; i < 4; i++) List.generate(32, (_) => i),
      ];
      final requested = <String>[];
      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/index.m3u8') {
          // EXTINF 必须紧跟其分片行（规范如此），逐对交错生成。
          req.response.write('#EXTM3U\n#EXT-X-ENDLIST\n'
              '${List.generate(4, (i) => '#EXTINF:10.0,\nseg$i.ts\n').join()}');
          await req.response.close();
        } else if (path.startsWith('/seg')) {
          requested.add(path);
          final i = int.parse(path.substring(4, path.length - 3));
          req.response.add(segs[i]);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      final out = '${tempDir.path}${Platform.pathSeparator}offset.ts';
      final recorder = MediaRecorder(
        url: 'http://127.0.0.1:${server.port}/index.m3u8',
        outputPath: out,
        startOffset: const Duration(seconds: 15), // 10s×4 段 → 从 seg1 起
      );
      await recorder.start();
      await recorder.done;
      await recorder.stop();

      expect(requested, ['/seg1.ts', '/seg2.ts', '/seg3.ts']); // seg0 未请求
      expect(File(out).lengthSync(), 32 * 3);
    });

    test('非 200 源：start 抛出带状态码的友好错误', () async {
      server.listen((req) async {
        req.response.statusCode = 403;
        await req.response.close();
      });
      final out = '${tempDir.path}${Platform.pathSeparator}out.ts';
      final recorder = MediaRecorder(
        url: 'http://127.0.0.1:${server.port}/video.mp4',
        outputPath: out,
      );
      await expectLater(
        recorder.start(),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('403'),
        )),
      );
    });

    // A5：录制被源断开时，done 必须完成——引擎靠它把按钮复位并提示用户
    // （`_onRecorderFinished`）。若 done 悬着不完成，UI 会永远停在「录制中」。
    test('直播源中途断开：done 完成后录制随之结束', () async {
      var served = 0;
      server.listen((req) async {
        if (req.uri.path == '/live.m3u8') {
          // 无 ENDLIST = 直播：录制器会轮询清单
          req.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          req.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2.0,\nseg0.ts\n');
          await req.response.close();
        } else if (req.uri.path == '/seg0.ts') {
          req.response.add(List.generate(32, (i) => i));
          await req.response.close();
          // 只服务一次分片，随后由测试主动停止，模拟源断开。
          served++;
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      final out = '${tempDir.path}${Platform.pathSeparator}live.ts';
      final recorder = MediaRecorder(
        url: 'http://127.0.0.1:${server.port}/live.m3u8',
        outputPath: out,
        pollInterval: const Duration(seconds: 30), // 别让轮询拖住测试
      );
      await recorder.start();
      expect(served, greaterThan(0), reason: '首片应已下载');

      // stop() 必须等后台循环退出后才返回（B 项修改的语义）。
      // 计时判据：此前轮询等待（最长 10s）不可打断，stop() 会空等一整个
      // 周期，而 play() 在 open 前 await 它 —— 直播录制中切台就是这段黑屏。
      final sw = Stopwatch()..start();
      await recorder.stop();
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(2000),
          reason: 'stop() 在轮询等待上耗了 ${sw.elapsedMilliseconds}ms');
      expect(recorder.isStopped, isTrue);
      // 直播是用户主动停止的，不是「正常录完」——不能报成录制完成。
      expect(recorder.completed, isFalse);
      expect(File(out).lengthSync(), 32);
    });

    // 起播提速审计 S4：录制中切集时 play() 会 await stopRecording()，
    // 而 stop() 等在途下载退出。若下载卡在「响应头已到、实体不再吐」的分片上，
    // 理论上要等满 timeout × 重试才返回 = 起播前黑屏。
    // 实测判据：force-close 客户端应让在途 await-for 立即报错，stop() 亚秒级返回。
    test('分片卡在无响应体时：stop() 必须快速返回（不拖住起播）', () async {
      final seg1 = List.generate(64, (i) => i);
      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/index.m3u8') {
          req.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          // 点播（带 ENDLIST）：两片，第一片正常、第二片永挂。
          req.response.write('#EXTM3U\n#EXT-X-ENDLIST\n'
              '#EXTINF:5.0,\nseg1.ts\n#EXTINF:5.0,\nhang.ts\n');
          await req.response.close();
        } else if (path == '/seg1.ts') {
          req.response.add(seg1);
          await req.response.close();
        } else if (path == '/hang.ts') {
          // 只发响应头，实体永不写入、也不关闭。
          await req.response.flush();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      final out = '${tempDir.path}${Platform.pathSeparator}hang.ts';
      final recorder = MediaRecorder(
        url: 'http://127.0.0.1:${server.port}/index.m3u8',
        outputPath: out,
        // 单次网络操作 15s：若 stop() 等满超时 + 重试，会被这个值放大。
        timeout: const Duration(seconds: 15),
      );
      await recorder.start();
      expect(File(out).lengthSync(), 64, reason: '首片应已落盘');

      final sw = Stopwatch()..start();
      await recorder.stop();
      sw.stop();

      // 判据：远小于 timeout（15s）。给 2 秒冗余，容忍 CI 抖动。
      expect(
        sw.elapsedMilliseconds,
        lessThan(2000),
        reason: 'stop() 被在途下载拖住 ${sw.elapsedMilliseconds}ms，'
            '会直接压进切集起播等待',
      );
      // 已写入的首片内容必须保留。
      expect(File(out).lengthSync(), 64);
    });
  });
}

Uint8List _hex(String hex) {
  final clean =
      hex.startsWith('0x') ? hex.substring(2) : hex.replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
