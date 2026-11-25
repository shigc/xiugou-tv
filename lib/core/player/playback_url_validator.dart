import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 直链媒体扩展名：此类地址信任、不诊断（避免给正常 CDN 增加额外往返与误判）。
const _directMediaExtensions = {
  '.m3u8',
  '.mp4',
  '.flv',
  '.ts',
  '.mkv',
  '.webm',
  '.mov',
  '.avi',
  '.m4v',
  '.mpd',
};

const _probeTimeout = Duration(seconds: 6);

const _htmlErrorReason =
    '解析中转返回了网页而非视频流，请更新站点解析配置或换线';

/// 播放失败后的「根因诊断」：当 mpv 报「无法识别格式」等错误时，最佳努力地回源拉取一次，
/// 读取中转返回的错误页（HTML/JSON），提取给用户看的真实原因。
///
/// 设计要点：
/// - **只在播放已经失败之后调用**（mpv 已报错），因此回源不会影响任何正在进行的播放，
///   也不会消耗可用线路的令牌——即使某些中转的令牌是单次有效，失败的这一条也不会再被播放。
/// - 任何异常 / 超时 / 无法判定一律返回 null（不诊断），绝不覆盖 mpv 原有的错误信息。
/// - 命中直链媒体扩展名时直接返回 null（这类基本不会是错误页）。
///
/// 返回非 null 即表示「确实是中转返回的非媒体错误页」，文案可直接展示给用户。
Future<String?> diagnosePlaybackUrl(String url,
    {Map<String, String>? headers}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final path = uri.path.toLowerCase();
  if (_directMediaExtensions.any((ext) => path.endsWith(ext))) {
    return null;
  }

  final client = HttpClient()..connectionTimeout = _probeTimeout;
  try {
    final request = await client.getUrl(uri).timeout(_probeTimeout);
    headers?.forEach((k, v) => request.headers.set(k, v));
    // 只取前若干字节即可判定类型，避免拉取整段视频。
    request.headers.set('Range', 'bytes=0-2047');
    if (headers?.containsKey('user-agent') != true &&
        headers?.containsKey('User-Agent') != true) {
      request.headers.set(
          'User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
    }
    final response = await request.close().timeout(_probeTimeout);

    if (response.statusCode >= 400) {
      return '播放地址返回 HTTP ${response.statusCode}，源可能已失效，请换线';
    }

    final contentType =
        (response.headers.contentType?.mimeType ?? '').toLowerCase();
    final text = utf8
        .decode(await _readCapped(response, 2111), allowMalformed: true)
        .trim();

    // 明确是媒体类型：不是错误页，无需诊断。
    if (contentType.startsWith('video/') ||
        contentType.startsWith('audio/') ||
        contentType == 'application/vnd.apple.mpegurl' ||
        contentType == 'application/x-mpegurl' ||
        contentType == 'application/dash+xml' ||
        contentType == 'application/octet-stream') {
      return null;
    }
    if (contentType.contains('mpegurl') ||
        (contentType == 'text/plain' && text.startsWith('#EXT'))) {
      // m3u8 有时被标成 text/plain，但正文以 #EXTM3U 开头。
      return null;
    }
    if (contentType == 'application/json') {
      return _extractJsonReason(text) ??
          '解析中转返回了错误（JSON）而非视频流，请更新站点解析配置或换线';
    }
    if (contentType == 'text/html') {
      return _htmlErrorReason;
    }
    // 其它未知类型：保守不诊断，保留 mpv 原错误信息。
    return null;
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  } finally {
    // 强制关闭连接，避免读取中途断开导致 socket 泄漏。
    client.close(force: true);
  }
}

Future<List<int>> _readCapped(HttpClientResponse response, int cap) async {
  final out = <int>[];
  await for (final chunk in response) {
    final remaining = cap - out.length;
    if (remaining <= 0) break;
    if (chunk.length <= remaining) {
      out.addAll(chunk);
    } else {
      out.addAll(chunk.sublist(0, remaining));
    }
    if (out.length >= cap) break;
  }
  return out;
}

/// 从错误页 JSON 中提取给用户看的原因，形如 {"code":"404","msg":"秘钥不存在",...}。
/// 不是合法的错误对象（如二进制/清单）时返回 null，交由上层保守处理。
String? _extractJsonReason(String text) {
  try {
    final data = jsonDecode(text);
    if (data is! Map) return null;
    final raw = data['msg'] ?? data['message'] ?? data['error'] ?? data['reason'];
    final msg = raw is String ? raw : raw?.toString();
    if (msg == null || msg.isEmpty) return null;
    final code = data['code'];
    if (code != null && '$code'.isNotEmpty) {
      return '解析中转返回错误（code $code）：$msg';
    }
    return '解析中转返回错误：$msg';
  } catch (_) {
    return null;
  }
}
