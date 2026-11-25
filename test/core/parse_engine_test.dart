import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/api/parse_engine.dart';
import 'package:xiugou_tv/core/config/models/vod_config.dart';

/// 起播提速回归：ParseEngine 的单请求限时、整轮预算与失败熔断。
void main() {
  late HttpServer server;
  late String host;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// 路由：/ok 秒回直链；/slow 挂 12 秒后才回（用于触发限时）。
  /// [slowDelayOk] 为 false 时 /ok 也改回空结果，模拟接口废弃。
  void serve({bool slowDelayOk = true, bool okReturnsUrl = true}) {
    server.listen((request) async {
      final path = request.uri.path;
      request.response.headers
          .set('content-type', 'application/json; charset=utf-8');
      if (path == '/ok') {
        request.response.write(okReturnsUrl
            ? jsonEncode({'url': 'https://cdn.example.com/play.m3u8'})
            : jsonEncode({'code': 404, 'msg': 'gone'}));
      } else if (path == '/slow') {
        if (slowDelayOk) {
          await Future<void>.delayed(const Duration(seconds: 12));
        }
        request.response
            .write(jsonEncode({'url': 'https://slow.example.com/play.m3u8'}));
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('{}');
      }
      await request.response.close();
    });
  }

  Parse parseAt(String path) =>
      Parse(name: path, type: 1, url: '$host$path?u=');

  test('直链媒体地址不发起任何解析请求', () async {
    serve();
    final engine = ParseEngine();
    final spec = await engine.parse(
      'https://cdn.example.com/video.m3u8',
      parses: [parseAt('/slow')],
    );
    expect(spec.url, 'https://cdn.example.com/video.m3u8');
  });

  test('解析成功返回直链', () async {
    serve();
    final engine = ParseEngine();
    final spec = await engine.parse(
      'https://host/vod/123',
      parses: [parseAt('/ok')],
    );
    expect(spec.url, 'https://cdn.example.com/play.m3u8');
  });

  test('死解析按单请求限时收敛，不拖满默认超时', () async {
    // /slow 挂 12 秒：receive 8 秒触发超时，整轮回落直连。
    serve();
    final engine = ParseEngine();
    final sw = Stopwatch()..start();
    final spec = await engine.parse(
      'https://host/vod/123',
      parses: [parseAt('/slow')],
    );
    sw.stop();
    expect(spec.url, 'https://host/vod/123');
    expect(sw.elapsedMilliseconds, lessThan(11000));
  });

  test('失败解析进入熔断：第二次调用立刻跳过，改口直连', () async {
    serve();
    final engine = ParseEngine();
    final first = await engine.parse(
      'https://host/vod/123',
      parses: [parseAt('/slow')],
    );
    expect(first.url, 'https://host/vod/123');

    final sw = Stopwatch()..start();
    final second = await engine.parse(
      'https://host/vod/456',
      parses: [parseAt('/slow')],
    );
    sw.stop();
    expect(second.url, 'https://host/vod/456');
    // 熔断期内不再发请求，应远快于一次超时。
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('空结果（接口废弃）同样计熔断；健康解析不受影响', () async {
    serve(okReturnsUrl: false);
    final engine = ParseEngine();
    final first = await engine.parse(
      'https://host/vod/123',
      parses: [parseAt('/ok')],
    );
    expect(first.url, 'https://host/vod/123');

    final sw = Stopwatch()..start();
    await engine.parse('https://host/vod/456', parses: [parseAt('/ok')]);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('整轮预算兜底：多条慢解析不会叠加成长尾', () async {
    serve();
    final engine = ParseEngine();
    final sw = Stopwatch()..start();
    await engine.parse(
      'https://host/vod/123',
      parses: [parseAt('/slow'), parseAt('/slow'), parseAt('/slow')],
    );
    sw.stop();
    // 无预算时 3 × 12s+；预算 15s 应显著收敛。
    expect(sw.elapsedMilliseconds, lessThan(16000));
  });

  test('全部熔断时清空熔断表再试，不把 requireResolved 链路锁死', () async {
    serve(okReturnsUrl: false);
    final engine = ParseEngine();
    // 让唯一解析进入熔断。
    await expectLater(
      engine.parse('https://host/vod/1',
          parses: [parseAt('/ok')], requireResolved: true),
      throwsFormatException,
    );
    // 此刻 /ok 处于熔断期且是全部候选：应触发「清空后重试一轮」，
    // 依旧失败（而不是被熔断直接跳过、连一次机会都不给）。
    final sw = Stopwatch()..start();
    await expectLater(
      engine.parse('https://host/vod/2',
          parses: [parseAt('/ok')], requireResolved: true),
      throwsFormatException,
    );
    sw.stop();
    // 走的是真实请求（接口返回快），不是 8 秒超时。
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('无解析配置时回落直连播放', () async {
    serve();
    final engine = ParseEngine();
    final spec = await engine.parse('https://host/vod/123', parses: const []);
    expect(spec.url, 'https://host/vod/123');
  });
}
