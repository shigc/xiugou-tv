import 'dart:async';
import 'package:flutter/foundation.dart';

import 'dlna_device.dart';
import 'dlna_service.dart';

/// 一次 DLNA 投屏会话的不可变快照。
///
/// 播放器底栏的投屏按钮、投屏弹窗的「正在投屏」面板都订阅它，
/// 因此设备一旦在弹窗外（例如换集自动重推）变化，UI 会立即跟上。
@immutable
class DlnaCastState {
  const DlnaCastState({
    this.device,
    this.url,
    this.title,
    this.paused = false,
  });

  /// 当前被投屏控制中的设备；为 null 表示未投屏。
  final DlnaDevice? device;

  /// 已推送到电视的媒体地址（换集重推时用来比对）。
  final String? url;

  /// 已推送的标题。
  final String? title;

  /// 电视侧是否处于暂停状态（本地暂停由播放器自己管理）。
  final bool paused;

  bool get connected => device != null;

  DlnaCastState copyWith({
    DlnaDevice? device,
    String? url,
    String? title,
    bool? paused,
  }) =>
      DlnaCastState(
        device: device ?? this.device,
        url: url ?? this.url,
        title: title ?? this.title,
        paused: paused ?? this.paused,
      );
}

/// 应用级投屏会话控制器（全应用一份，弹窗关闭也不销毁）。
///
/// 封装 [DlnaService] 的生命周期与会话状态：
/// - 弹窗只借用 [service] 做设备发现，投屏结果写回 [state]；
/// - 换集时宿主比对 `state.url`，变化就重新 [cast] 同一设备；
/// - 退出播放时宿主调用 [disconnect]，电视停机并清除状态。
class DlnaCastController {
  DlnaCastController({DlnaService? service})
      : _service = service ?? DlnaService();

  final DlnaService _service;

  /// 供设备发现 / IP 探测复用同一个 HTTP 客户端。
  DlnaService get service => _service;

  final ValueNotifier<DlnaCastState> state =
      ValueNotifier<DlnaCastState>(const DlnaCastState());

  /// 推送媒体并立即播放；成功后记录为当前会话。
  Future<void> cast(DlnaDevice device, String uri, {String? title}) async {
    await _service.cast(device, uri, title: title);
    state.value = DlnaCastState(
      device: device,
      url: uri,
      title: title,
      paused: false,
    );
  }

  /// 在当前设备上继续播放。
  Future<void> play() async {
    if (!state.value.connected) return;
    await _service.play();
    state.value = state.value.copyWith(paused: false);
  }

  /// 在当前设备上暂停。
  Future<void> pause() async {
    if (!state.value.connected) return;
    await _service.pause();
    state.value = state.value.copyWith(paused: true);
  }

  /// 在当前设备上停止（保留设备记录，可再次 [play]）。
  Future<void> stop() async {
    if (!state.value.connected) return;
    await _service.stop();
    state.value = state.value.copyWith(paused: true);
  }

  /// 断开投屏：尽力让电视停机，然后清除本地会话状态。
  void disconnect() {
    if (!state.value.connected) return;
    _service.disconnect();
    state.value = const DlnaCastState();
  }

  void dispose() {
    if (state.value.connected) _service.disconnect();
    state.dispose();
    unawaited(_service.dispose());
  }
}
