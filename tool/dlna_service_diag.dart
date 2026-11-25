// 临时诊断脚本：直接调用应用内 DlnaService 真实代码做按 IP 探测。
// 运行: dart run tool/dlna_service_diag.dart [ip]
import 'dart:io';

import 'package:xiugou_tv/core/dlna/dlna_service.dart';

Future<void> main(List<String> args) async {
  final ip = args.isNotEmpty ? args[0] : '192.168.6.155';
  final service = DlnaService();

  stdout.writeln('=== probeDevice($ip) ===');
  final watch = Stopwatch()..start();
  try {
    final device = await service.probeDevice(ip).timeout(
          const Duration(seconds: 90),
        );
    stdout.writeln('elapsed: ${watch.elapsedMilliseconds} ms');
    if (device == null) {
      stdout.writeln('RESULT: null（未命中）');
    } else {
      stdout.writeln('RESULT: ${device.friendlyName}');
      stdout.writeln('  location: ${device.location}');
      stdout.writeln('  control:  ${device.avTransportControlUrl}');
      stdout.writeln('  castable: ${device.isCastable}');
    }
  } catch (e, st) {
    stdout.writeln('probeDevice threw: $e');
    stdout.writeln(st.toString().split('\n').take(5).join('\n'));
  }

  stdout.writeln('=== discover(4s) ===');
  try {
    final devices = await DlnaService()
        .discover()
        .timeout(const Duration(seconds: 60));
    stdout.writeln('discovered ${devices.length}:');
    for (final d in devices) {
      stdout.writeln('  ${d.friendlyName} @ ${d.location}');
    }
  } catch (e) {
    stdout.writeln('discover threw: $e');
  }
  service.dispose();
  exit(0);
}
