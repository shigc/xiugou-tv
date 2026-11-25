import 'models/vod_models.dart';

/// 归一化片名：跨站同名影片的分组键（只做**确定性**变换，不做语义猜测）。
///
/// - 全角字符 → 半角；转小写；去掉所有空白；
/// - 去掉常见标点（中英文标点统一剥除）；
/// - 去掉尾部年份（如 `狂飙2023` → `狂飙`；`Movie (2019)` → `movie`）；
/// - 去掉尾部清晰度 / 版本词（4k、1080p、蓝光、hd、国语、粤语等常见后缀）。
///
/// 例：`狂飙 2023` / `狂飙（2023）` / `狂飙4K` → `狂飙`。
String normalizeVodName(String value) {
  var text = value.trim().toLowerCase();
  // 全角 → 半角（复用集名归一化的映射区间）
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  text = buffer.toString();
  // 剥除空白与常见标点（含中文标点）
  text = text.replaceAll(RegExp(r'[\s!-/:-@\[-`{-~！-／：－＠［－｀｛－～、。·「」『』（）《》〈〉【】—～￥…]+'), '');
  // 循环剥除尾部年份 / 清晰度 / 版本词
  var changed = true;
  while (changed) {
    changed = false;
    final yearMatch = RegExp(r'(19\d{2}|20\d{2})$').firstMatch(text);
    if (yearMatch != null) {
      text = text.substring(0, yearMatch.start);
      changed = true;
      continue;
    }
    final tagMatch = RegExp(
            r'(2160p|1080p|720p|4k|uhd|blu-ray|bluray|蓝光|高清|抢先版|枪版|hd|国语|粤语|普通话|英语|日语|韩语|.ts|.tc)$')
        .firstMatch(text);
    if (tagMatch != null && tagMatch.start > 0) {
      text = text.substring(0, tagMatch.start);
      changed = true;
    }
  }
  return text;
}

/// 对单个搜索结果做"源质量"评分（仅用条目自带信息，确定性、无 IO）。
///
/// 分值越高越优先作为组内主条目：
/// - 有备注（集数 / 清晰度信息）+10 —— 无备注多半是无法点播的导航条目；
/// - 清晰度：4K/2160 +8，1080 +5，720 +2；蓝光/高清 +2；
/// - 明显枪版（抢先/枪版/TC/TS）-10；
/// - 有站源标识 +1（保证可回溯详情）。
int rankVodItem(VodItem item) {
  var score = 0;
  final remarks = item.remarks?.trim() ?? '';
  if (remarks.isNotEmpty) score += 10;
  final lower = remarks.toLowerCase();
  if (lower.contains('2160') || lower.contains('4k')) {
    score += 8;
  } else if (lower.contains('1080')) {
    score += 5;
  } else if (lower.contains('720')) {
    score += 2;
  }
  if (lower.contains('蓝光') || lower.contains('blu') || lower.contains('高清')) {
    score += 2;
  }
  if (lower.contains('抢先') || lower.contains('枪版') || lower.contains('.ts') || lower.contains('.tc')) {
    score -= 10;
  }
  if ((item.siteKey ?? '').isNotEmpty) score += 1;
  return score;
}

/// 一组"同一部片"的跨站搜索结果。
class VodSearchGroup {
  /// 组内评分最高的条目（展示与点击入口）。
  final VodItem main;

  /// 其余同片条目（起播失败时的备用源，按评分降序）。
  final List<VodItem> alternates;

  final String normalizedName;

  const VodSearchGroup({
    required this.main,
    required this.alternates,
    required this.normalizedName,
  });
}

/// 把聚合搜索结果按归一化片名分组：同组只保留主条目，其余挂 alternates。
///
/// - 保持主条目按"首次出现顺序"（不打乱用户看到的先后）；
/// - 组内排序稳定：同分时先出现者优先；
/// - 片名归一化后为空的条目不参与分组（各自独立）。
List<VodSearchGroup> groupSearchResults(List<VodItem> items) {
  final orderedKeys = <String>[];
  final groups = <String, List<VodItem>>{};
  for (final item in items) {
    final key = normalizeVodName(item.name);
    if (key.isEmpty) {
      // 无可归一片名：用自身唯一键独立成组，保证不丢条目
      final unique = '\u0000${searchItemKeyOf(item)}';
      orderedKeys.add(unique);
      groups[unique] = [item];
      continue;
    }
    if (!groups.containsKey(key)) {
      orderedKeys.add(key);
      groups[key] = [];
    }
    groups[key]!.add(item);
  }

  final result = <VodSearchGroup>[];
  for (final key in orderedKeys) {
    final members = groups[key]!;
    final ranked = List.of(members)
      ..sort((a, b) {
        final byScore = rankVodItem(b).compareTo(rankVodItem(a));
        if (byScore != 0) return byScore;
        return members.indexOf(a).compareTo(members.indexOf(b));
      });
    result.add(VodSearchGroup(
      main: ranked.first,
      alternates: ranked.sublist(1),
      normalizedName: key,
    ));
  }
  return result;
}

/// 与 `search_engine.searchItemKey` 同口径的去重键（避免引入反向依赖）。
String searchItemKeyOf(VodItem item) => '${item.siteKey}_${item.id}_${item.name}';
