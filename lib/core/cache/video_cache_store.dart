import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../player/models/player_state.dart';
import '../settings/models/video_cache_preferences.dart';

/// 缓存进度快照（进度条 / 信息面板共用）。
class VideoCacheProgress {
  /// 正在缓存的源地址（哈希前缀对应的清单 / 直链）
  final String url;

  /// 已缓存到磁盘的时长（点播 HLS 为分片时长累加；mp4 直链按字节比例折算）
  final int cachedMs;

  /// 总时长；未知（如 mp4 无时长）时为 0
  final int totalMs;

  /// 已写入字节数
  final int cachedBytes;

  /// 顺播方向的缓存前沿（绝对时间）：从起播位置向后连续下载到的位置。
  /// 进度条在「播放位置 → 前沿」之间画缓存带。
  final int frontierMs;

  /// 回填前缀的已缓存时长：前沿到达片尾后回头补片的进度（绝对时间）。
  final int prefixMs;

  /// 整段缓存完成
  final bool done;

  /// 缓存因错误中断时的说明（不影响播放本身）
  final String? error;

  const VideoCacheProgress({
    this.url = '',
    this.cachedMs = 0,
    this.totalMs = 0,
    this.cachedBytes = 0,
    this.frontierMs = 0,
    this.prefixMs = 0,
    this.done = false,
    this.error,
  });

  /// 缓存完成比例（0..1）；总时长未知时按「有缓存就算有进度」给 0，避免画满。
  double get fraction =>
      totalMs > 0 ? (cachedMs / totalMs).clamp(0.0, 1.0) : 0.0;

  VideoCacheProgress copyWith({
    int? cachedMs,
    int? totalMs,
    int? cachedBytes,
    int? frontierMs,
    int? prefixMs,
    bool? done,
    String? error,
  }) =>
      VideoCacheProgress(
        url: url,
        cachedMs: cachedMs ?? this.cachedMs,
        totalMs: totalMs ?? this.totalMs,
        cachedBytes: cachedBytes ?? this.cachedBytes,
        frontierMs: frontierMs ?? this.frontierMs,
        prefixMs: prefixMs ?? this.prefixMs,
        done: done ?? this.done,
        error: error,
      );
}

/// 单个 HLS 分片在缓存清单里的一条记录。
class _CachedSegment {
  final int index;
  final String fileName;
  final int durationMs;
  final String url;
  const _CachedSegment(this.index, this.fileName, this.durationMs, this.url);
}

/// 视频本地缓存下载器。
///
/// 设计要点：
/// - **与播放状态无关**：由引擎在起播时启动，暂停 / 拖动都不影响下载，
  /// 只有停止播放、切换片源或用户关闭缓存才会中断 —— 这正是「暂停也能
  /// 继续缓存」的实现方式（下载不挂在播放器事件上）。
/// - **顺序前缀缓存**：按分片顺序从第 0 片往后下，天然形成「已缓存前缀」，
///   进度条上就是一段从左往右推进的实心区。
/// - **断点续传**：每个分片落盘前先查存在且非空，重复起播不重下；
///   mp4 直链用 HTTP Range 续传。
/// - **容量上限**：超过偏好里的上限即停止新写入（已有文件保留，供清理入口删除）。
class VideoCacheStore {
  VideoCachePreferences _prefs = const VideoCachePreferences();

  HttpClient? _client;

  CancelToken? _token;
  VideoCacheProgress _progress = const VideoCacheProgress();
  final _progressController = StreamController<VideoCacheProgress>.broadcast();
  Timer? _progressThrottle;

  static const int _segmentBytesWarn = 512 * 1024 * 1024; // 单任务异常保护
  static const Duration _requestTimeout = Duration(seconds: 30);

  Stream<VideoCacheProgress> get progressStream => _progressController.stream;
  VideoCacheProgress get progress => _progress;

  /// 当前缓存是否在跑（用于设置页 / 信息面板展示状态）
  bool get isRunning => _token != null && !_token!.cancelled;

  /// 用户自定义的缓存根目录；未设置时为 null（落到默认位置）。
  String? get configuredDirectory {
    final custom = _prefs.directory?.trim();
    return (custom != null && custom.isNotEmpty) ? custom : null;
  }

  /// 生效的缓存根目录（绝对路径）。[defaultRoot] 为应用数据目录下的默认位置。
  String effectiveRoot(String defaultRoot) {
    final custom = _prefs.directory?.trim();
    return (custom != null && custom.isNotEmpty) ? custom : defaultRoot;
  }

  /// 应用最新偏好：目录 / 上限 / 开关即时生效。
  ///
  /// 关闭缓存会立刻中断当前下载（已下载文件保留，由「清空缓存」负责删除）。
  Future<void> applyPreferences(VideoCachePreferences prefs,
      {required String defaultRoot}) async {
    final wasEnabled = _prefs.enabled;
    _prefs = prefs;
    if (!prefs.enabled && wasEnabled) stop();
  }

  /// 开始缓存 [spec] 指向的视频。重复调用会先停掉上一个任务。
  ///
  /// 非 http(s) 地址、直播流与解析失败都不缓存，但**绝不抛异常**——
  /// 缓存是播放的旁路功能，任何失败都不应影响播放主链路。
  Future<void> start(MediaPlaySpec spec, {required String defaultRoot}) async {
    stop();
    if (!_prefs.enabled) return;
    final uri = Uri.tryParse(spec.url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return;
    if (spec.isLive) return; // 直播是滑动窗口，缓存整段没有意义

    _token = CancelToken();
    final token = _token!;
    _progress = VideoCacheProgress(url: spec.url);
    _emit(force: true);

    // 后台执行：起播链路不等待缓存准备
    unawaited(_run(spec, uri, token, defaultRoot));
  }

  /// 停止当前缓存任务（保留已下载内容）。
  void stop() {
    _token?.cancel();
    _token = null;
    _progressThrottle?.cancel();
    _progressThrottle = null;
  }

  Future<void> dispose() async {
    stop();
    await _progressController.close();
    _client?.close(force: true);
    _client = null;
  }

  // ---------------- 主流程 ----------------

  Future<void> _run(MediaPlaySpec spec, Uri uri, CancelToken token,
      String defaultRoot) async {
    try {
      final root = effectiveRoot(defaultRoot);
      final key = crypto.sha1.convert(utf8.encode(spec.url)).toString();
      // 量一次真实占用并把超限的老任务淘汰掉。要放在创建自己的任务目录
      // **之前**，否则可能把自己刚建的目录当最久未用的淘汰掉。
      await _measureAndEvict(root, excludeKey: key);
      final taskDir = Directory(p.join(root, key));
      await taskDir.create(recursive: true);

      final playlist = await _resolvePlaylist(uri, spec.headers, token);
      if (token.cancelled) return;
      if (playlist == null) {
        // 非 HLS：整文件直下（mp4 / mkv 等）
        await _cacheDirectFile(uri, spec.headers, taskDir, token, key);
        return;
      }
      await _cacheHls(spec, playlist, taskDir, token, key);
    } on CacheCancelled {
      return;
    } catch (e) {
      _progress = _progress.copyWith(error: '缓存中断：$e');
      _emit(force: true);
    }
  }

  Future<void> _cacheHls(MediaPlaySpec spec, _Playlist playlist,
      Directory taskDir, CancelToken token, String key) async {
    final startMs = spec.startPosition?.inMilliseconds ?? 0;
    // 1) 写清单元数据（幂等：同地址重复播放复用）
    final metaFile = File(p.join(taskDir.path, 'meta.json'));
    final meta = <String, dynamic>{
      'version': 1,
      'url': spec.url,
      'title': spec.title,
      'totalMs': playlist.totalMs,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'segments': [
        for (final s in playlist.segments)
          {'i': s.index, 'file': s.fileName, 'ms': s.durationMs, 'url': s.url},
      ],
    };
    await _atomicWrite(metaFile, jsonEncode(meta));

    _progress = VideoCacheProgress(url: spec.url, totalMs: playlist.totalMs);
    _emit(force: true);

    // 2) 下载顺序：先从起播位置向后（缓存带立刻出现在播放位置前方），
    //    到片尾后再回头补齐前缀 —— 续播时进度条上也能马上看到缓存推进。
    final segs = playlist.segments;
    var startIdx = 0;
    var acc = 0;
    for (var i = 0; i < segs.length; i++) {
      if (acc >= startMs) break;
      acc += segs[i].durationMs;
      startIdx = i + 1;
    }
    if (startIdx >= segs.length) startIdx = 0;
    final startBaseMs = acc; // 起始分片的时间起点
    final order = <_CachedSegment>[
      for (var i = startIdx; i < segs.length; i++) segs[i],
      for (var i = 0; i < startIdx; i++) segs[i],
    ];

    var cachedMs = 0;
    var bytes = 0;
    var aheadMs = 0; // 顺播方向已连续缓存的时长（从起播位置起算）
    var prefixMs = 0; // 回填前缀的时长
    for (final seg in order) {
      if (token.cancelled) return;
      if (_overLimit()) {
        // 任务开始时的淘汰不够：一个长视频自己就能把水位顶穿。
        // 先回头淘汰别的任务（顺带用真实扫描校正累加漂移），仍塞不下才停。
        await _measureAndEvict(taskDir.parent.path, excludeKey: key);
      }
      if (_overLimit()) {
        _progress = _progress.copyWith(error: '已达缓存容量上限（${_prefs.maxSizeGb}GB），停止写入');
        _emit(force: true);
        return;
      }
      final inPrefix = seg.index < startIdx;
      final file = File(p.join(taskDir.path, seg.fileName));
      final alreadyCached = await file.exists() && await file.length() > 0;
      if (!alreadyCached) {
        final ok = await _downloadToFile(
          Uri.parse(seg.url),
          spec.headers,
          file,
          token,
          // 逐块累加：单个大分片也能在写入过程中撞上上限，而不是下一片才发现。
          onBytes: (n) => _lastKnownSizeBytes += n,
        );
        if (token.cancelled) return;
        if (!ok) {
          _progress = _progress.copyWith(
              error: '分片下载失败（${seg.index + 1}/${segs.length}）');
          _emit(force: true);
          return;
        }
      }
      cachedMs += seg.durationMs;
      bytes += await file.length();
      if (inPrefix) {
        prefixMs += seg.durationMs;
      } else {
        aheadMs += seg.durationMs;
      }
      _progress = VideoCacheProgress(
          url: spec.url,
          totalMs: playlist.totalMs,
          cachedMs: cachedMs,
          cachedBytes: bytes,
          frontierMs: inPrefix ? _progress.frontierMs : startBaseMs + aheadMs,
          prefixMs: prefixMs);
      _emit();
    }
    _progress = _progress.copyWith(
        done: true, frontierMs: playlist.totalMs, prefixMs: startBaseMs);
    _emit(force: true);
  }

  /// 非 HLS 直链（mp4 等）：单文件 Range 续传。
  Future<void> _cacheDirectFile(Uri uri, Map<String, String>? headers,
      Directory taskDir, CancelToken token, String key) async {
    final file = File(p.join(taskDir.path, 'video${_extOf(uri)}'));
    final existing = await file.exists() ? await file.length() : 0;

    final client = _httpClient();
    final req = await client.getUrl(uri).timeout(_requestTimeout);
    headers?.forEach(req.headers.set);
    if (existing > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
    final res = await req.close().timeout(_requestTimeout);
    if (res.statusCode != 200 && res.statusCode != 206) {
      _progress = _progress.copyWith(error: '缓存请求失败 HTTP ${res.statusCode}');
      _emit(force: true);
      return;
    }
    final totalLen = int.tryParse(res.headers.value(HttpHeaders.contentLengthHeader) ?? '');
    final totalBytes = res.statusCode == 206 ? existing + (totalLen ?? 0) : (totalLen ?? 0);
    // totalBytes 仅用于校验 Content-Length 合法性；进度按字节累积展示
    assert(totalBytes >= 0);
    _progress = VideoCacheProgress(
        url: uri.toString(), cachedMs: 0, totalMs: 0, cachedBytes: existing);
    _emit(force: true);

    var written = existing;
    final sink = file.openWrite(mode: FileMode.append);
    try {
      await for (final chunk in res.timeout(_requestTimeout)) {
        if (token.cancelled) return;
        written += chunk.length;
        _lastKnownSizeBytes += chunk.length;
        sink.add(chunk);
        _progress = VideoCacheProgress(
            url: uri.toString(), totalMs: 0, cachedBytes: written);
        _emit();
        if (written > _segmentBytesWarn) {
          _progress = _progress.copyWith(error: '文件过大，已停止缓存');
          _emit(force: true);
          return;
        }
        // 直链此前只受 512MB 单文件保护，完全绕过了用户的容量上限。
        if (_overLimit()) {
          await _measureAndEvict(taskDir.parent.path, excludeKey: key);
        }
        if (_overLimit()) {
          _progress =
              _progress.copyWith(error: '已达缓存容量上限（${_prefs.maxSizeGb}GB），停止写入');
          _emit(force: true);
          return;
        }
      }
      await sink.flush();
      _progress = _progress.copyWith(done: true, cachedBytes: written);
      _emit(force: true);
    } finally {
      await sink.close();
    }
  }

  // ---------------- 清单解析 ----------------

  Future<_Playlist?> _resolvePlaylist(
      Uri uri, Map<String, String>? headers, CancelToken token) async {
    var current = uri;
    for (var hop = 0; hop < 4; hop++) {
      if (token.cancelled) throw const CacheCancelled();
      final body = await _fetchText(current, headers, token);
      if (body == null || !body.contains('#EXTM3U')) return null;

      final variants = _variantUris(body, current);
      if (variants.isNotEmpty) {
        current = variants.first;
        continue;
      }
      final isVod = body.contains('#EXT-X-ENDLIST') ||
          RegExp(r'#EXT-X-PLAYLIST-TYPE:\s*VOD', caseSensitive: false)
              .hasMatch(body);
      if (!isVod) return null; // 直播清单不缓存

      final segments = _mediaSegments(body, current);
      if (segments.isEmpty) return null;
      final totalMs = segments.fold<int>(0, (a, s) => a + s.durationMs);
      return _Playlist(segments, totalMs);
    }
    return null;
  }

  List<_CachedSegment> _mediaSegments(String body, Uri base) {
    final lines = const LineSplitter().convert(body);
    final out = <_CachedSegment>[];
    final extInf = RegExp(r'#EXTINF:\s*([0-9]+(?:\.[0-9]+)?)', caseSensitive: false);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      final m = extInf.firstMatch(line);
      if (m == null) continue;
      String? target;
      for (var j = i + 1; j < lines.length; j++) {
        final next = lines[j].trim();
        if (next.isEmpty || next.startsWith('#')) continue;
        target = next;
        i = j;
        break;
      }
      if (target == null) continue;
      final seconds = double.tryParse(m.group(1)!) ?? 0;
      out.add(_CachedSegment(out.length, 'seg_${out.length.toString().padLeft(6, '0')}.ts',
          (seconds * 1000).round(), base.resolve(target).toString()));
    }
    return out;
  }

  List<Uri> _variantUris(String body, Uri base) {
    final out = <Uri>[];
    final lines = const LineSplitter().convert(body);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      var target =
          RegExp(r'URI\s*=\s*"([^"]+)"').firstMatch(line)?.group(1);
      if (target == null) {
        for (var j = i + 1; j < lines.length; j++) {
          final next = lines[j].trim();
          if (next.isEmpty) continue;
          if (next.startsWith('#')) break;
          target = next;
          break;
        }
      }
      if (target != null) out.add(base.resolve(target));
    }
    return out;
  }

  // ---------------- 网络与磁盘 ----------------

  HttpClient _httpClient() => _client ??= HttpClient()
    ..connectionTimeout = _requestTimeout
    ..findProxy = HttpClient.findProxyFromEnvironment;

  Future<String?> _fetchText(
      Uri uri, Map<String, String>? headers, CancelToken token) async {
    final client = _httpClient();
    final req = await client.getUrl(uri).timeout(_requestTimeout);
    headers?.forEach(req.headers.set);
    final res = await req.close().timeout(_requestTimeout);
    if (res.statusCode != 200) return null;
    final builder = BytesBuilder(copy: false);
    var size = 0;
    await for (final chunk in res.timeout(_requestTimeout)) {
      if (token.cancelled) throw const CacheCancelled();
      size += chunk.length;
      if (size > 8 * 1024 * 1024) break;
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  /// 下载到文件；成功（含断点续传）返回 true，失败返回 false，取消抛 [CacheCancelled]。
  Future<bool> _downloadToFile(Uri uri, Map<String, String>? headers, File file,
      CancelToken token, {void Function(int)? onBytes}) async {
    final client = _httpClient();
    final existing = await file.exists() ? await file.length() : 0;
    final req = await client.getUrl(uri).timeout(_requestTimeout);
    headers?.forEach(req.headers.set);
    if (existing > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
    final res = await req.close().timeout(_requestTimeout);
    if (res.statusCode != 200 && res.statusCode != 206) return false;

    final tmp = File('${file.path}.part');
    final sink = tmp.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in res.timeout(_requestTimeout)) {
        if (token.cancelled) throw const CacheCancelled();
        sink.add(chunk);
        onBytes?.call(chunk.length);
      }
      await sink.flush();
      await sink.close();
      await tmp.rename(file.path);
      return true;
    } on CacheCancelled {
      await sink.close();
      rethrow;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      return false;
    }
  }

  /// 测量缓存目录真实占用，并在超限时按「最久没写入的任务目录」整体淘汰到 80% 水位。
  ///
  /// 测量不能省：`_lastKnownSizeBytes` 只在下载过程中累加，进程重启、外部清理
  /// 都会让它失真；而它此前一直是 0（没有任何调用方喂过真实占用），于是
  /// 「超限淘汰」与「超限停止写入」两条路径都永远不触发——上限形同虚设。
  /// 这条扫描跑在后台任务里（`_run` 由起播链路 unawait），不压起播等待。
  ///
  /// 淘汰依据是任务目录内文件的最近修改时间（= 下载完成时间）。读取不更新
  /// mtime，所以这是 FIFO 而非严格 LRU，但语义正是「先缓存的老剧集先走」。
  /// 按整个任务目录淘汰而不是挑单个分片：淘汰半截会让续播时缺分片。
  Future<void> _measureAndEvict(String root, {String? excludeKey}) async {
    final limitBytes = _limitBytes;
    if (limitBytes <= 0) return;
    final total = await _measure(root, excludeKey: excludeKey);
    // 测量失败（total 为 null）保持既有计数：宁可不动，也不能影响缓存主流程。
    if (total == null) return;
    _lastKnownSizeBytes = total.value;
    if (total.value <= limitBytes) return;
    final target = (limitBytes * 0.8).round();
    var current = total.value;
    final tasks = [...total.tasks]..sort((a, b) => a.stamp.compareTo(b.stamp));
    for (final task in tasks) {
      if (current <= target) break;
      try {
        await task.dir.delete(recursive: true);
        current -= task.size;
      } on FileSystemException {
        // 被占用（正在播放）就跳过，继续下一个
      }
    }
    _lastKnownSizeBytes = current < 0 ? 0 : current;
  }

  /// 一次遍历得到「总占用 + 可淘汰的任务目录」；[excludeKey] 对应的目录
  /// 计入总量但不参与淘汰（那正是当前任务自己，续播时它的 mtime 可能是旧的）。
  Future<_CacheMeasure?> _measure(String root, {String? excludeKey}) async {
    try {
      final dir = Directory(root);
      if (!await dir.exists()) return const _CacheMeasure(0, []);
      final tasks = <_CacheTask>[];
      var total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory) {
          // 根目录下的散落文件也要计入，否则测量值系统性偏小。
          if (entity is File) {
            try {
              total += await entity.length();
            } on FileSystemException {
              // 读不到大小的文件按 0 计入
            }
          }
          continue;
        }
        var stamp = DateTime.fromMillisecondsSinceEpoch(0);
        var size = 0;
        await for (final f
            in entity.list(recursive: true, followLinks: false)) {
          if (f is! File) continue;
          try {
            final stat = await f.stat();
            if (stat.modified.isAfter(stamp)) stamp = stat.modified;
            size += stat.size;
          } on FileSystemException {
            // 个别文件读不到不影响整体统计
          }
        }
        total += size;
        if (excludeKey != null && p.basename(entity.path) == excludeKey) {
          continue;
        }
        tasks.add(_CacheTask(entity, stamp, size));
      }
      return _CacheMeasure(total, tasks);
    } catch (_) {
      return null;
    }
  }

  int get _limitBytes => _prefs.maxSizeGb * 1024 * 1024 * 1024;

  /// 容量上限判断：缓存根目录总占用超过偏好上限即停止新写入。
  bool _overLimit() {
    final limitBytes = _limitBytes;
    if (limitBytes <= 0) return false;
    return _lastKnownSizeBytes > limitBytes;
  }

  int _lastKnownSizeBytes = 0;

  void _emit({bool force = false}) {
    if (_progressController.isClosed) return;
    if (!force) {
      // 节流：250ms 内的更新合并（分片很小的时候避免刷爆进度条订阅）
      _progressThrottle ??= Timer(const Duration(milliseconds: 250), () {
        _progressThrottle = null;
        if (!_progressController.isClosed) _progressController.add(_progress);
      });
      return;
    }
    _progressThrottle?.cancel();
    _progressThrottle = null;
    _progressController.add(_progress);
  }

  static String _extOf(Uri uri) {
    final path = uri.path.toLowerCase();
    for (final ext in const ['.mp4', '.mkv', '.flv', '.ts', '.mov', '.webm']) {
      if (path.endsWith(ext)) return ext;
    }
    return '.mp4';
  }

  static Future<void> _atomicWrite(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(target.path);
  }

  /// 清空缓存根目录 [root]（绝对路径）；返回释放的字节数。占用中的文件会被跳过。
  ///
  /// 静态方法：设置页在引擎实例之外也能直接调用。
  static Future<int> clearAll(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return 0;
    var freed = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        final size = await entity.length();
        await entity.delete();
        freed += size;
      } on FileSystemException {
        // 占用 / 权限问题跳过，不中断整体清理
      }
    }
    // 清掉空目录
    await for (final d in dir.list(recursive: true, followLinks: false)) {
      if (d is Directory) {
        try {
          if (await d.list().isEmpty) await d.delete();
        } on FileSystemException {
          // 只清空文件，目录删不掉不影响结果
        }
      }
    }
    return freed;
  }

  /// 统计缓存目录总占用（字节）。
  static Future<int> totalSize(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } on FileSystemException {
        // 读不到大小的文件按 0 计入，不让统计失败
      }
    }
    return total;
  }
}

class _Playlist {
  final List<_CachedSegment> segments;
  final int totalMs;
  const _Playlist(this.segments, this.totalMs);
}

/// 一次目录遍历的产物：总占用与可淘汰的任务目录。
class _CacheMeasure {
  final int value;
  final List<_CacheTask> tasks;
  const _CacheMeasure(this.value, this.tasks);
}

class _CacheTask {
  final Directory dir;
  final DateTime stamp;
  final int size;
  const _CacheTask(this.dir, this.stamp, this.size);
}

/// 任务被取消（停止播放 / 切片 / 关闭缓存）——静默返回，不报错误。
class CacheCancelled implements Exception {
  const CacheCancelled();
}

/// 协作式取消标记（不依赖 dart:async 的实现细节）。
class CancelToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}
