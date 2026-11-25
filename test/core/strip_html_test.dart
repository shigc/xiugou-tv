import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/api/models/vod_models.dart';

void main() {
  group('stripHtmlToPlainText', () {
    test('去掉标签与 style 属性，保留正文', () {
      const raw = '<p><span style="font-size:15px">凡人修仙传讲了双手</span></p>';
      expect(stripHtmlToPlainText(raw), '凡人修仙传讲了双手');
    });

    test('解码命名实体', () {
      expect(stripHtmlToPlainText('a&nbsp;b&amp;c&quot;d'), 'a b&c"d');
    });

    test('解码数字实体（十/十六进制）', () {
      expect(stripHtmlToPlainText('&#20320;&#x597D;'), '你好');
    });

    test('不二次解码 &amp;lt;', () {
      expect(stripHtmlToPlainText('&amp;lt;'), '&lt;');
    });

    test('折叠标签留下的多余空白', () {
      expect(stripHtmlToPlainText('<p>甲</p>   <p>乙</p>'), '甲 乙');
    });

    test('纯文本原样返回', () {
      expect(stripHtmlToPlainText('平凡的世界'), '平凡的世界');
    });
  });

  group('cleanCastList（vod_actor BBCode 清洗）', () {
    test('提取 AppleCMS BBCode 链接的演员名', () {
      const raw = '[a=cr({"id":"梁朝伟/pg","name":"梁朝伟"})]梁朝伟[/a]'
          ' [a=cr({"id":"汤唯/pg","name":"汤唯"})]汤唯[/a]';
      expect(cleanCastList(raw), '梁朝伟 汤唯');
    });

    test('内部文本为空时退回 JSON name 字段', () {
      const raw = '[a=cr({"id":"1","name":"周润发"})][/a]';
      expect(cleanCastList(raw), '周润发');
    });

    test('无 BBCode 的逗号分隔名单原样通过', () {
      expect(cleanCastList('梁朝伟,汤唯,陈冲'), '梁朝伟,汤唯,陈冲');
    });

    test('夹带 HTML 时仍走通用清洗', () {
      expect(cleanCastList('<p>梁朝伟</p>&nbsp;汤唯'), '梁朝伟 汤唯');
    });

    test('fromJson 清洗 vod_actor 与 vod_director', () {
      final item = VodItem.fromJson({
        'vod_id': '1',
        'vod_name': '色戒',
        'vod_actor': '[a=cr({"id":"a","name":"梁朝伟"})]梁朝伟[/a]',
        'vod_director': '[a=cr({"id":"b","name":"李安"})]李安[/a]',
      });
      expect(item.actor, '梁朝伟');
      expect(item.director, '李安');
    });

    test('清洗后为空字符串时归为 null', () {
      final item = VodItem.fromJson({'vod_id': '1', 'vod_actor': '  '});
      expect(item.actor, isNull);
    });
  });
}
