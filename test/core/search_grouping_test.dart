import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/api/models/vod_models.dart';
import 'package:xiugou_tv/core/api/search_grouping.dart';
import 'package:xiugou_tv/core/follow/follow_record.dart';

void main() {
  group('normalizeVodName', () {
    test('同名不同年份 / 清晰度后缀归为同一键', () {
      expect(normalizeVodName('狂飙 2023'), normalizeVodName('狂飙（2023）'));
      expect(normalizeVodName('狂飙2023'), normalizeVodName('狂飙4K'));
      expect(normalizeVodName('Movie (2019)'), normalizeVodName('movie'));
    });

    test('全角半角 / 空白 / 标点差异不影响归一化', () {
      expect(normalizeVodName('三体（ＴＶ）'), normalizeVodName('三体(tv)'));
      expect(normalizeVodName('  长安的荔枝 '), normalizeVodName('长安的荔枝'));
      expect(normalizeVodName('庆余年·第二季'), normalizeVodName('庆余年第二季'));
    });

    test('无片名归一化为空串', () {
      expect(normalizeVodName(''), '');
      expect(normalizeVodName('   '), '');
      expect(normalizeVodName('...'), '');
    });
  });

  group('groupSearchResults', () {
    VodItem item(String site, String id, String name, {String? remarks}) =>
        VodItem(id: id, name: name, pic: '', remarks: remarks,
            siteKey: site, siteName: site);

    test('同名条目合并为组，评分最高者为主条目', () {
      final groups = groupSearchResults([
        item('a', '1', '狂飙', remarks: null),
        item('b', '2', '狂飙 2023', remarks: '1080P'),
        item('c', '3', '其他电影'),
      ]);
      expect(groups.length, 2);
      // b 有 remarks（+10）+ 1080（+5）+ 站点（+1）= 16 分，应为组内主条目
      expect(groups[0].main.siteKey, 'b');
      expect(groups[0].alternates.length, 1);
      expect(groups[0].alternates.first.siteKey, 'a');
      expect(groups[1].main.name, '其他电影');
      expect(groups[1].alternates, isEmpty);
    });

    test('保持首次出现顺序；无片名条目独立成组不丢失', () {
      final groups = groupSearchResults([
        item('a', '1', '其他电影'),
        item('b', '2', '...'),
        item('c', '3', '其他电影', remarks: '更新至10集'),
      ]);
      expect(groups.length, 2);
      expect(groups[0].main.siteKey, 'c'); // 同名组主条目为高分者
      expect(groups[0].alternates.first.siteKey, 'a');
      expect(groups[1].main.name, '...');
    });

    test('空列表返回空', () {
      expect(groupSearchResults(const []), isEmpty);
    });
  });

  group('FollowRecord', () {
    test('unseenEpisodes 计算：known 12 / seen 10 → 2 集更新', () {
      final record = FollowRecord(
        id: 'a/1',
        vodId: '1',
        vodName: '测试剧',
        vodPic: '',
        knownEpisodes: 12,
        seenEpisodes: 10,
        followedAt: DateTime(2026, 1, 1),
      );
      expect(record.unseenEpisodes, 2);
      expect(record.hasUpdate, isTrue);
    });

    test('seen > known 时不下溢', () {
      final record = FollowRecord(
        id: 'a/1',
        vodId: '1',
        vodName: '测试剧',
        vodPic: '',
        knownEpisodes: 8,
        seenEpisodes: 10,
        followedAt: DateTime(2026, 1, 1),
      );
      expect(record.unseenEpisodes, 0);
      expect(record.hasUpdate, isFalse);
    });

    test('JSON 往返保留字段', () {
      final record = FollowRecord(
        id: 'site1/vod9',
        vodId: 'vod9',
        vodName: '剧名',
        vodPic: 'http://pic',
        siteKey: 'site1',
        siteName: '站点一',
        knownEpisodes: 24,
        seenEpisodes: 20,
        followedAt: DateTime(2026, 1, 2, 3, 4),
        lastCheckedAt: DateTime(2026, 1, 3),
        lastUpdatedAt: DateTime(2026, 1, 3, 8),
      );
      final restored = FollowRecord.fromJson(record.toJson());
      expect(restored.id, record.id);
      expect(restored.knownEpisodes, 24);
      expect(restored.seenEpisodes, 20);
      expect(restored.siteKey, 'site1');
      expect(restored.lastUpdatedAt, record.lastUpdatedAt);
      expect(restored.hasUpdate, isTrue);
    });
  });
}
