import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../storage/data_directory_manager.dart';

/// 海报 / 台标的磁盘缓存。
///
/// 在此之前，网络图片只进 Flutter 的内存 ImageCache（上限被收到 48MB），
/// 进程一退就全没了：每次冷启动所有海报都要重新下载，来回滑动还要反复
/// 重新解码。这里在图片解码器前面加一层按 URL 散列的磁盘缓存。
///
/// 用 dart:io 直写，不引第三方依赖；目录就是数据目录下的 `poster_cache/`。
///
/// 淘汰策略是按写入时间的 FIFO，不是严格 LRU：命中时不去更新文件 mtime，
/// 省掉每次读图都要写一次元数据的开销——海报的访问模式都差不多，
/// 「最久没写入的先走」和「最久没用的先走」实际效果一致。
class PosterCacheStore {
  PosterCacheStore._();

  static final PosterCacheStore instance = PosterCacheStore._();

  /// 条目上限（超出按最久未写入淘汰）
  static const int maxEntries = 400;

  /// 每写入这么多次才扫一次目录，避免每下载一张图就全盘扫
  static const int _sweepEveryWrites = 64;

  Directory? _dir;
  int _writesSinceSweep = 0;
  bool _sweeping = false;

  Directory _directory() => _dir ??= Directory(
      '${DataDirectoryManager.currentPath}${Platform.pathSeparator}poster_cache');

  /// 两个 32 位哈希串起来当 64 位用，碰撞概率可忽略。
  ///
  /// 不直接用 URL 当文件名：长度不可控，还可能含非法字符。
  String _fileNameFor(String url) {
    var h1 = 5381;
    var h2 = 0;
    for (final unit in url.codeUnits) {
      h1 = ((h1 << 5) + h1 + unit) & 0xFFFFFFFF;
      h2 = (unit + (h2 << 6) + (h2 << 16) - h2) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(36)}-${h2.toRadixString(36)}';
  }

  File _fileFor(String url) => File(
      '${_directory().path}${Platform.pathSeparator}${_fileNameFor(url)}');

  /// 命中返回字节；未命中或读出错都返回 null（缓存不该影响正常加载）。
  Future<Uint8List?> read(String url) async {
    try {
      final file = _fileFor(url);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String url, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    try {
      final dir = _directory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _fileFor(url).writeAsBytes(bytes, flush: false);
      if (++_writesSinceSweep >= _sweepEveryWrites) {
        _writesSinceSweep = 0;
        unawaited(_sweep());
      }
    } catch (_) {
      // 缓存写不进去就算了，不能让图片加载跟着失败
    }
  }

  /// 按写入时间淘汰到 [maxEntries] 以内。
  Future<void> _sweep() async {
    if (_sweeping) return;
    _sweeping = true;
    try {
      final dir = _directory();
      if (!await dir.exists()) return;
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      if (files.length <= maxEntries) return;
      final stamps = <File, DateTime>{};
      for (final file in files) {
        stamps[file] = await file.lastModified();
      }
      final oldest = stamps.keys.toList()
        ..sort((a, b) => stamps[a]!.compareTo(stamps[b]!));
      for (var i = 0; i < files.length - maxEntries; i++) {
        await oldest[i].delete().catchError((Object _) => oldest[i]);
      }
    } catch (_) {
    } finally {
      _sweeping = false;
    }
  }
}
