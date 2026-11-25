import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// HLS 播放列表总时长解析。
///
/// 背景：mpv / ffmpeg 的 HLS 解复用器在部分源上不给总时长 —— 实测 `duration`
/// 会等于**当前分片**的时长并随播放不断变化（4.166 → 3.550 → 1.950 → 2.200 …
/// 与 `#EXTINF` 逐条对应），进度条的 max 因此每隔几秒跳一次，看起来就是
/// 「一直在循环刷新、看不到实际进度」。
///
/// 这类源的特征：有 `#EXT-X-ENDLIST` 但缺 `#EXT-X-PLAYLIST-TYPE:VOD`，
/// ffmpeg 于是按「直播」处理。与其依赖 mpv 的判断，不如直接把清单拉下来
/// 自己累加 `#EXTINF` —— 对点播清单准确，对真直播则不做猜测（返回 null）。
class HlsDurationResolver {
  HlsDurationResolver({
    HttpClient? client,
    this.timeout = const Duration(seconds: 10),
    this.maxRedirects = 3,
    this.maxBytes = 8 * 1024 * 1024,
  }) : _client = client;

  /// 复用外部客户端时为非 null；否则每次解析自建并在结束时关闭。
  final HttpClient? _client;
  final Duration timeout;
  final int maxRedirects;

  /// 单个清单最大读取字节（4K 长片的分片列表可达上百 KB，8MB 足够宽松）
  final int maxBytes;

  static final RegExp _extInf =
      RegExp(r'#EXTINF:\s*([0-9]+(?:\.[0-9]+)?)', caseSensitive: false);

  /// 解析播放地址的总时长；无法判定（非 HLS / 真直播 / 拉取失败）时返回 null。
  Future<Duration?> resolve(String url, Map<String, String>? headers) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }
    var current = uri;
    for (var hop = 0; hop < maxRedirects; hop++) {
      final body = await _fetch(current, headers);
      if (body == null) return null;
      if (!body.contains('#EXTM3U')) return null; // 不是 m3u8（可能是直链 mp4）

      final variants = _variantUris(body, current);
      if (variants.isNotEmpty) {
        current = variants.first; // master 清单：下钻到子清单
        continue;
      }
      // 媒体清单：有结束标记或显式点播声明才采纳总时长，
      // 否则按直播处理（滑动窗口，总时长本就未知）。
      final finished = body.contains('#EXT-X-ENDLIST') ||
          RegExp(r'#EXT-X-PLAYLIST-TYPE:\s*VOD', caseSensitive: false)
              .hasMatch(body);
      final seconds = _totalSeconds(body);
      if (!finished || seconds == null) return null;
      return Duration(microseconds: (seconds * 1e6).round());
    }
    return null;
  }

  /// 累加 `#EXTINF`；清单里没有任何分片时返回 null。
  double? _totalSeconds(String body) {
    var total = 0.0;
    var found = false;
    for (final match in _extInf.allMatches(body)) {
      final value = double.tryParse(match.group(1)!);
      if (value == null) continue;
      total += value;
      found = true;
    }
    return found ? total : null;
  }

  /// 多码率 master 清单的子清单地址：按带宽从高到低排（优先最清晰的线路）。
  List<Uri> _variantUris(String body, Uri base) {
    final out = <_Variant>[];
    final lines = const LineSplitter().convert(body);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final bandwidth = RegExp(r'BANDWIDTH\s*=\s*(\d+)', caseSensitive: false)
          .firstMatch(line)
          ?.group(1);
      // URI 可能在同一行（URI="..."）或紧跟的下一行
      var target = RegExp(r'URI\s*=\s*"([^"]+)"').firstMatch(line)?.group(1);
      if (target == null) {
        for (var j = i + 1; j < lines.length; j++) {
          final next = lines[j].trim();
          if (next.isEmpty) continue;
          if (next.startsWith('#')) break;
          target = next;
          break;
        }
      }
      if (target == null) continue;
      out.add(_Variant(base.resolve(target), int.tryParse(bandwidth ?? '') ?? 0));
    }
    out.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return out.map((e) => e.uri).toList();
  }

  Future<String?> _fetch(Uri uri, Map<String, String>? headers) async {
    final owned = _client == null;
    final client = _client ?? HttpClient();
    try {
      // 跟随系统代理环境变量：有代理（沙箱 / 公司网络）时也能取到清单。
      client.findProxy = HttpClient.findProxyFromEnvironment;
      final request = await client.getUrl(uri).timeout(timeout);
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      var size = 0;
      await for (final chunk in response.timeout(timeout)) {
        size += chunk.length;
        if (size > maxBytes) break;
        builder.add(chunk);
      }
      return utf8.decode(builder.takeBytes(), allowMalformed: true);
    } catch (_) {
      // 网络异常不阻塞播放：调用方继续用 mpv 报的时长
      return null;
    } finally {
      if (owned) client.close(force: true);
    }
  }
}

class _Variant {
  final Uri uri;
  final int bandwidth;
  const _Variant(this.uri, this.bandwidth);
}
