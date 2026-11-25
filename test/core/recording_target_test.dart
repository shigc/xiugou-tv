import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/player/recording_target.dart';

void main() {
  group('RecordingTarget.extensionFor', () {
    test('直链 mp4 / mkv / flv 保留原容器扩展名', () {
      expect(RecordingTarget.extensionFor('http://a.com/v/movie.mp4'),
          'mp4');
      expect(RecordingTarget.extensionFor('http://a.com/v/movie.mkv?token=x'),
          'mkv');
      expect(
          RecordingTarget.extensionFor('http://a.com/live/1.FLV'), 'flv');
    });

    test('HLS 与未识别来源统一为 ts', () {
      expect(RecordingTarget.extensionFor('http://a.com/index.m3u8'), 'ts');
      expect(RecordingTarget.extensionFor('http://a.com/stream'), 'ts');
    });
  });

  group('RecordingTarget.sanitizeTitle', () {
    test('剔除 Windows 非法字符并压缩空白，保留中文', () {
      expect(RecordingTarget.sanitizeTitle('狂飙 2023:第1集 <4K>'),
          '狂飙 2023 第1集 4K');
    });

    test('空 / 全非法字符回退为「录制」', () {
      expect(RecordingTarget.sanitizeTitle(''), '录制');
      expect(RecordingTarget.sanitizeTitle('///'), '录制');
    });

    test('超长标题截断到 120 字符', () {
      final long = '剧' * 300;
      expect(RecordingTarget.sanitizeTitle(long).length, 120);
    });
  });

  group('RecordingTarget.resolve', () {
    test('路径含 xiugou-recordings 子目录与时间戳', () {
      final path = RecordingTarget.resolve(
        root: r'C:\Users\me\Downloads',
        title: '测试剧',
        url: 'http://a.com/index.m3u8',
        now: DateTime(2026, 10, 31, 9, 5, 3),
      );
      expect(path, contains('xiugou-recordings'));
      expect(path, contains('测试剧-20261031-090503'));
      expect(path, endsWith('.ts'));
    });

    test('同时间戳冲突时追加序号，不覆盖既有文件', () {
      // resolve 用 existsSync 探测真实文件系统；这里以临时目录构造冲突。
      final dir = Directory.systemTemp.createTempSync('rec_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sub =
          Directory('${dir.path}${Platform.pathSeparator}xiugou-recordings')
            ..createSync();
      final stamp = RecordingTarget.formatStamp(DateTime(2026, 1, 1));
      File('${sub.path}${Platform.pathSeparator}片-$stamp.ts')
          .writeAsStringSync('');

      final path = RecordingTarget.resolve(
        root: dir.path,
        title: '片',
        url: 'http://a.com/index.m3u8',
        now: DateTime(2026, 1, 1),
      );
      expect(path, contains('-2.ts'));
    });
  });

  group('RecordingTarget.formatStamp', () {
    test('补零', () {
      expect(
        RecordingTarget.formatStamp(DateTime(2026, 3, 7, 8, 9, 5)),
        '20260307-080905',
      );
    });
  });
}
