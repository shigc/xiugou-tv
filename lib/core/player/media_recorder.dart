import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'aes128_cbc.dart';

/// 纯 Dart 录制器：把当前播放源原样落盘。
///
/// 为什么不用 mpv 的 stream-record：media_kit 捆绑的 libmpv 是精简构建，
/// ffmpeg 的封装器（muxer）被全部裁掉——设置 `stream-record`/`record-file`
/// 后 mpv 报 `recorder: Output format not found` 然后静默禁用录制
/// （ts/mp4/mkv/avi/webm/ogg/wav 全部扩展名实测无一可用，2026-10-31）。
/// 因此录制在应用层实现：不经过解码/重编码，只搬运源字节。
///
/// 支持两类源：
/// * **HLS（m3u8）**：解析清单 → 逐分片下载 → 原样拼接。点播按清单顺序
///   下载到 ENDLIST；直播周期轮询清单、只追加新分片，直到调用 [stop]。
/// * **HTTP 直链**：GET 响应体直接 dump（从第 0 字节起，完整文件，
///   不跟随本地播放进度——本地可以随便拖动，产物仍是完整视频）。
///
/// 产物是源格式原样容器（HLS/mpegts → .ts；直链 → 源本身的封装）。
class MediaRecorder {
  MediaRecorder({
    required this.url,
    required this.outputPath,
    this.headers,
    this.startOffset = Duration.zero,
    this.timeout = const Duration(seconds: 15),
    this.pollInterval = const Duration(seconds: 4),
    this.maxPlaylistBytes = 8 * 1024 * 1024,
  });

  final String url;
  final String outputPath;
  final Map<String, String>? headers;

  /// 点播起始偏移：HLS 点播从该播放时刻对应的分片开始下载，
  /// 实现「从当前观看位置开始录制」（跳过片头贴片广告与已看部分）。
  /// 直播与直链源忽略此值（直播窗口本身就是"当前"，直链保持完整文件语义）。
  final Duration startOffset;

  /// 单次网络操作（连接 / 请求 / 响应头）超时。
  final Duration timeout;

  /// 直播清单轮询兜底间隔（清单无 TARGETDURATION 时使用）。
  final Duration pollInterval;

  /// 清单最大读取字节。
  final int maxPlaylistBytes;

  final Completer<void> _firstData = Completer<void>();
  Future<void>? _runFuture;
  HttpClient? _client;
  IOSink? _sink;
  bool _stopped = false;
  final Set<String> _downloaded = {};

  /// 停止信号：`HttpClient.close(force: true)` **打不断已经返回的响应流**，
  /// 在途分片只能靠读循环自己让路。实测一个「发完响应头就沉默」的分片会把
  /// `stop()` 拖满 timeout（15s），而 `play()` 在 open 之前 await 了这个
  /// `stop()` —— 录制中切集就是一片 15 秒黑屏。
  final Completer<void> _stopSignal = Completer<void>();

  bool get isStopped => _stopped;

  /// 后台任务是否**正常跑完**（点播清单下完 / 直链读到流尾）。
  ///
  /// 与「结束」区分开：用户 stop()、源中途断流、请求报错都算「结束但未完成」。
  /// 引擎据此决定提示「录制完成」还是「录制中断」，不把正常下完也报成故障。
  bool get completed => _completed;
  bool _completed = false;

  /// 启动录制。返回时**文件里已经有真实字节**（首个分片 / 首块响应体
  /// 已写入）；拉不到源时抛 [StateError]，消息面向用户（可直接展示）。
  ///
  /// 后台下载在返回后继续进行（直播录制会一直跑到 [stop] 被调用）。
  Future<void> start() async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError('仅支持网络源（http/https）录制');
    }
    final client = _client = HttpClient();
    client.connectionTimeout = timeout;
    // 跟随系统代理环境变量（与 HlsDurationResolver 一致）。
    client.findProxy = HttpClient.findProxyFromEnvironment;
    _sink = File(outputPath).openWrite();
    // 后台错误若发生在 start() 超时之后，需要有人接住避免未处理异常。
    _firstData.future.ignore();
    // 吞掉后台错误：首份数据已落盘后的中断只影响文件完整性。
    _runFuture = _run(uri).catchError((_) {});
    // 兜底超时：个别源连首份数据都吐不出来（半死 CDN 等），30s 后如实报错。
    await _firstData.future.timeout(const Duration(seconds: 30),
        onTimeout: () =>
            throw StateError('等待视频源数据超时，无法开始录制'));
  }

  /// 后台录制任务（点播下载完整个清单 / 直播轮询被停止）何时结束。
  Future<void> get done => _runFuture ?? Future<void>.value();

  /// 停止录制并落盘收尾。重复调用安全；返回输出路径。
  ///
  /// 会等后台下载循环真正退出后再返回：否则 `stop()` 之后立即 `play()` 时，
  /// 新播放的控制流可能和旧录制器收尾抢同一批 IO 句柄。
  Future<String> stop() async {
    _stopped = true;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    // 先关客户端让在途请求失败，下载循环才会及时退出。
    _shutdownClient();
    final run = _runFuture;
    if (run != null) {
      try {
        await run;
      } catch (_) {
        // 后台错误已在 start() / 运行期处理，这里只等它结束。
      }
    }
    await _closeSink();
    _shutdownClient();
    return outputPath;
  }

  // ---------------- 内部实现 ----------------

  Future<void> _run(Uri uri) async {
    try {
      final response = await _open(uri);
      // 响应是单订阅流：用 StreamIterator 一次性消费，先嗅探 4KB
      // 判断 m3u8 / 直链，再决定剩余字节进清单解析还是进文件。
      final iterator = StreamIterator<List<int>>(response);
      final head = await _readUpTo(iterator, 4096);
      final sniff = utf8.decode(head, allowMalformed: true);
      if (sniff.contains('#EXTM3U')) {
        final rest = await _drainText(iterator, maxPlaylistBytes);
        await _cancel(iterator);
        await _recordHls(uri, sniff + rest);
      } else {
        await _append(head);
        await _dumpDirect(iterator);
      }
      // 走到这里没有任何异常：点播清单已下完 / 直链已读到流尾。
      // 用户中途 stop() 时 _stopped 为真，不算「正常完成」。
      if (!_stopped) _completed = true;
    } catch (e) {
      // 首字节还没写出去：错误必须送达 start() 的调用方。
      if (!_firstData.isCompleted) {
        _firstData.completeError(_toUserError(e));
      }
    } finally {
      await _closeSink();
      _shutdownClient();
    }
  }

  StateError _toUserError(Object e) {
    if (e is StateError) return e;
    return StateError('录制源连接失败：${_brief(e)}');
  }

  /// 追加写入并确认「首份数据已落盘」。
  Future<void> _append(List<int> bytes) async {
    _sink!.add(bytes);
    await _sink!.flush();
    _notifyFirstData();
  }

  void _notifyFirstData() {
    if (!_firstData.isCompleted) _firstData.complete();
  }

  /// 让 [future] 与停止信号赛跑：停止即抛，读循环立刻把控制权交回 `stop()`。
  /// 被放弃的 future 其错误由 [Future.any] 接管，不会变成未处理异常。
  Future<T> _cancellable<T>(Future<T> future) {
    if (_stopSignal.isCompleted) throw _aborted();
    return Future.any([
      future,
      _stopSignal.future.then<T>((_) => throw _aborted()),
    ]);
  }

  static StateError _aborted() => StateError('录制已停止');

  Future<HttpClientResponse> _open(Uri uri) async {
    final request = await _cancellable(_client!.getUrl(uri).timeout(timeout));
    headers?.forEach(request.headers.set);
    final response = await _cancellable(request.close().timeout(timeout));
    if (response.statusCode != 200) {
      await response.drain<void>().catchError((_) {});
      throw StateError('源返回 HTTP ${response.statusCode}');
    }
    return response;
  }

  /// 从迭代器读取至多 [max] 字节（不足则读到流结束）。
  Future<Uint8List> _readUpTo(
      StreamIterator<List<int>> iterator, int max) async {
    final builder = BytesBuilder(copy: false);
    var size = 0;
    while (size < max && await _cancellable(iterator.moveNext())) {
      builder.add(iterator.current);
      size += iterator.current.length;
    }
    return builder.takeBytes();
  }

  /// 读取迭代器剩余全部字节（文本用途，限长保护）。
  Future<String> _drainText(
      StreamIterator<List<int>> iterator, int max) async {
    final builder = BytesBuilder(copy: false);
    var size = 0;
    while (size <= max && await _cancellable(iterator.moveNext())) {
      builder.add(iterator.current);
      size += iterator.current.length;
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  /// 直链：把剩余响应体持续写入文件，直到源结束或用户停止。
  Future<void> _dumpDirect(StreamIterator<List<int>> iterator) async {
    try {
      while (await _cancellable(iterator.moveNext())) {
        _sink!.add(iterator.current);
        if (_stopped) break;
      }
      await _cancel(iterator);
      await _sink!.flush();
    } catch (e) {
      await _cancel(iterator);
      if (!_stopped) rethrow;
      // 用户主动停止：连接被强制关闭属预期。
    }
  }

  /// 释放迭代器，但不能因「源不再吐数据」而反噬 `stop()` 的快速返回。
  Future<void> _cancel(StreamIterator<List<int>> iterator) async {
    try {
      await _cancellable(iterator.cancel());
    } catch (_) {
      // 停止路径：句柄交给 _shutdownClient() 统一强关。
    }
  }

  Future<void> _recordHls(Uri playlistUri, String playlist) async {
    // master 清单下钻到媒体清单（最多 3 跳）。
    var base = playlistUri;
    var body = playlist;
    for (var hop = 0; hop < 3; hop++) {
      final variants = variantUris(body, base);
      if (variants.isEmpty) break;
      base = variants.first;
      final text = await _fetchText(base);
      if (text == null) throw StateError('无法获取清晰度子清单');
      body = text;
    }
    var entries = parseSegments(body, base);
    _rejectUnsupportedEncryption(entries);

    // 点播 + 指定起始偏移：跳过偏移之前的分片（片头贴片广告 / 已看部分），
    // 实现「从当前观看位置开始录制」。直播是滚动窗口，偏移无意义。
    final live = isLivePlaylist(body);
    if (!live && startOffset > Duration.zero) {
      final skip = segmentStartIndexForOffset(entries, startOffset);
      if (skip > 0) entries = entries.sublist(skip);
    }

    // fMP4 直播/点播：init 段必须写在最前，产物才能独立播放。
    final init = initSegmentUri(body, base);
    if (init != null) {
      await _downloadRawTo(init);
    }

    while (!_stopped) {
      await _downloadPending(entries, live: live);
      if (!live) break; // 点播：清单走完即完成
      final target = targetDurationSeconds(body);
      final wait = target != null && target > 0
          ? Duration(milliseconds: (target * 500).round())
          : pollInterval;
      await _cancellable(Future<void>.delayed(
          wait < const Duration(seconds: 2)
              ? const Duration(seconds: 2)
              : wait > const Duration(seconds: 10)
                  ? const Duration(seconds: 10)
                  : wait));
      final next = await _fetchText(base);
      if (next != null) {
        body = next;
        entries = parseSegments(body, base);
        _rejectUnsupportedEncryption(entries);
      }
    }
  }

  /// 加密方式在下载前就检查：SAMPLE-AES 等无法应用层解密，立即如实报错，
  /// 而不是录出打不开的加密字节。
  void _rejectUnsupportedEncryption(List<HlsSegment> entries) {
    for (final e in entries) {
      if (e.keyMethod != null &&
          e.keyMethod != 'NONE' &&
          e.keyMethod != 'AES-128') {
        throw StateError('该源使用 ${e.keyMethod} 加密，暂不支持录制');
      }
    }
  }

  /// 下载清单内尚未抓取的分片；直播单分片失败不终止会话。
  Future<void> _downloadPending(List<HlsSegment> entries,
      {required bool live}) async {
    for (final entry in entries) {
      if (_stopped) return;
      if (!_downloaded.add(entry.uri.toString())) continue;
      try {
        await _downloadTo(entry);
      } catch (e) {
        _downloaded.remove(entry.uri.toString());
        if (!live && !_firstData.isCompleted) rethrow;
        // 直播（或已有数据落盘后）：丢一段继续追清单。
      }
    }
  }

  final Map<String, Uint8List> _keyCache = {};

  /// 取 AES-128 密钥（16 字节原始内容），按 URI 缓存。
  Future<Uint8List> _fetchKey(Uri uri) async {
    final cached = _keyCache[uri.toString()];
    if (cached != null) return cached;
    final response = await _open(uri);
    final key = await _readAllBytes(response, 1024);
    if (key.length < 16) {
      throw StateError('解密密钥内容异常（不足 16 字节）');
    }
    return _keyCache[uri.toString()] = Uint8List.sublistView(key, 0, 16);
  }

  Future<void> _downloadTo(HlsSegment entry) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _open(entry.uri);
        final body = await _readAllBytes(response, maxPlaylistBytes * 8);
        final data =
            entry.isEncrypted ? await _decryptSegment(body, entry) : body;
        _sink!.add(data);
        await _sink!.flush();
        _notifyFirstData(); // HLS：首个分片 / init 段写入即视为录制开始
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('分片下载失败');
  }

  /// 未加密分片（init 段等）：直接流式落盘。
  Future<void> _downloadRawTo(Uri uri) async {
    final response = await _open(uri);
    final iterator = StreamIterator<List<int>>(response);
    try {
      while (await _cancellable(iterator.moveNext())) {
        _sink!.add(iterator.current);
      }
    } finally {
      await _cancel(iterator);
    }
    await _sink!.flush();
    _notifyFirstData();
  }

  /// 按分片携带的密钥信息解密（AES-128-CBC，IV 显式给定或用媒体序号推导）。
  Future<Uint8List> _decryptSegment(Uint8List body, HlsSegment entry) async {
    final key = await _fetchKey(entry.keyUri!);
    final iv = entry.iv ?? _ivFromSequence(entry.sequence);
    return Aes128Cbc(key).decrypt(body, iv);
  }

  /// HLS 规范：未显式给出 IV 时，IV = 128 位大端媒体序号。
  static Uint8List _ivFromSequence(int sequence) {
    final iv = Uint8List(16);
    for (var i = 15; i >= 8; i--) {
      iv[i] = (sequence >> ((15 - i) * 8)) & 0xff;
    }
    return iv;
  }

  /// 读取响应全部字节（限长保护）。
  Future<Uint8List> _readAllBytes(Stream<List<int>> stream, int max) =>
      _readAll(stream, max);

  Future<String> _readAllText(Stream<List<int>> stream, int max) async =>
      utf8.decode(await _readAll(stream, max), allowMalformed: true);

  Future<Uint8List> _readAll(Stream<List<int>> stream, int max) async {
    final iterator = StreamIterator<List<int>>(stream);
    final builder = BytesBuilder(copy: false);
    var size = 0;
    try {
      while (await _cancellable(iterator.moveNext())) {
        builder.add(iterator.current);
        size += iterator.current.length;
        if (size > max) break;
      }
    } finally {
      await _cancel(iterator);
    }
    return builder.takeBytes();
  }

  Future<String?> _fetchText(Uri uri) async {
    try {
      final response = await _open(uri);
      return await _readAllText(response, maxPlaylistBytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _closeSink() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }

  void _shutdownClient() {
    _client?.close(force: true);
    _client = null;
  }

  static String _brief(Object e) {
    final text = e.toString();
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  // ---------------- HLS 清单解析（公开供单测） ----------------

  /// 带密钥上下文的分片：`#EXT-X-KEY` 状态对**其后所有分片**生效，
  /// 直到出现新的 KEY 行。`duration` 取自分片前的 `#EXTINF`（秒）。
  static List<HlsSegment> parseSegments(String body, Uri base) {
    final out = <HlsSegment>[];
    String? keyMethod;
    Uri? keyUri;
    Uint8List? keyIv;
    var sequence = 0;
    double? pendingDuration;
    for (final raw in const LineSplitter().convert(body)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence =
            int.tryParse(line.substring(line.indexOf(':') + 1).trim()) ?? 0;
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        pendingDuration = double.tryParse(
            line.substring(line.indexOf(':') + 1).split(',').first.trim());
        continue;
      }
      if (line.startsWith('#EXT-X-KEY:')) {
        keyMethod = _attr(line, 'METHOD');
        final uriAttr = _attr(line, 'URI');
        keyUri = uriAttr == null ? null : base.resolve(uriAttr);
        final ivAttr = _attr(line, 'IV');
        keyIv = ivAttr == null ? null : _hexToBytes(ivAttr);
        continue;
      }
      if (line.startsWith('#')) continue;
      final uri = Uri.tryParse(line);
      if (uri == null) continue;
      out.add(HlsSegment(
        uri: base.resolveUri(uri),
        keyMethod: keyMethod,
        keyUri: keyUri,
        iv: keyIv,
        sequence: sequence,
        duration: pendingDuration,
      ));
      pendingDuration = null;
      sequence++;
    }
    return out;
  }

  /// 定位 [offset] 播放时刻对应的分片下标（按 EXTINF 累计时长）。
  ///
  /// 返回第一个「结束时刻 ≥ offset」的分片；偏移超出全部时长时返回
  /// 最后一个分片（保证至少有数据可录）。分片缺 EXTINF 时无法定位，返回 0。
  static int segmentStartIndexForOffset(
      List<HlsSegment> entries, Duration offset) {
    final targetMs = offset.inMilliseconds;
    if (targetMs <= 0) return 0;
    var elapsedMs = 0.0;
    for (var i = 0; i < entries.length; i++) {
      final d = entries[i].duration;
      if (d == null) return 0; // 时长信息缺失：从头录最稳妥
      elapsedMs += d * 1000;
      if (elapsedMs >= targetMs) return i;
    }
    return entries.isEmpty ? 0 : entries.length - 1;
  }

  /// 从 `ATTR=VALUE,ATTR=VALUE` 属性串取值（值可带双引号）。
  static String? _attr(String line, String name) {
    final match = RegExp('$name=("[^"]*"|[^,]*)', caseSensitive: false)
        .firstMatch(line);
    if (match == null) return null;
    var value = match.group(1)!;
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  /// `0x...` 十六进制 IV（不足 16 字节左侧补零）。
  static Uint8List? _hexToBytes(String hex) {
    final clean = hex.startsWith('0x') || hex.startsWith('0X')
        ? hex.substring(2)
        : hex;
    if (clean.length.isOdd) return null;
    final bytes = Uint8List(16);
    var offset = 16 - clean.length ~/ 2;
    if (offset < 0) return null;
    for (var i = 0; i < clean.length; i += 2) {
      final v = int.tryParse(clean.substring(i, i + 2), radix: 16);
      if (v == null) return null;
      bytes[offset + i ~/ 2] = v;
    }
    return bytes;
  }

  /// 媒体清单中的分片地址（绝对化），按出现顺序。
  static List<Uri> mediaSegments(String body, Uri base) {
    final out = <Uri>[];
    for (final raw in const LineSplitter().convert(body)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final uri = Uri.tryParse(line);
      if (uri == null) continue;
      out.add(base.resolveUri(uri));
    }
    return out;
  }

  /// 直播判定：无 `#EXT-X-ENDLIST` 且未声明 VOD。
  static bool isLivePlaylist(String body) {
    if (body.contains('#EXT-X-ENDLIST')) return false;
    return !RegExp(r'#EXT-X-PLAYLIST-TYPE:\s*VOD', caseSensitive: false)
        .hasMatch(body);
  }

  /// `#EXT-X-TARGETDURATION` 的秒数。
  static int? targetDurationSeconds(String body) {
    final match = RegExp(r'#EXT-X-TARGETDURATION:\s*(\d+)',
            caseSensitive: false)
        .firstMatch(body);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// fMP4 的 init 段（`#EXT-X-MAP:URI="..."`）。
  static Uri? initSegmentUri(String body, Uri base) {
    final match =
        RegExp(r'#EXT-X-MAP:.*?URI\s*=\s*"([^"]+)"', caseSensitive: false)
            .firstMatch(body);
    if (match == null) return null;
    return base.resolve(match.group(1)!);
  }

  /// master 清单的子清单地址（含带宽降序）。
  static List<Uri> variantUris(String body, Uri base) {
    final out = <_Variant>[];
    final lines = const LineSplitter().convert(body);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final bandwidth = RegExp(r'BANDWIDTH\s*=\s*(\d+)', caseSensitive: false)
          .firstMatch(line)
          ?.group(1);
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
      out.add(_Variant(
          base.resolve(target), int.tryParse(bandwidth ?? '') ?? 0));
    }
    out.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return out.map((e) => e.uri).toList();
  }
}

class _Variant {
  final Uri uri;
  final int bandwidth;
  const _Variant(this.uri, this.bandwidth);
}

/// 清单中的一个分片及其生效的加密状态。
class HlsSegment {
  const HlsSegment({
    required this.uri,
    this.keyMethod,
    this.keyUri,
    this.iv,
    this.duration,
    required this.sequence,
  });

  final Uri uri;
  final String? keyMethod;
  final Uri? keyUri;
  final Uint8List? iv;

  /// 分片时长（秒，取自 EXTINF；缺失为 null）。
  final double? duration;

  /// 媒体序号（未显式给 IV 时用于推导 IV）。
  final int sequence;

  bool get isEncrypted => keyMethod == 'AES-128' && keyUri != null;
}
