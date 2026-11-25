import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/config/models/history_record.dart';

HistoryRecord _record({String playUrl = '', String episodeUrl = ''}) =>
    HistoryRecord(
      id: '1001_第1集',
      vodId: '1001',
      vodName: '测试片',
      vodPic: '',
      episodeName: '第1集',
      sourceName: '线路一',
      playUrl: playUrl,
      episodeUrl: episodeUrl,
      siteKey: 'site_a',
      timestamp: 0,
    );

/// `hasDirectPlayablePath` 决定历史续播「先直链还是先跨源」：
/// 返回 true 时本地就能起播，跨源不该抢在它前面（A1）。
void main() {
  group('HistoryRecord.hasDirectPlayablePath', () {
    test('有直链兜底：为 true（详情失败也能立刻播）', () {
      expect(
        _record(playUrl: 'http://cdn.example.com/a/index.m3u8').hasDirectPlayablePath,
        isTrue,
      );
    });

    test('无直链、选集地址是相对路径：为 false（只能跨源）', () {
      expect(_record(episodeUrl: '/vodplay/1001-1-1').hasDirectPlayablePath,
          isFalse);
    });

    test('无直链、选集地址是绝对地址：为 true', () {
      expect(
        _record(episodeUrl: 'http://cdn.example.com/ep/1.m3u8')
            .hasDirectPlayablePath,
        isTrue,
      );
      expect(
        _record(episodeUrl: 'https://cdn.example.com/ep/1').hasDirectPlayablePath,
        isTrue,
      );
    });

    test('直链与选集地址都为空：为 false', () {
      expect(_record().hasDirectPlayablePath, isFalse);
    });
  });
}
