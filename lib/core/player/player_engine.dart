import 'dart:async';
import '../cache/video_cache_store.dart';
import '../settings/models/video_cache_preferences.dart';
import 'models/player_settings.dart';
import 'models/player_state.dart';
import 'models/track_info.dart';

/// 播放引擎顶层抽象接口
abstract class PlayerEngine {
  /// 初始化播放引擎
  Future<void> initialize();

  /// 开始播放指定媒体流
  Future<void> play(MediaPlaySpec spec);

  /// 暂停播放
  Future<void> pause();

  /// 恢复播放
  Future<void> resume();

  /// 停止播放并重置状态
  Future<void> stop();

  /// 跳转至指定播放进度
  Future<void> seek(Duration position);

  /// 设置音量大小 (0.0 ~ 100.0)
  Future<void> setVolume(double volume);

  /// 设置播放倍速 (如 0.5, 1.0, 1.25, 1.5, 2.0)
  Future<void> setRate(double rate);

  /// 配置硬件加速模式（取值见 [PlayerSettings.hwdecOptions]，旧值 'auto' 视为自动）
  Future<void> setHardwareDecoding(String mode);

  /// 应用播放器与解码首选项。
  ///
  /// 可在 [initialize] 之前调用（暂存，初始化时生效）；初始化后调用时，
  /// 解码 / 声道 / 音画同步 / 色彩 / 缓冲发起即时应用，默认音量与倍速仅在初始化时应用。
  /// 写入成功不等于设备正在使用硬解；具体确认与失败信息由引擎的应用状态提供。
  Future<void> applyPlaybackSettings(PlayerSettings settings);

  /// 切换音轨
  Future<void> selectAudioTrack(TrackInfo track);

  /// 切换字幕轨
  Future<void> selectSubtitleTrack(TrackInfo track);

  /// 应用视频本地缓存偏好（开关 / 目录 / 容量上限）。
  ///
  /// [defaultRoot] 为偏好未指定目录时的默认缓存根（应用数据目录下的 video_cache）。
  Future<void> applyCachePreferences(VideoCachePreferences preferences,
      {required String defaultRoot});

  // --- 录制（把当前播放原流 dump 到本地文件） ---

  /// 是否正在录制当前播放。
  bool get isRecording;

  /// 录制状态变更流（true=开始，false=结束）。
  Stream<bool> get recordingStream;

  /// 开始录制当前播放到 [path]（原样 dump 解复用流，不重编码）。
  ///
  /// [from] 为当前播放位置：HLS 点播从该时刻对应的分片开始下载
  /// （跳过片头贴片广告与已看部分），直播 / 直链源忽略。
  ///
  /// 换源 / 停止播放会自动终止录制；重复调用抛 [StateError]。
  Future<void> startRecording(String path, {Duration? from});

  /// 停止录制，返回实际写出的文件路径；未在录制时返回 null。
  Future<String?> stopRecording();

  /// 释放播放器引擎资源
  Future<void> dispose();

  // --- 当前状态快照 ---
  PlaybackStatus get status;
  Duration get position;
  Duration get duration;
  Duration get buffer;
  double get volume;
  double get rate;
  VideoDimensions get dimensions;
  String? get currentError;
  MediaPlaySpec? get currentSpec;

  /// 本地缓存下载器（独立于播放状态：暂停 / 拖动不影响下载）
  VideoCacheStore get cacheStore;

  /// 当前缓存进度快照
  VideoCacheProgress get cacheProgress;

  List<TrackInfo> get audioTracks;
  List<TrackInfo> get subtitleTracks;

  // --- 响应式状态流 ---
  Stream<PlaybackStatus> get statusStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<double> get volumeStream;
  Stream<double> get rateStream;
  Stream<VideoDimensions> get dimensionsStream;
  Stream<String?> get errorStream;
  Stream<VideoCacheProgress> get cacheProgressStream;
  Stream<List<TrackInfo>> get audioTracksStream;
  Stream<List<TrackInfo>> get subtitleTracksStream;
}
