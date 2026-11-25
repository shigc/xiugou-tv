// 回归：肥猫配置里 `光盘|APP` 站源的 api 带 `|token` 后缀，
// 旧逻辑整串交给 Dio 会触发 `FormatException: Invalid port`，
// 导致站点直接"暂时无法加载"。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/api/cms_json_api.dart';
import 'package:xiugou_tv/core/config/models/vod_config.dart';

void main() {
  test('api 带 |token 后缀时按 | 截断，不把辅助段送进端口解析', () async {
    final captured = <Uri>[];
    final dio = Dio(BaseOptions(responseType: ResponseType.plain))
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          captured.add(options.uri);
          handler.resolve(Response(
            requestOptions: options,
            data: '{"class":[],"list":[]}',
            statusCode: 200,
          ));
        },
      ));

    final api = CmsJsonApi(dio: dio);
    const site = Site(
      key: 'guangpan',
      name: '光盘|APP',
      type: 0,
      api: 'http://103.217.190.91:5566|hagYExMdMkeWfemK',
    );

    final result = await api.fetchHome(site.api, site: site);

    expect(captured, isNotEmpty);
    final first = captured.first;
    expect(first.host, '103.217.190.91');
    expect(first.port, 5566);
    expect(first.toString(), isNot(contains('|')));
    expect(result.list, isEmpty);
  });

  test('ext 带辅助后缀时同样截断', () async {
    final captured = <Uri>[];
    final dio = Dio(BaseOptions(responseType: ResponseType.plain))
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          captured.add(options.uri);
          handler.resolve(Response(
            requestOptions: options,
            data: '{"class":[],"list":[]}',
            statusCode: 200,
          ));
        },
      ));

    final api = CmsJsonApi(dio: dio);
    const site = Site(
      key: 'csp_ext',
      name: '爬虫站',
      type: 0,
      api: 'csp_AppYsV2',
      ext: 'http://example.com:9978|abc123',
    );

    expect(api.supportsHttpEndpoint(site), isTrue);
    await api.fetchHome(site.api, site: site);
    expect(captured.first.host, 'example.com');
    expect(captured.first.port, 9978);
    expect(captured.first.toString(), isNot(contains('|')));
  });
}
