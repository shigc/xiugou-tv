// 诊断 v3：确认 media_kit 的 libmpv 是否还有任何 muxer（录制封装能力）。
import 'dart:io';
import 'package:media_kit/media_kit.dart';

Future<void> main(List<String> args) async {
  final media = args.first;
  final dll =
      File('build/windows/x64/runner/Release/libmpv-2.dll').absolute.path;
  MediaKit.ensureInitialized(libmpv: dll);
  final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.info));
  player.stream.log.listen((l) {
    if (l.level == 'error' || l.level == 'fatal') {
      stdout.writeln('  [mpv ${l.level}] ${l.prefix}: ${l.text}');
    }
  });
  final native = player.platform as NativePlayer;

  for (final ext in const ['ts', 'mp4', 'mkv', 'avi', 'webm', 'ogg', 'wav']) {
    final out = '${Directory.systemTemp.path}\\rec_test.$ext';
    if (File(out).existsSync()) File(out).deleteSync();
    await native.setProperty('stream-record', out);
    await player.open(Media(media), play: true);
    await Future<void>.delayed(const Duration(seconds: 2));
    final f = File(out);
    final ok = f.existsSync() && f.lengthSync() > 0;
    stdout.writeln('.$ext -> ${ok ? "OK size=${f.lengthSync()}" : "无文件"}');
    await player.stop();
    await native.setProperty('stream-record', '');
    if (f.existsSync()) f.deleteSync();
  }
  await player.dispose();
}
