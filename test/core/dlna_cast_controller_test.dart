import 'package:flutter_test/flutter_test.dart';
import 'package:xiugou_tv/core/dlna/dlna_cast_controller.dart';
import 'package:xiugou_tv/core/dlna/dlna_device.dart';
import 'package:xiugou_tv/core/dlna/dlna_service.dart';

class _FakeDlnaService extends DlnaService {
  final List<String> calls = <String>[];
  String? lastUri;
  String? lastTitle;

  @override
  Future<void> cast(DlnaDevice device, String uri, {String? title}) async {
    calls.add('cast');
    lastUri = uri;
    lastTitle = title;
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  void disconnect() => calls.add('disconnect');

  @override
  Future<void> dispose() async {}
}

void main() {
  late _FakeDlnaService service;
  late DlnaCastController controller;

  const device = DlnaDevice(
    usn: 'uuid:living-room-tv',
    location: 'http://192.168.1.9:49152/description.xml',
    friendlyName: '客厅电视',
    avTransportControlUrl: 'http://192.168.1.9:49152/AVTransport',
  );

  setUp(() {
    service = _FakeDlnaService();
    controller = DlnaCastController(service: service);
  });

  tearDown(() => controller.dispose());

  test('初始状态为空闲', () {
    expect(controller.state.value.connected, isFalse);
    expect(controller.state.value.device, isNull);
    expect(controller.state.value.paused, isFalse);
  });

  test('投屏成功后记录设备、地址与标题', () async {
    await controller.cast(device, 'http://media/1.m3u8', title: '第 1 集');

    expect(service.calls, ['cast']);
    expect(service.lastUri, 'http://media/1.m3u8');
    expect(service.lastTitle, '第 1 集');
    expect(controller.state.value.device, device);
    expect(controller.state.value.url, 'http://media/1.m3u8');
    expect(controller.state.value.connected, isTrue);
  });

  test('暂停/继续/停止更新状态并转发到服务', () async {
    await controller.cast(device, 'http://media/1.m3u8');

    await controller.pause();
    expect(controller.state.value.paused, isTrue);

    await controller.play();
    expect(controller.state.value.paused, isFalse);

    await controller.stop();
    expect(controller.state.value.paused, isTrue);
    expect(service.calls, ['cast', 'pause', 'play', 'stop']);
  });

  test('换集重推覆盖地址并保留设备', () async {
    await controller.cast(device, 'http://media/1.m3u8', title: '第 1 集');
    await controller.cast(device, 'http://media/2.m3u8', title: '第 2 集');

    expect(controller.state.value.device, device);
    expect(controller.state.value.url, 'http://media/2.m3u8');
    expect(controller.state.value.title, '第 2 集');
  });

  test('断开通知服务停机并清空会话', () async {
    await controller.cast(device, 'http://media/1.m3u8');
    controller.disconnect();

    expect(service.calls, ['cast', 'disconnect']);
    expect(controller.state.value.connected, isFalse);
    expect(controller.state.value.url, isNull);
  });

  test('未投屏时的控制调用不会落到服务', () async {
    await controller.play();
    await controller.pause();
    await controller.stop();
    controller.disconnect();

    expect(service.calls, isEmpty);
  });

  test('会话变化会通知订阅者', () async {
    var notified = 0;
    controller.state.addListener(() => notified++);

    await controller.cast(device, 'http://media/1.m3u8');
    await controller.pause();
    controller.disconnect();

    expect(notified, 3);
  });
}
