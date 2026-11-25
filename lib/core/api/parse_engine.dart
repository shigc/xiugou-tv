import 'dart:convert';
import 'package:dio/dio.dart';
import '../config/models/vod_config.dart';
import '../net/http_client_factory.dart';
import '../player/models/player_state.dart';

/// 视频播放地址解析引擎 (处理第三方解析规则与直链提取)
class ParseEngine {
  final Dio _dio;

  ParseEngine({Dio? dio})
      : _dio = dio ??
            HttpClientFactory.createDio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 12),
              ),
            );

  /// 单条解析接口的限时：健康的解析 1~2 秒返回，异常的要快速放行下一条，
  /// 不能让一条死解析按默认超时（connect 10s + receive 12s）拖满 22 秒。
  static const Duration _perRequestConnectTimeout = Duration(seconds: 6);
  static const Duration _perRequestReceiveTimeout = Duration(seconds: 8);

  /// 整轮解析的时间预算：预算耗尽即停止尝试剩余规则，回落直连播放。
  static const Duration _totalBudget = Duration(seconds: 15);

  /// 失败解析的熔断时长。同一配置里坏掉的解析接口在每条线路、每次切集时
  /// 都会被重新撞一遍；熔断期内直接跳过，到期自然恢复。
  static const Duration _breakerOpenFor = Duration(minutes: 10);

  /// 熔断与预算计时统一走单调时钟：Windows 上 DateTime.now() 精度约 15ms
  /// 且可能跳变，连读两次甚至可能倒序，不足以判定「1 秒内不该恢复」。
  final Stopwatch _uptime = Stopwatch()..start();

  /// 解析接口失败时刻表（进程内记忆）：key 为解析 URL，value 为失败时的单调毫秒。
  final Map<String, int> _failedAt = {};

  /// 根据原始播放地址与平台旗标解析可直接播放的流媒体地址 (m3u8 / mp4)。
  ///
  /// [breakerRetried] 内部防重入：全熔断补试只允许一轮。
  Future<MediaPlaySpec> parse(String rawUrl,
      {String? flag,
      List<Parse> parses = const [],
      bool requireResolved = false,
      bool breakerRetried = false}) async {
    final trimmed = rawUrl.trim();

    // 1. 如果本身已是标准直链媒体文件，无需调用解析接口
    if (!requireResolved && _isDirectMediaUrl(trimmed)) {
      return MediaPlaySpec(url: trimmed);
    }

    // 2. 遍历配置中的有效解析规则进行直链嗅探/接口解析
    final candidates = parses.where((p) => p.type == 1).toList();
    final deadlineMs = _uptime.elapsedMilliseconds + _totalBudget.inMilliseconds;
    var attempted = 0;
    for (final parseItem in candidates) {
      // 熔断期内的失败解析直接跳过：坏接口在每条线路、每次切集都会被重撞。
      if (_isBreakerOpen(parseItem.url)) continue;
      if (_uptime.elapsedMilliseconds >= deadlineMs) break;
      attempted++;
      try {
        // JSON 接口解析
        final parseApi = parseItem.url;
        final targetUrl = '$parseApi$trimmed';

        final headers = <String, dynamic>{
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 xiugou-tv/5.6.3',
        };
        if (parseItem.header != null) {
          headers.addAll(parseItem.header!);
        }

        final response = await _dio.get(
          targetUrl,
          options: Options(
            headers: headers,
            responseType: ResponseType.plain,
            connectTimeout: _perRequestConnectTimeout,
            receiveTimeout: _perRequestReceiveTimeout,
          ),
        );

        final result = _extractUrlFromJson(response.data);
        if (result != null && result.isNotEmpty) {
          _failedAt.remove(parseItem.url);
          return MediaPlaySpec(
            url: result,
            headers: parseItem.header,
          );
        }
        // 有响应但拿不到地址：同样计为失败（多半是接口已废弃）
        _tripBreaker(parseItem.url);
      } catch (_) {
        // 单个解析接口失败/超时：熔断并轮询下一个备用解析
        _tripBreaker(parseItem.url);
        continue;
      }
    }

    if (requireResolved) {
      // Spider 链路没有直连兜底：若全部候选都在熔断期（一次都没试），
      // 清空熔断表完整重跑一轮——宁可慢一轮，也不能把可播内容锁死 10 分钟。
      if (attempted == 0 && candidates.isNotEmpty && !breakerRetried) {
        _failedAt.clear();
        return parse(rawUrl,
            flag: flag,
            parses: parses,
            requireResolved: true,
            breakerRetried: true);
      }
      throw const FormatException('没有可用的 JSON 解析结果，暂不支持网页嗅探');
    }

    // 3. 所有解析器失效或无解析配置时，尝试直连播放
    return MediaPlaySpec(url: trimmed);
  }

  /// 站点显式指定的 JSON 解析前缀；失败时不能把原始ID当成媒体返回。
  Future<MediaPlaySpec> parseSiteJson(String prefix, String rawUrl,
      {Map<String, String>? requestHeaders}) async {
    final endpoint = prefix.substring('json:'.length).trim();
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('站点 JSON 解析地址无效');
    }
    final response = await _dio.get<String>(
      '$endpoint${Uri.encodeComponent(rawUrl.trim())}',
      options: Options(headers: requestHeaders, responseType: ResponseType.plain),
    );
    final dynamic decoded;
    try {
      decoded = jsonDecode(response.data ?? '');
    } on FormatException {
      throw const FormatException('站点 JSON 解析服务未返回有效 JSON');
    }
    if (decoded is! Map) throw const FormatException('站点 JSON 解析结果无效');
    final data = decoded['data'];
    final result = data is Map && decoded['url'] == null ? data : decoded;
    final url = result['url']?.toString().trim() ?? '';
    final media = Uri.tryParse(url);
    if (media == null || !{'http', 'https', 'rtmp', 'rtsp'}.contains(media.scheme) || media.host.isEmpty) {
      throw const FormatException('站点 JSON 解析未返回可播放地址');
    }
    final headers = <String, String>{};
    Object? rawHeaders = result['header'] ?? result['headers'];
    if (rawHeaders is String) {
      try { rawHeaders = jsonDecode(rawHeaders); } on FormatException { rawHeaders = null; }
    }
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    return MediaPlaySpec(url: url, headers: headers.isEmpty ? null : headers);
  }

  bool _isBreakerOpen(String url) {
    final failedMs = _failedAt[url];
    if (failedMs == null) return false;
    if (_uptime.elapsedMilliseconds - failedMs >=
        _breakerOpenFor.inMilliseconds) {
      _failedAt.remove(url);
      return false;
    }
    return true;
  }

  void _tripBreaker(String url) => _failedAt[url] = _uptime.elapsedMilliseconds;

  bool _isDirectMediaUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('.mp4') ||
        lower.contains('.flv') ||
        lower.contains('.ts') ||
        lower.contains('.mkv') ||
        lower.startsWith('rtmp://') ||
        lower.startsWith('rtsp://');
  }

  String? _extractUrlFromJson(dynamic raw) {
    if (raw == null) return null;
    try {
      final map = raw is Map ? raw : jsonDecode(raw.toString());
      if (map is Map) {
        final url = map['url']?.toString();
        if (url != null && url.isNotEmpty) return url;
        final data = map['data'];
        if (data is Map) {
          final dataUrl = data['url']?.toString();
          if (dataUrl != null && dataUrl.isNotEmpty) return dataUrl;
        }
      }
    } catch (_) {}
    return null;
  }
}
