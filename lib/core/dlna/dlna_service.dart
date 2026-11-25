import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../diagnostics/app_logger.dart';
import 'dlna_device.dart';

/// DLNA 投屏服务：SSDP 设备发现 + AVTransport SOAP 控制。
///
/// 全部基于 `dart:io`（UDP 组播 + HTTP POST），零第三方网络依赖；
/// `xml` 包仅用于解析设备描述文档（本就在依赖清单中）。
///
/// 生命周期：[discover] 可反复调用；[setUri] / [play] / [pause] / [stop]
/// 面向最近一次推送的设备；[dispose] 关闭内部 HTTP 客户端。
class DlnaService {
  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;

  /// 多 ST 探测：部分电视只响应其中一种（实测某些品牌不回 MediaRenderer，
  /// 只回 rootdevice / ssdp:all）。
  static const List<String> _searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'upnp:rootdevice',
    'ssdp:all',
  ];

  /// 按 IP 直连探测：常见 UPnP 描述端口 × 常见描述路径。
  /// （SSDP 被防火墙 / 组播路由 / 电视不响应 M-SEARCH 卡住时的兜底通道。）
  static const List<int> _probePorts = [
    49152, 49153, 49154, // UPnP 动态端口最常见区间
    5000, 7676, 8200, 1400, 40000, 1025, 2869, 1901,
  ];

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  /// 最近一次成功推送的设备（后续 play/pause/stop 的默认目标）。
  DlnaDevice? _currentDevice;
  DlnaDevice? get currentDevice => _currentDevice;

  /// 发现局域网内的 DLNA 渲染设备（电视 / 盒子）。
  ///
  /// [duration] 为收集 SSDP 报文的窗口（同时收 M-SEARCH 单播响应与
  /// 设备的 `ssdp:alive` NOTIFY 广播）。窗口结束后并发拉取各设备描述
  /// XML 补全 friendlyName 与 AVTransport 控制地址。
  /// 返回按名称排序的去重设备列表（仅保留可投屏的）。
  Future<List<DlnaDevice>> discover({
    Duration duration = const Duration(seconds: 4),
  }) async {
    final found = <String, DlnaDevice>{};
    final sockets = <RawDatagramSocket>[];
    try {
      // 多网卡机器（VPN / 虚拟网卡）组播可能走错出口：对每个非回环 IPv4
      // 接口各绑一个套接字并加入组播组，收包覆盖全部接口。
      final bindTargets = <InternetAddress>[InternetAddress.anyIPv4];
      try {
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          includeLinkLocal: false,
        );
        for (final ni in interfaces) {
          for (final addr in ni.addresses) {
            if (addr.type == InternetAddressType.IPv4) {
              bindTargets.add(addr);
            }
          }
        }
      } catch (_) {
        // 枚举失败退回单 anyIPv4。
      }
      for (final addr in bindTargets.take(8)) {
        final RawDatagramSocket socket;
        try {
          socket = await RawDatagramSocket.bind(addr, 0, reuseAddress: true);
        } on SocketException {
          continue; // 个别接口绑定失败不影响其余。
        }
        try {
          socket.joinMulticast(InternetAddress(_ssdpAddress));
        } catch (_) {}
        // 多 ST 各发两遍，丢包时提高命中率。
        for (final st in _searchTargets) {
          final packet = _buildMSearch(st);
          socket.send(packet, InternetAddress(_ssdpAddress), _ssdpPort);
          socket.send(packet, InternetAddress(_ssdpAddress), _ssdpPort);
        }
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          final device = _parseSsdpPacket(datagram);
          if (device != null) {
            // 同 USN 后到不影响先到；地址解析在窗口后统一补全。
            found.putIfAbsent(device.usn, () => device);
          }
        });
        sockets.add(socket);
      }
      await Future<void>.delayed(duration);
    } on SocketException catch (e) {
      AppLogger.instance.warning('dlna', 'SSDP 发现失败', error: e);
      // 发现失败不致命：返回空列表，UI 提示检查网络/防火墙。
    } finally {
      for (final socket in sockets) {
        socket.close();
      }
    }

    if (found.isEmpty) return const [];
    return _resolveAll(found.values.toList());
  }

  /// 按 IP 直连探测一台设备的 UPnP 描述服务。
  ///
  /// 两级策略：
  /// 1. 常见端口 × 常见描述路径并发 GET（毫秒级）；
  /// 2. 未命中且 [deepScan] 时，TCP 扫描 UPnP 动态端口段（49152-65535 与
  ///    1024-5000），对开放端口再探测描述路径 —— TCL 等品牌的服务端口
  ///    经常落在非常见端口上。
  /// SSDP 被防火墙拦组播但放行出站 TCP 时可用。未命中返回 null。
  Future<DlnaDevice?> probeDevice(
    String host, {
    Duration timeout = const Duration(seconds: 2),
    bool deepScan = true,
  }) async {
    final ip = host.trim();
    if (ip.isEmpty) return null;

    Future<DlnaDevice?> tryProbe(int port) async {
      final location = 'http://$ip:$port/description.xml';
      final resolved = await _probeLocation(location, ip, port, timeout);
      if (resolved != null) return resolved;
      // 主路径未命中时对同一端口补测其余常见路径。
      for (final path in const ['/dd.xml', '/devicedescription.xml']) {
        final device = await _probeLocation(
            'http://$ip:$port$path', ip, port, timeout);
        if (device != null) return device;
      }
      return null;
    }

    // 1) 常见端口。
    final common = await Future.wait(_probePorts.map(tryProbe));
    for (final device in common) {
      if (device != null) return device;
    }
    if (!deepScan) return null;

    // 2) 深度扫描：UPnP 动态端口段。
    final openPorts = await _scanOpenPorts(ip);
    for (final port in openPorts) {
      if (_probePorts.contains(port)) continue; // 已探过。
      final device = await tryProbe(port);
      if (device != null) return device;
    }
    return null;
  }

  /// 单个 URL 的描述探测：GET → 解析 → 含 AVTransport 才算命中。
  Future<DlnaDevice?> _probeLocation(
      String location, String ip, int port, Duration timeout) async {
    try {
      final device = await _resolveDevice(DlnaDevice(
        usn: 'probe-$ip-$port',
        location: location,
        friendlyName: ip,
      )).then<DlnaDevice?>((v) => v).timeout(
            timeout,
            onTimeout: () => null,
          );
      // 解析失败 / 非 AVTransport 设备（isCastable=false）视为未命中。
      return device != null && device.isCastable ? device : null;
    } catch (_) {
      return null;
    }
  }

  /// TCP 扫描 UPnP 动态端口段（49152-65535、1024-5000），返回开放端口。
  Future<List<int>> _scanOpenPorts(String ip) async {
    final open = <int>[];
    final ports = <int>[
      for (var p = 49152; p <= 65535; p++) p,
      for (var p = 1024; p <= 5000; p++) p,
    ];
    const connectTimeout = Duration(milliseconds: 400);
    const batchSize = 2000;
    for (var i = 0; i < ports.length; i += batchSize) {
      final batch = ports.sublist(
          i, (i + batchSize) > ports.length ? ports.length : i + batchSize);
      await Future.wait(batch.map((port) async {
        try {
          final socket =
              await Socket.connect(ip, port, timeout: connectTimeout);
          socket.destroy();
          open.add(port);
        } catch (_) {
          // 关闭 / 超时。
        }
      }));
    }
    open.sort();
    AppLogger.instance.debug('dlna', '深度扫描 ${open.length} 个开放端口');
    return open;
  }

  /// 并发补全设备描述（限并发 6），过滤不可投屏项并按名称排序。
  /// 同一物理设备可能经多种 ST 被发现（USN 不同但 LOCATION 相同），
  /// 解析后按 LOCATION 去重。
  Future<List<DlnaDevice>> _resolveAll(List<DlnaDevice> entries) async {
    final resolved = <DlnaDevice>[];
    final seen = <String>{};
    for (var i = 0; i < entries.length; i += 6) {
      final batch = entries.sublist(
          i, (i + 6) > entries.length ? entries.length : i + 6);
      for (final device in await Future.wait(batch.map(_resolveDevice))) {
        if (!device.isCastable) continue;
        if (!seen.add(device.location)) continue; // 同 LOCATION 已收录。
        resolved.add(device);
      }
    }
    resolved.sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
    return resolved;
  }

  /// 把媒体 URL 推送到设备（SetAVTransportURI + Play）。
  ///
  /// 成功后记录为当前设备；任一步失败抛异常并保持设备为空。
  ///
  /// SOAP 参数构造注意（实测 TCL/BDLE 固件会校验）：
  /// - DIDL-Lite 元数据必须整体转义后作为 `CurrentURIMetaData` 的
  ///   **唯一文本**嵌入，不能再包一层同名标签，否则电视返回
  ///   UPnPError 501 "XML error"；
  /// - 报文必须按 UTF-8 编码发送，`codeUnits` 会把中文标题截断成
  ///   非法字节导致同样的 XML 错误。
  Future<void> cast(DlnaDevice device, String uri, {String? title}) async {
    final hasTitle = title != null && title.isNotEmpty;
    final didl = '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
        '<item id="0" restricted="1">'
        '<dc:title>${_escapeXml(title ?? '')}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '</item></DIDL-Lite>';
    await _soapAction(
      device,
      'AVTransport',
      'SetAVTransportURI',
      arguments: {
        'InstanceID': '0',
        'CurrentURI': _escapeXml(uri),
        if (hasTitle) 'CurrentURIMetaData': _escapeXml(didl),
      },
    );
    await _soapAction(device, 'AVTransport', 'Play',
        arguments: {'InstanceID': '0', 'Speed': '1'});
    _currentDevice = device;
  }

  /// 在当前设备上播放（推送后暂停过的恢复）。
  Future<void> play() async {
    final device = _currentDevice;
    if (device == null) throw StateError('尚未投屏到任何设备');
    await _soapAction(device, 'AVTransport', 'Play',
        arguments: {'InstanceID': '0', 'Speed': '1'});
  }

  Future<void> pause() async {
    final device = _currentDevice;
    if (device == null) throw StateError('尚未投屏到任何设备');
    await _soapAction(device, 'AVTransport', 'Pause',
        arguments: {'InstanceID': '0'});
  }

  /// 停止投屏播放（不断开设备记录，可再次 Play）。
  Future<void> stop() async {
    final device = _currentDevice;
    if (device == null) return;
    await _soapAction(device, 'AVTransport', 'Stop',
        arguments: {'InstanceID': '0'});
  }

  /// 清除当前设备记录（断开投屏）。
  void disconnect() {
    if (_currentDevice != null) {
      // 尽力通知设备停止；失败不影响本地状态清理。
      stop().catchError((_) {});
    }
    _currentDevice = null;
  }

  /// 构造 M-SEARCH 报文（[RFC 1.1](https://tools.ietf.org) SSDP 标准）。
  Uint8List _buildMSearch(String st) {
    final message = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $st\r\n'
        '\r\n';
    return Uint8List.fromList(message.codeUnits);
  }

  /// 解析 SSDP 报文。兼容两类来源：
  /// 1. M-SEARCH 的单播响应 `HTTP/1.1 200 ...`；
  /// 2. 设备主动广播 `NOTIFY * HTTP/1.1`（NTS: ssdp:alive）——
  ///    部分电视不响应 M-SEARCH，只能靠监听 NOTIFY 拿到 LOCATION。
  /// 非 200 / 非 alive 或缺 LOCATION·USN 返回 null。
  DlnaDevice? _parseSsdpPacket(Datagram packet) {
    final text = String.fromCharCodes(packet.data);
    final isSearchResponse = text.startsWith('HTTP/1.1 200');
    final isAliveNotify = text.startsWith('NOTIFY') &&
        (_headerValue(text, 'NTS') ?? '').contains('ssdp:alive');
    if (!isSearchResponse && !isAliveNotify) return null;
    final location =
        _headerValue(text, 'LOCATION') ?? _headerValue(text, 'location');
    final usn = _headerValue(text, 'USN') ?? _headerValue(text, 'usn');
    if (location == null || usn == null) return null;
    return DlnaDevice(
      usn: usn,
      location: location,
      friendlyName: usn, // 占位，待设备描述解析后覆盖。
    );
  }

  String? _headerValue(String raw, String name) {
    for (final line in raw.split('\r\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toUpperCase() == name.toUpperCase()) {
        return line.substring(idx + 1).trim();
      }
    }
    return null;
  }

  /// 拉取设备描述 XML，补全 friendlyName 与 AVTransport controlURL。
  Future<DlnaDevice> _resolveDevice(DlnaDevice device) async {
    try {
      final request =
          await _http.getUrl(Uri.parse(device.location)).timeout(
                const Duration(seconds: 6),
              );
      request.headers.persistentConnection = false;
      final response = await request.close().timeout(
            const Duration(seconds: 6),
          );
      final body = await response.transform(const Utf8BytesToStringFix())
          .join();
      final doc = XmlDocument.parse(body);
      final name = doc
          .findAllElements('friendlyName')
          .map((e) => e.innerText.trim())
          .firstWhere((_) => true, orElse: () => device.friendlyName);

      // UPnP 1.0 规范：声明 URLBase 时，相对 controlURL 以它为基准；
      // 未声明则回落到设备描述 LOCATION。
      final urlBaseRaw = doc
          .findAllElements('URLBase')
          .map((e) => e.innerText.trim())
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      final baseUrl = urlBaseRaw.isNotEmpty
          ? Uri.parse(urlBaseRaw)
          : Uri.parse(device.location);

      // AVTransport 服务 controlURL（相对路径时基于 baseUrl 拼 URL）。
      String? controlUrl;
      for (final service in doc.findAllElements('service')) {
        final serviceType =
            service.findElements('serviceType').map((e) => e.innerText).join();
        if (!serviceType.contains('AVTransport')) continue;
        final raw = service
            .findElements('controlURL')
            .map((e) => e.innerText.trim())
            .firstWhere((_) => true, orElse: () => '');
        if (raw.isEmpty) continue;
        controlUrl = _resolveUrl(baseUrl, raw).toString();
        break;
      }
      return DlnaDevice(
        usn: device.usn,
        location: device.location,
        friendlyName: name.isEmpty ? device.host : name,
        avTransportControlUrl: controlUrl,
      );
    } catch (e) {
      AppLogger.instance.warning('dlna', '解析设备描述失败：${device.location}', error: e);
      return device; // 保留原样（不可投屏，会被 removeWhere 过滤）。
    }
  }

  /// 发送 SOAP Action。
  ///
  /// [arguments] 为参数名 → 已转义值 的映射，按序还原为
  /// `<名>值</名>` 序列。
  Future<void> _soapAction(
    DlnaDevice device,
    String service,
    String action, {
    required Map<String, String> arguments,
  }) async {
    final controlUrl = device.avTransportControlUrl;
    if (controlUrl == null || controlUrl.isEmpty) {
      throw StateError('设备 ${device.friendlyName} 不支持 AVTransport');
    }
    final params = arguments.entries
        .map((e) => '<${e.key}>${e.value}</${e.key}>')
        .join();

    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="urn:schemas-upnp-org:service:$service:1">'
        '$params'
        '</u:$action>'
        '</s:Body>'
        '</s:Envelope>';

    try {
      final request = await _http.postUrl(Uri.parse(controlUrl)).timeout(
            const Duration(seconds: 8),
          );
      request.headers.set('SOAPACTION',
          '"urn:schemas-upnp-org:service:$service:1#$action"');
      request.headers.contentType = ContentType(
        'text',
        'xml',
        charset: 'utf-8',
      );
      // 电视的 HTTP 服务多为 HTTP/1.0 风格，会静默断开空闲连接；
      // 禁用 keep-alive 逐请求新建连接，避免 Dart 复用已死连接报
      // "Connection closed before full header was received"。
      request.headers.persistentConnection = false;
      // 标题等含中文：必须按 UTF-8 编码，codeUnits 会截断多字节字符。
      request.add(utf8.encode(body));
      final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
      final responseBody = await response
          .transform(utf8.decoder)
          .timeout(const Duration(seconds: 8))
          .join();
      // UPnP 规范：500 = ActionFailed（常见于设备不支持该动作），同样视为失败。
      if (response.statusCode >= 400) {
        throw HttpException(
          'SOAP $action 失败 (HTTP ${response.statusCode}'
          '${_upnpErrorHint(responseBody)})',
          uri: Uri.parse(controlUrl),
        );
      }
    } on SocketException catch (e) {
      throw HttpException('设备连接失败：$e');
    }
  }

  /// 从 UPnP 错误响应里提取 errorCode / errorDescription 便于定位。
  String _upnpErrorHint(String responseBody) {
    if (responseBody.isEmpty || !responseBody.contains('UPnPError')) return '';
    final code = RegExp(r'<errorCode>(\d+)</errorCode>').firstMatch(responseBody)?[1];
    final desc =
        RegExp(r'<errorDescription>([^<]+)</errorDescription>')
            .firstMatch(responseBody)?[1];
    if (code == null && desc == null) return '';
    return ', UPnP ${code ?? '?'} ${desc ?? ''}'.trimRight();
  }

  String _escapeXml(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// UPnP 相对地址解析。
  ///
  /// 部分电视（如 TCL/BDLE 固件）的 controlURL 首段含冒号
  /// （`_urn:schemas-upnp-org:service:AVTransport_control`），Dart 的
  /// [Uri.resolve] 会把 `_urn:` 误判为「scheme 必须以字母开头」直接抛
  /// FormatException；按 RFC 3986 对此类相对引用补 `./` 前缀后即可
  /// 正确解析为普通路径。
  Uri _resolveUrl(Uri base, String reference) {
    try {
      return base.resolve(reference);
    } on FormatException {
      return base.resolve('./$reference');
    }
  }

  Future<void> dispose() async {
    _http.close(force: true);
  }
}

/// 设备描述 XML 可能是 GBK 等非 UTF-8 编码；响应头里 charset 缺失时
/// HttpClient 默认按 latin1 解。这里只处理 UTF-8 BOM，其余按 latin1
/// 兜底解码（不抛错即可；主流电视均以 UTF-8 输出）。
class Utf8BytesToStringFix
    extends StreamTransformerBase<List<int>, String> {
  const Utf8BytesToStringFix();

  @override
  Stream<String> bind(Stream<List<int>> stream) async* {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    final hasBom = bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF;
    yield String.fromCharCodes(bytes, hasBom ? 3 : 0);
  }
}
