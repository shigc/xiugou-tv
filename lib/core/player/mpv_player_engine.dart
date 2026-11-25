import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'decode_diagnostics.dart';
import 'embedded_playback.dart';
import 'live_stream_tuning.dart';
import 'local_subtitle_files.dart';
import '../cache/video_cache_store.dart';
import '../diagnostics/app_logger.dart';
import '../settings/models/video_cache_preferences.dart';
import 'media_recorder.dart';
import 'models/player_settings.dart';
import 'models/player_state.dart';
import 'models/track_info.dart';
import 'playback_diagnostics.dart';
import 'playback_error_gate.dart';
import 'playback_error_text.dart';
import 'playback_http_headers.dart';
import 'playback_url_validator.dart';
import 'player_engine.dart';
import 'player_track_capabilities.dart';
import 'player_settings_application.dart';
import 'mpv_settings_target.dart';
import 'seek_recovery_controller.dart';
import '../danmaku/danmaku_api.dart';

part 'mpv_embedded_routing.dart';

/// 基于 media_kit (libmpv) 的 Windows 平台硬件加速播放引擎实现
class MpvPlayerEngine
    implements
        PlayerEngine,
        VideoTrackCapable,
        SubtitleTrackCapable,
        SeekRecoveryCapable {
  MpvPlayerEngine();

  @visibleForTesting
  static const playerConfiguration = PlayerConfiguration(
    // Independent pitch control uses an audio-only scaletempo path which
    // media_kit warns can desynchronize video. Standard speed keeps A/V synced.
    pitch: false,
    // ASS 的排版和矢量绘图不能由 Flutter 的纯文字字幕层还原。
    libass: true,
    // 播放缓冲 16MB，1080p 约 6~10 秒余量，视码率而定。
    bufferSize: 16 * 1024 * 1024,
    logLevel: MPVLogLevel.warn,
    protocolWhitelist: mpvProtocolWhitelist,
  );

  /// Connects the real engine event handling to an injected media_kit adapter.
  @visibleForTesting
  MpvPlayerEngine.withPlayer(Player player) {
    _player = player;
    _nativeCreated = true;
    _initialization = Future<void>.value();
    _bindNativeStreams();
    unawaited(_observeNativeSeekCompletion());
  }

  late final Player _player;
  late final VideoController _videoController;

  final _embeddedTexture = ValueNotifier<EmbeddedPlaybackSession?>(null);
  _EmbeddedRoute? _route;
  Future<Duration?>? _embeddedClosing;
  Duration? _parkedPosition;
  bool _volumeNeedsSync = false;
  VideoDimensions _parkedDimensions = const VideoDimensions();

  ValueListenable<EmbeddedPlaybackSession?> get embeddedSession => _embeddedTexture;

  Future<bool> selectPlaybackBackend(NativePlaybackBackend? backend,
      {EmbeddedPlaybackChannel channel = const EmbeddedPlaybackChannel()}) =>
      _selectBackend(backend, channel);

  bool get _mpvOwnsPlayback => _route == null && _embeddedClosing == null;

  PlaybackStatus _status = PlaybackStatus.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  double _volume = 100.0;
  double _rate = 1.0;
  VideoDimensions _dimensions = const VideoDimensions();
  String? _currentError;
  MediaPlaySpec? _currentSpec;
  /// 已经为这次会话做过「同一地址自动重开」的 spec；同一会话只重试一次。
  MediaPlaySpec? _softRetrySpec;

  /// 正在回源诊断失败原因（避免重复拉取中转地址）。
  bool _diagnosing = false;
  List<TrackInfo> _audioTracks = [];
  List<TrackInfo> _subtitleTracks = [];
  int _subtitleRead = 0;
  int _subtitleChoice = 0;
  double _subtitleScale = 1;
  final _localSubtitles = LocalSubtitleFiles();
  String? _subtitleCodec;
  final _sourceSubtitleIds = <int, String>{};
  List<TrackInfo> _videoTracks = [];

  /// 本地缓存下载器：与播放状态无关，暂停 / 拖动不影响下载。
  @override
  final VideoCacheStore cacheStore = VideoCacheStore();
  String _cacheDefaultRoot = '';
  Timer? _cacheReanchorTimer;

  /// ④ 诊断闭环：mpv 最近日志环形缓冲（40 条），供错误面板展示与「复制诊断」。
  final RecentLogBuffer _recentLogs = RecentLogBuffer();

  final _statusController = StreamController<PlaybackStatus>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferController = StreamController<Duration>.broadcast();
  final _volumeController = StreamController<double>.broadcast();
  final _rateController = StreamController<double>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();
  final _errorController = StreamController<String?>.broadcast();
  final _audioTracksController = StreamController<List<TrackInfo>>.broadcast();
  final _subtitleTracksController =
      StreamController<List<TrackInfo>>.broadcast();
  final _videoTracksController = StreamController<List<TrackInfo>>.broadcast();

  // --- 录制（纯 Dart 源下载：media_kit 的 libmpv 精简构建无 muxer，
  //     mpv 自带录制不可用，见 MediaRecorder 文件头说明） ---
  bool _recording = false;
  String? _recordingPath;
  MediaRecorder? _recorder;

  /// 用户**主动**终止录制。用来区分「源断了」与「我自己停的」——
  /// 后者走 `stopRecording()` 的下发路径，不应额外提示「录制已结束」。
  bool _recordingStopRequested = false;

  /// 「从当前进度开始录」的尾部豁免区间：剩余不足这个时长时改为从头录。
  /// 直播（时长恒为 0）与直链不受影响——它们本来就不按偏移裁剪。
  static const Duration _recordTailGuard = Duration(seconds: 60);

  final _recordingController = StreamController<bool>.broadcast();

  /// 录制**意外**结束（源断开 / 直播断流）时的面向用户的原因。
  /// 用户主动点停止、换源导致的中止都不会发。
  final _recordingEndedController = StreamController<String>.broadcast();

  /// 录制任务自然结束时的播报（点播清单下完 / 直链读到流尾）。
  /// 与 [recordingEndedStream] 分开：一个是「录完了」，一个是「断了」。
  final _recordingFinishedController = StreamController<String>.broadcast();

  final List<StreamSubscription> _subscriptions = [];

  /// 直播断流重连：退避计数 + 待执行的重开定时器；[_sessionEpoch] 用于作废
  /// 换台 / 停止之后才到期的旧重连。
  final LiveReconnectPolicy _liveReconnect = LiveReconnectPolicy();
  Timer? _reconnectTimer;
  int _sessionEpoch = 0;

  /// §56 错误致命性判定：mpv 的 error 级日志先待定，到期看位置有没有推进再决定。
  final PlaybackErrorGate _errorGate = PlaybackErrorGate();
  Timer? _errorConfirmTimer;

  final settingsApplication = PlayerSettingsApplication();
  Future<void>? _initialization;
  bool _nativeCreated = false;
  bool _disposed = false;
  bool _pauseIntent = false;
  bool _externalPlaybackPaused = false;
  bool _openingMedia = false;
  bool _awaitingOpenPosition = false;
  bool _sawOpenPosition = false;
  bool _hasOpenLiveFrame = false;
  bool _nativeBuffering = false;
  int _openEpoch = 0;
  String? _openedMediaUri;
  int? _seekEvidenceGeneration;
  final _seekRecovery = SeekRecoveryController();

  @override
  ValueListenable<SeekRecoveryState> get seekRecovery => _seekRecovery;

  /// User pause intent survives buffering and source replacement.
  bool get isPlaybackPaused => _pauseIntent;

  bool get _acceptMediaEvents =>
      !_disposed &&
      _mpvOwnsPlayback &&
      _currentSpec != null &&
      !_openingMedia &&
      !_externalPlaybackPaused;

  bool get _hasPendingSeek =>
      _seekRecovery.value.phase != SeekRecoveryPhase.idle;

  bool get _awaitingPausedLiveOpen =>
      _awaitingOpenPosition && _pauseIntent && _currentSpec?.isLive == true;

  // A paused live stream may never advance time or expose a positive duration.
  // Only native evidence for the opened path may certify its decoded frame.
  void _readPendingLiveEvidence() {
    final uri = _openedMediaUri;
    if (!_acceptMediaEvents || !_awaitingPausedLiveOpen || uri == null) return;
    unawaited(_readOpenedMediaEvidence(_sessionEpoch, _openEpoch, uri));
  }

  bool _isCurrentSession(int epoch) => !_disposed && epoch == _sessionEpoch;

  PlayerSettings get playbackSettings => settingsApplication.settings;
  Player get nativePlayer => _player;
  VideoController get videoController => _videoController;

  /// 当前是否关闭视频输出（mpv `vid=no`）；引擎未初始化或回读失败时为 false。
  bool get isVideoDisabled {
    if (!_nativeCreated || !_mpvOwnsPlayback) return false;
    try {
      return _player.state.track.video.id == 'no';
    } catch (_) {
      return false;
    }
  }

  /// 读取引擎（mpv）版本字符串，用于关于页的运行环境展示。
  ///
  /// 只读诊断信息；引擎未初始化或回读失败时返回 null（调用方显示不可用，不猜值）。
  Future<String?> readEngineVersion() async {
    if (!_mpvOwnsPlayback) return null;
    final epoch = _sessionEpoch;
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        final version = await platform.getProperty('mpv-version');
        return _isCurrentSession(epoch) ? version : null;
      }
    } catch (_) {
      // 引擎未初始化（late 字段未赋值）或原生回读失败：返回 null
    }
    return null;
  }

  @override
  Future<void> initialize() {
    if (_disposed) return Future<void>.error(StateError('播放器已关闭'));
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      MediaKit.ensureInitialized();
      _player = Player(configuration: playerConfiguration);
      _nativeCreated = true;
      _videoController = VideoController(_player);
      _bindNativeStreams();
      await _observeNativeSeekCompletion();
      await settingsApplication.attach(MpvSettingsTarget(_player));
      AppLogger.instance.info('player', 'mpv 引擎初始化完成');
      // ④：显式钉住网络连接超时（mpv 默认即 60s）——直播源失联时保证约 60s
      // 内进入错误态并可诊断，而不是无限等待；个别发行版 / 配置可能覆写该值。
      try {
        final platform = _player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty('network-timeout', '60');
          // 缓存相关 mpv 属性：`cache-on-disk=yes` 会把网络缓存落到磁盘，
          // 分片源在机械盘 / 高码率下表现为周期性卡顿；改成纯内存缓存并加大预读。
          await _applyCacheTweaks();
        }
      } catch (_) {
        // 属性不可用时不影响播放主链路。
      }
    } catch (error, stack) {
      settingsApplication.initializationFailed();
      AppLogger.instance.error('player', 'mpv 引擎初始化失败',
          error: error, stack: stack);
      rethrow;
    }
  }

  Future<void> _applyCacheTweaks() async {
    try {
      final platform = _player.platform;
      if (platform is! NativePlayer) return;
      for (final entry in const <String, String>{
        'cache-on-disk': 'no',
        'demuxer-readahead-secs': '30',
        'demuxer-max-bytes': '64MiB',
        'demuxer-max-back-bytes': '32MiB',
      }.entries) {
        await platform.setProperty(entry.key, entry.value);
      }
    } catch (_) {
      // 属性不可用时不影响播放主链路。
    }
  }

  /// §50 读取实际解码状态（hwdec-current / 编码 / 分辨率）。
  ///
  /// 只读诊断；引擎未初始化或回读失败时返回 null（界面不显示该行，不猜值）。
  Future<DecodeDiagnostics?> readDecodeDiagnostics() async {
    if (!_mpvOwnsPlayback) return null;
    final epoch = _sessionEpoch;
    try {
      final platform = _player.platform;
      if (platform is! NativePlayer) return null;
      final diagnostics = DecodeDiagnostics(
        requested: playbackSettings.hwdec,
        current: (await platform.getProperty('hwdec-current')).trim(),
        codec: (await platform.getProperty('video-codec')).trim(),
        width: int.tryParse(await platform.getProperty('width')) ?? 0,
        height: int.tryParse(await platform.getProperty('height')) ?? 0,
      );
      return _isCurrentSession(epoch) ? diagnostics : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> applyPlaybackSettings(PlayerSettings settings) =>
      settingsApplication.update(settings);

  void _bindNativeStreams() {
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (!_acceptMediaEvents || _awaitingOpenPosition) return;
        if (_status != PlaybackStatus.error && !_nativeBuffering) {
          _updateStatus(
              playing ? PlaybackStatus.playing : PlaybackStatus.paused);
        }
      }),
    );

    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        if (!_acceptMediaEvents) return;
        _nativeBuffering = buffering;
        if (buffering && _status != PlaybackStatus.error) {
          _updateStatus(PlaybackStatus.buffering);
        } else if (!buffering &&
            !_awaitingOpenPosition &&
            _status == PlaybackStatus.buffering) {
          _updateStatus(_pauseIntent
              ? PlaybackStatus.paused
              : PlaybackStatus.playing);
        }
        if (!buffering && _pauseIntent) {
          unawaited(_readSettledSeekPosition());
          _readPendingLiveEvidence();
        }
      }),
    );

    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (!_acceptMediaEvents || _hasPendingSeek) return;
        if (completed) {
          // 直播没有「播完」：EOF 即断流，优先自动重连。
          if (_scheduleLiveReconnect()) return;
          _updateStatus(PlaybackStatus.completed);
        }
      }),
    );

    _subscriptions.add(
      _player.stream.position.listen(_publishPosition),
    );

    _subscriptions.add(
      _player.stream.duration.listen(_publishDuration),
    );

    _subscriptions.add(
      _player.stream.buffer.listen((buf) {
        if (!_acceptMediaEvents) return;
        _buffer = buf;
        _bufferController.add(buf);
      }),
    );

    _subscriptions.add(
      _player.stream.volume.listen((vol) {
        if (_disposed || !_mpvOwnsPlayback) return;
        _volume = vol;
        _volumeController.add(vol);
      }),
    );

    _subscriptions.add(
      _player.stream.rate.listen((r) {
        if (_disposed || !_mpvOwnsPlayback) return;
        _rate = r;
        _rateController.add(r);
      }),
    );

    _subscriptions.add(
      _player.stream.width.listen((w) {
        if (!_acceptMediaEvents) return;
        if (_awaitingPausedLiveOpen) {
          // Player.state may still contain the other dimension of the old file.
          _readPendingLiveEvidence();
          return;
        }
        _dimensions =
            VideoDimensions(width: w ?? 0, height: _player.state.height ?? 0);
        _dimensionsController.add(_dimensions);
      }),
    );

    _subscriptions.add(
      _player.stream.height.listen((h) {
        if (!_acceptMediaEvents) return;
        if (_awaitingPausedLiveOpen) {
          // Player.state may still contain the other dimension of the old file.
          _readPendingLiveEvidence();
          return;
        }
        _dimensions =
            VideoDimensions(width: _player.state.width ?? 0, height: h ?? 0);
        _dimensionsController.add(_dimensions);
      }),
    );

    _subscriptions.add(
      _player.stream.tracks.listen((tracks) {
        if (!_acceptMediaEvents) return;
        _audioTracks = tracks.audio
            .map((t) => TrackInfo(
                  id: t.id,
                  type: TrackType.audio,
                  title: t.title,
                  language: t.language,
                  isSelected: t.id == _player.state.track.audio.id,
                ))
            .toList();
        _audioTracksController.add(_audioTracks);

        unawaited(_refreshSubtitleTracks());

        _videoTracks = tracks.video
            .where((t) => t.id != 'auto' && t.id != 'no')
            .map((t) => TrackInfo(
                  id: t.id,
                  type: TrackType.video,
                  title: t.title,
                  language: t.language,
                  isSelected: t.id == _player.state.track.video.id,
                ))
            .toList();
        _videoTracksController.add(_videoTracks);
      }),
    );

    // 轨道列表与「当前选中」是两条独立的流。`sub-add` / 切轨时 mpv 先发
    // track-list、后发 current-tracks，只在上面那个回调里读 `state.track`
    // 拿到的是旧值——外挂字幕已经在画面上渲染，菜单里勾着的却还是「关闭字幕」。
    _subscriptions.add(
      _player.stream.track.listen((_) {
        _resyncTrackSelection();
      }),
    );

    _subscriptions.add(
      _player.stream.track.listen((track) {
        if (!_acceptMediaEvents) return;
        _audioTracks = markTrackSelection(_audioTracks, track.audio.id);
        _audioTracksController.add(_audioTracks);
        unawaited(_refreshSubtitleTracks());
      }),
    );

    _subscriptions.add(
      _player.stream.log.listen((log) {
        if (_disposed || !_mpvOwnsPlayback) return;
        _recentLogs.add('[${log.level}] ${log.text}');
      }),
    );

    _subscriptions.add(
      _player.stream.error.listen((err) {
        if (_disposed ||
            !_mpvOwnsPlayback ||
            _externalPlaybackPaused ||
            _currentSpec == null ||
            err.isEmpty) {
          return;
        }
        if (_hasPendingSeek) {
          _recentLogs.add('[seek-error] $err');
          return;
        }
        // 解码器/缓存降级：mpv 会自动回退继续播放，不能当播放失败（否则「报错但视频正常」）。
        if (isBenignPlaybackError(err)) {
          _recentLogs.add('[benign] 解码/缓存降级，mpv 自动回退，不视为播放失败：$err');
          return;
        }
        _recentLogs.add('[error] $err');
        if (_status == PlaybackStatus.error || _reconnectTimer != null) return;
        final wait = _errorGate.onError(err,
            position: _position,
            mediaOpened: _duration > Duration.zero || _dimensions.width > 0);
        if (wait == null) return;
        final epoch = _sessionEpoch;
        _errorConfirmTimer?.cancel();
        _errorConfirmTimer = Timer(wait, () {
          _errorConfirmTimer = null;
          if (_disposed || epoch != _sessionEpoch) return;
          final fatal = _errorGate.resolve(position: _position);
          if (fatal == null) {
            _recentLogs.add('[nonfatal] 报错后播放仍在推进，按可恢复处理：$err');
            return;
          }
          _commitError(fatal);
        });
      }),
    );
  }

  void _publishPosition(Duration position) {
    if (!_acceptMediaEvents) return;
    _position = position;
    _sawOpenPosition = true;
    _confirmOpenPosition();
    _readPendingLiveEvidence();
    final generation = _seekEvidenceGeneration;
    if (generation != null) {
      if (_pauseIntent && _player.platform is NativePlayer) {
        // A paused time-pos preview is not proof that native seeking settled.
        unawaited(_readSettledSeekPosition());
      } else {
        _seekRecovery.onPosition(position,
            generation: generation,
            isPaused: _pauseIntent,
            isBuffering: _nativeBuffering);
      }
    }
    _liveReconnect.onPosition(position);
    _errorGate.onPosition(position);
    _positionController.add(position);
    if (_status == PlaybackStatus.error && _errorGate.recovered(position)) {
      _recentLogs.add('[recover] 错误后播放继续推进，已解除错误态');
      _currentError = null;
      _errorController.add(null);
      _updateStatus(_pauseIntent ? PlaybackStatus.paused : PlaybackStatus.playing);
    }
  }

  void _publishDuration(Duration duration) {
    if (!_acceptMediaEvents) return;
    _duration = duration;
    _durationController.add(duration);
    _confirmOpenPosition();
  }

  void _confirmOpenPosition() {
    final hasMedia = _duration > Duration.zero ||
        (_awaitingPausedLiveOpen
            ? _hasOpenLiveFrame
            : _position > Duration.zero);
    if (!_awaitingOpenPosition || !_sawOpenPosition || !hasMedia) return;
    _awaitingOpenPosition = false;
    if (!_nativeBuffering && _status != PlaybackStatus.error) {
      _updateStatus(_pauseIntent ? PlaybackStatus.paused : PlaybackStatus.playing);
    }
  }

  /// 确认致命错误：直播先走断流重连，其余锁存为错误态（错误面板 / 自动换线据此工作）。
  void _commitError(String err) {
    if (_disposed || !_mpvOwnsPlayback || _externalPlaybackPaused || _hasPendingSeek) return;
    if (_scheduleLiveReconnect()) return;
    // 网络瞬断（CDN 掐 TCP 连接）先静默自动重连；重试窗口内的重复报错一并吞掉
    // （一次失败 mpv 会连发多条 error），超出次数或非瞬断错误才落错误面板。
    if (_autoRetryPending || _maybeAutoRetry(err)) return;
    // 传输中断（清单/分段没读全）多为瞬时问题：同一地址先自动重开一次，再判失败。
    if (_shouldSoftRetry(err)) {
      _softRetrySpec = _currentSpec;
      _recentLogs.add('[retry] 传输中断，同一地址自动重开一次：$err');
      final spec = _currentSpec;
      if (spec != null) {
        final epoch = _sessionEpoch;
        unawaited(_open(spec).catchError((Object error) {
          if (!_isCurrentSession(epoch)) return;
          _currentError = '$error';
          _errorController.add(_currentError);
          _updateStatus(PlaybackStatus.error);
        }));
        return;
      }
    }
    _currentError = err;
    AppLogger.instance.warning(
        'player', '播放错误：${err.replaceAll(RegExp(r'\s+'), ' ')}');
    _errorController.add(err);
    _updateStatus(PlaybackStatus.error);
    // 内容级失败（格式无法识别 / 读到纯文本播放列表等）多半是「解析中转把错误页当视频回传」，
    // 回源诊断一次，把真实原因（如「秘钥不存在」）覆盖到错误面板。
    if (!_diagnosing && _contentErrorPattern.hasMatch(err)) {
      _diagnoseContentError();
    }
  }

  /// 是否值得「同一地址再开一次」：只针对传输中断，且每个会话只做一次。
  bool _shouldSoftRetry(String err) {
    final spec = _currentSpec;
    if (_disposed || _externalPlaybackPaused || spec == null) return false;
    if (identical(_softRetrySpec, spec)) return false;
    final text = err.toLowerCase();
    return text.contains('stream ends prematurely') || text.contains('ffurl_read');
  }

  /// 列表里的这条字幕轨，是否就是当前正在用的那条。
  ///
  /// 外挂字幕必须特殊对齐：`SubtitleTrack.uri` 的 `id` 是文件路径，而 mpv 的
  /// track-list 给同一条轨发的是数字 sid，两者永不相等——不认回来的话，
  /// 字幕明明在画面上跑，面板却显示「已关闭」。加载时我们把 title 写成了
  /// 文件名，只能靠它对齐。
  bool _subtitleSelected(String id, String? title) {
    final selected = _player.state.track.subtitle;
    if (id == selected.id) return true;
    final isPath = selected.id.contains('/') || selected.id.contains(r'\');
    return isPath && p.basename(selected.id) == title;
  }

  /// 用最新的 `state.track` 重算三条列表的选中态并重新推送。
  /// 只在「确实有变化」时发事件，避免每次选中流都让三个菜单重建。
  void _resyncTrackSelection() {
    final selected = _player.state.track;
    List<TrackInfo>? nextAudio;
    List<TrackInfo>? nextSubtitle;
    List<TrackInfo>? nextVideo;
    void sync(List<TrackInfo> current, bool Function(TrackInfo) hit,
        void Function(List<TrackInfo>) assign) {
      if (!current.any((t) => t.isSelected != hit(t))) return;
      assign(current
          .map((t) => TrackInfo(
                id: t.id,
                type: t.type,
                title: t.title,
                language: t.language,
                isSelected: hit(t),
              ))
          .toList());
    }

    sync(_audioTracks, (t) => t.id == selected.audio.id, (v) => nextAudio = v);
    sync(
        _subtitleTracks,
        (t) => _subtitleSelected(t.id, t.title),
        (v) => nextSubtitle = v);
    sync(_videoTracks, (t) => t.id == selected.video.id, (v) => nextVideo = v);

    if (nextAudio != null) {
      _audioTracks = nextAudio!;
      _audioTracksController.add(_audioTracks);
    }
    if (nextSubtitle != null) {
      _subtitleTracks = nextSubtitle!;
      _subtitleTracksController.add(_subtitleTracks);
    }
    if (nextVideo != null) {
      _videoTracks = nextVideo!;
      _videoTracksController.add(_videoTracks);
    }
  }

  // ---------------- 自动重试（网络瞬断） ----------------

  /// 本次播放会话已自动重试的次数（用户重新起播时清零）。
  int _autoRetryCount = 0;

  /// 有一条自动重试在途中（防抖：一次失败 mpv 可能连发多条 error）。
  bool _autoRetryPending = false;

  /// 自动重试上限：连续两次仍瞬断就交给错误面板，避免无限打转。
  static const int _maxAutoRetries = 2;

  /// 自动重试前的等待：给 CDN / 本地网络一点恢复时间。
  static const Duration _autoRetryDelay = Duration(milliseconds: 1500);

  /// 瞬断特征：mpv/libmpv 在 Windows 上把 Winsock 错误码以十六进制冒出来，
  /// `0xffffd8ba` = -10054 WSAECONNRESET（连接被对端重置）、
  /// `0xffffd8bb` = -10053 WSAECONNABORTED。免费 CDN 限速 / 踢连接时高发，
  /// 重新打开同一地址通常立刻恢复。
  static final RegExp _transientNetworkError = RegExp(
      r'ffurl_(read|write) returned 0x|connection reset|connection aborted|timed?\s?out',
      caseSensitive: false);

  /// 内容级失败特征：mpv 把中转返回的错误页（HTML/JSON/纯文本）当成媒体打开时，
  /// 会报「无法识别格式 / 读到纯文本播放列表」。这类最可能是解析中转返回了错误而非视频流。
  static final RegExp _contentErrorPattern = RegExp(
      r'recognize file format|plaintext playlist|no playable streams|invalid (?:data|format)|unsupported format',
      caseSensitive: false);

  /// 播放失败后最佳努力回源诊断：拉取一次中转地址，若其返回的是错误页（HTML/JSON），
  /// 用真实原因（如「秘钥不存在」）覆盖错误面板的文案。仅在播放已失败、且当前规格仍处错误态时生效，
  /// 因此不会影响任何正在进行的播放，也不会消耗可用线路的令牌。
  void _diagnoseContentError() {
    final spec = _currentSpec;
    if (spec == null || spec.isLive || _diagnosing || _disposed) return;
    final uri = Uri.tryParse(spec.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    _diagnosing = true;
    unawaited(() async {
      try {
        final reason =
            await diagnosePlaybackUrl(spec.url, headers: spec.headers);
        if (reason != null && !_disposed && _status == PlaybackStatus.error) {
          _currentError = reason;
          _errorController.add(reason);
          // 强制刷新错误面板：它随 statusStream 重建并读取 currentError；
          // 同时让自动换线把本次失败归类为「永久错误」从而立即换线。
          _statusController.add(_status);
        }
      } finally {
        _diagnosing = false;
      }
    }());
  }

  /// 判断 [err] 是否值得自动重试；是则安排一次断点续播并返回 true。
  bool _maybeAutoRetry(String err) {
    final spec = _currentSpec;
    if (spec == null || _disposed) return false;
    if (_autoRetryCount >= _maxAutoRetries) return false;
    if (!_transientNetworkError.hasMatch(err)) return false;
    _autoRetryCount++;
    _autoRetryPending = true;
    AppLogger.instance.info('player',
        '瞬断自动重试（第 $_autoRetryCount/$_maxAutoRetries 次），从断点续播');
    // 从最后一个已知位置续播：错误发生时播放已停，位置不再推进。
    final resumeMs = _position.inMilliseconds;
    _currentError = null;
    _errorController.add(null);
    _updateStatus(PlaybackStatus.buffering);
    unawaited(() async {
      try {
        await Future<void>.delayed(_autoRetryDelay);
        if (_disposed) return;
        // 直播没有「断点」：start 会让 mpv 尝试定位到滑动窗口里已经不存在的时刻，
        // 重试因此卡住或直接失败。直播一律重新接入。
        final retrySpec = MediaPlaySpec(
          url: spec.url,
          headers: spec.headers,
          title: spec.title,
          isLive: spec.isLive,
          startPosition: (!spec.isLive && resumeMs > 0)
              ? Duration(milliseconds: resumeMs)
              : null,
        );
        await _open(retrySpec);
      } finally {
        _autoRetryPending = false;
      }
    }());
    return true;
  }

  void _cancelErrorConfirm() {
    _errorConfirmTimer?.cancel();
    _errorConfirmTimer = null;
    _errorGate.reset();
  }

  /// 直播会话断流时按退避策略安排重开；返回 false 表示非直播或重试已用尽。
  bool _scheduleLiveReconnect() {
    final spec = _currentSpec;
    if (_disposed || _externalPlaybackPaused || spec == null || !spec.isLive) {
      return false;
    }
    if (_reconnectTimer != null) return true;
    final delay = _liveReconnect.nextDelay();
    if (delay == null) return false;
    final epoch = _sessionEpoch;
    _recentLogs.add('[reconnect] 直播断流，${delay.inSeconds}s 后第 '
        '${_liveReconnect.attempts} 次重连');
    AppLogger.instance.info('player',
        '直播断流，${delay.inSeconds}s 后第 ${_liveReconnect.attempts} 次重连');
    _updateStatus(PlaybackStatus.buffering);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || epoch != _sessionEpoch || _currentSpec != spec) return;
      unawaited(_open(spec).catchError((Object error) {
        if (epoch != _sessionEpoch) return;
        if (!_scheduleLiveReconnect()) {
          _currentError = '$error';
          _errorController.add(_currentError);
          _updateStatus(PlaybackStatus.error);
        }
      }));
    });
    return true;
  }

  void _cancelLiveReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _liveReconnect.reset();
  }

  /// 按会话类型写入网络缓冲参数（见 [sessionStreamProperties]）；须在 open 前生效。
  /// 把「系统代理」下发给 mpv。
  ///
  /// mpv/ffmpeg 只认进程环境变量（`HTTP_PROXY`/`HTTPS_PROXY`），读不到 Windows 的
  /// 「系统代理」设置（Clash 等的默认模式）。于是开着系统代理时：弹幕/伴随服务能联网，
  /// **播放器却在直连** —— HLS 子清单/分片走不通，表现就是时长只认出几秒、越播越长、
  /// 快到底再加载（§58 记录的同款症状，另一种成因）。
  ///
  /// 两条约束：① 回环地址（本机网盘代理）必须显式直连，否则会被塞进代理；
  /// ② 没有系统代理时**不动**，避免把用环境变量代理的用户清掉。
  Future<void> _applyPlaybackProxy(String url) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final host = Uri.tryParse(url)?.host ?? '';
    final loopback = host.isEmpty ||
        host == 'localhost' ||
        host == '::1' ||
        host.startsWith('127.');
    String value;
    if (loopback) {
      value = '';
    } else {
      final proxy = DanmakuApi.systemProxy();
      if (proxy == null || proxy.isEmpty) return;
      value = proxy.contains('://') ? proxy : 'http://$proxy';
    }
    try {
      await platform.setProperty('http-proxy', value);
    } catch (_) {
      // 个别 mpv 构建不支持该属性：保持默认，不影响主链路。
    }
  }

  Future<void> _applySessionStreamProperties(bool isLive, int epoch) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    for (final entry in sessionStreamProperties(isLive: isLive).entries) {
      if (!_isCurrentSession(epoch)) return;
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (_) {
        // 个别 mpv 构建不支持某属性：保持默认，不影响播放主链路。
      }
    }
  }

  void _resetMediaEvidence() {
    cancelSeekRecovery();
    _subtitleChoice++;
    _sourceSubtitleIds.clear();
    _subtitleCodec = null;
    _openingMedia = true;
    _awaitingOpenPosition = true;
    _sawOpenPosition = false;
    _hasOpenLiveFrame = false;
    _openedMediaUri = null;
    _nativeBuffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffer = Duration.zero;
    _dimensions = const VideoDimensions();
    _audioTracks = [];
    _subtitleTracks = [];
    _videoTracks = [];
    _positionController.add(_position);
    _durationController.add(_duration);
    _bufferController.add(_buffer);
    _dimensionsController.add(_dimensions);
    _audioTracksController.add(_audioTracks);
    _subtitleTracksController.add(_subtitleTracks);
    _videoTracksController.add(_videoTracks);
    _updateStatus(PlaybackStatus.buffering);
  }

  Future<void> _open(MediaPlaySpec spec,
      {bool play = true, int? sessionEpoch}) async {
    final epoch = sessionEpoch ?? _sessionEpoch;
    if (!_isCurrentSession(epoch) || !_mpvOwnsPlayback || _externalPlaybackPaused) return;
    final openEpoch = ++_openEpoch;
    _cancelErrorConfirm();
    _resetMediaEvidence();
    late final String openedUri;
    try {
      final attaching = _localSubtitles.pending;
      if (attaching != null) {
        await attaching;
        if (!_isCurrentSession(epoch) || openEpoch != _openEpoch) return;
      }
      if (_volumeNeedsSync) {
        await _player.setVolume(_volume);
        if (!_isCurrentSession(epoch) || openEpoch != _openEpoch) return;
        _volumeNeedsSync = false;
      }
      await _applySessionStreamProperties(spec.isLive, epoch);
      if (!_isCurrentSession(epoch) || openEpoch != _openEpoch) return;
      await _applyPlaybackProxy(spec.url);
      if (!_isCurrentSession(epoch) || openEpoch != _openEpoch) return;
      final media = Media(
        spec.url,
        // 站点没给 UA/Referer 时补浏览器默认值（有些源按 UA 拦非浏览器请求）。
        httpHeaders: withBrowserHeaderFallbacks(spec.headers, spec.url,
            enabled: playbackSettings.browserHeaders),
        // 直播是实时流，带起播位置会让 mpv 尝试 seek 到不存在的时间点。
        start: spec.isLive ? null : spec.startPosition,
      );
      openedUri = media.uri;
      _openedMediaUri = openedUri;
      // 本地缓存（旁路）：失败绝不影响播放，因此不等待也不捕获到播放链路
      if (_cacheDefaultRoot.isNotEmpty) {
        _cacheReanchorTimer?.cancel();
        _cacheReanchorTimer = null;
        unawaited(cacheStore.start(spec, defaultRoot: _cacheDefaultRoot));
      }
      await _player.open(media, play: play);
    } finally {
      if (_isCurrentSession(epoch) && openEpoch == _openEpoch) {
        // invariant: open's synthetic playing event is not loaded-media evidence.
        _openingMedia = false;
      }
    }
    await _readOpenedMediaEvidence(epoch, openEpoch, openedUri);
    if (_isCurrentSession(epoch) && openEpoch == _openEpoch) {
      // 本地媒体可能在 open 返回前就发出了唯一一次轨道列表。
      await _refreshSubtitleTracks();
    }
  }

  Future<void> _readOpenedMediaEvidence(
      int epoch, int openEpoch, String expectedUri) async {
    final platform = _player.platform;
    bool isCurrent() =>
        _isCurrentSession(epoch) &&
        openEpoch == _openEpoch &&
        _awaitingOpenPosition &&
        _acceptMediaEvents &&
        _openedMediaUri == expectedUri;
    if (platform is! NativePlayer || !isCurrent()) return;
    try {
      // Read mpv itself: Player.state can still describe the previous file.
      // Paused media may have emitted its only position while open was pending.
      final path = await platform.getProperty('path');
      if (!isCurrent() || path != expectedUri) return;
      if (await platform.getProperty('seeking') != 'no' || !isCurrent()) return;
      final duration = double.tryParse(await platform.getProperty('duration'));
      if (!isCurrent()) return;
      final position = double.tryParse(await platform.getProperty('time-pos'));
      if (!isCurrent()) return;
      final buffering = await platform.getProperty('paused-for-cache');
      if (!isCurrent() ||
          position == null ||
          !position.isFinite ||
          position < 0 ||
          buffering != 'no') {
        return;
      }
      final positiveDuration =
          duration != null && duration.isFinite && duration > 0 ? duration : null;
      VideoDimensions? decoded;
      if (positiveDuration == null) {
        if (!_awaitingPausedLiveOpen ||
            (duration != null && (!duration.isFinite || duration < 0))) {
          return;
        }
        if (await platform.getProperty('pause') != 'yes' || !isCurrent()) return;
        final width = int.tryParse(await platform.getProperty('video-dec-params/w'));
        if (!isCurrent()) return;
        final height = int.tryParse(await platform.getProperty('video-dec-params/h'));
        if (!isCurrent() || width == null || height == null || width <= 0 || height <= 0) {
          return;
        }
        if (await platform.getProperty('path') != expectedUri ||
            !isCurrent() || !_awaitingPausedLiveOpen) {
          return;
        }
        decoded = VideoDimensions(width: width, height: height);
      }
      _nativeBuffering = false;
      _publishDuration(positiveDuration == null
          ? Duration.zero
          : Duration(microseconds: (positiveDuration * Duration.microsecondsPerSecond).round()));
      if (decoded != null) {
        _hasOpenLiveFrame = true;
        _dimensions = decoded;
        _dimensionsController.add(decoded);
      }
      _publishPosition(Duration(
          microseconds: (position * Duration.microsecondsPerSecond).round()));
    } catch (error) {
      if (isCurrent()) _recentLogs.add('[source-evidence] $error');
    }
  }

  @override
  Future<void> play(MediaPlaySpec spec) async {
    if (_disposed) throw StateError('播放器已关闭');
    // 换源 / 换线自动终止上一会话的录制（已写内容保留为不完整文件）；
    // MediaRecorder.stop 会等后台下载循环真正退出，再进新会话，
    // 避免新旧录制器抢同一批 HTTP 连接与文件句柄。
    if (_recording) {
      try {
        await stopRecording();
      } catch (_) {
        // 清理失败不阻塞起播。
      }
    }
    final epoch = ++_sessionEpoch;
    final closing = _retireEmbedded();
    AppLogger.instance.info('player',
        '开始播放：${spec.title}（${spec.isLive ? '直播' : '点播'}）');
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    _pauseIntent = false;
    _externalPlaybackPaused = false;
    _currentSpec = spec;
    _softRetrySpec = null;
    _currentError = null;
    _errorController.add(null);
    _resetMediaEvidence();
    // 用户主动起播 = 新会话：自动重试计数与诊断状态归零。
    _autoRetryCount = 0;
    _autoRetryPending = false;
    _diagnosing = false;
    // 每次新播放会话重置诊断日志，避免上一部片的日志混进本次错误诊断。
    _recentLogs.clear();
    // 播放模式与来源 / 依据（探测结果、回退原因）写进诊断日志：
    // 「复制诊断」里能直接看到本次为什么按点播 / 直播起播。
    _recentLogs.add('[mode] ${spec.isLive ? '直播' : '点播'}'
        '（来源: ${playbackModeSourceLabel(spec.modeSource)}'
        '${spec.modeDetail == null ? '' : '；依据: ${spec.modeDetail}'}）');
    if (closing != null) {
      await closing;
      if (!_isCurrentSession(epoch)) return;
    }
    await _applySessionRate(spec);
    if (!_isCurrentSession(epoch)) return;
    await _open(spec, play: !_pauseIntent, sessionEpoch: epoch);
  }

  /// Replaces media while keeping user playback controls and diagnostics.
  /// Completion only acknowledges open; callers must wait for fresh evidence.
  Future<void> switchSource(MediaPlaySpec spec) async {
    if (_disposed) throw StateError('播放器已关闭');
    final savedRate = _rate;
    final savedVolume = _volume;
    final epoch = ++_sessionEpoch;
    final closing = _retireEmbedded();
    _externalPlaybackPaused = false;
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    _currentSpec = spec;
    _softRetrySpec = null;
    _currentError = null;
    _errorController.add(null);
    _resetMediaEvidence();
    _recentLogs.add('[source-switch] 保留倍速、音量和暂停状态');
    if (closing != null) {
      await closing;
      if (!_isCurrentSession(epoch)) return;
    }
    final wasPaused = _pauseIntent;
    await _open(spec, play: !wasPaused, sessionEpoch: epoch);
    if (!_isCurrentSession(epoch)) return;
    await setRate(savedRate);
    if (!_isCurrentSession(epoch)) return;
    await setVolume(closing != null ? _volume : savedVolume);
    if (!_isCurrentSession(epoch)) return;
    if (_pauseIntent != wasPaused) {
      if (_pauseIntent) {
        await _player.pause();
      } else {
        await _player.play();
      }
    }
  }

  /// 验收 C1：「默认倍速」每次起播都生效（以前只在播放器初始化时应用一次，
  /// 改设置后重新起播仍是旧倍速；mpv 的 speed 跨文件保留，上一部片手动调的倍速也会带过来）。
  /// 直播固定 1x：实时流加速只会追到直播边缘后反复缓冲。
  Future<void> _applySessionRate(MediaPlaySpec spec) async {
    final target = sessionPlaybackRate(
        isLive: spec.isLive, defaultRate: playbackSettings.defaultRate);
    try {
      await setRate(target);
    } catch (_) {
      // 倍速写入失败不阻断起播。
    }
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    _pauseIntent = true;
    if (!_mpvOwnsPlayback) return _embeddedPause(true);
    await _player.pause();
    if (!_disposed) {
      await _readSettledSeekPosition();
      _readPendingLiveEvidence();
    }
  }

  /// Pauses a handed-off session without allowing background recovery to reopen
  /// it. The media and controls stay available for an explicit return to playback.
  Future<void> pauseForExternalPlayback() async {
    if (_disposed || _currentSpec == null) return;
    if (_route != null) {
      _pauseIntent = true;
      final restore = selectPlaybackBackend(null);
      final epoch = _sessionEpoch;
      if (!await restore || !_isCurrentSession(epoch) || !_pauseIntent) return;
    }
    final epoch = ++_sessionEpoch;
    _openEpoch++;
    _externalPlaybackPaused = true;
    _pauseIntent = true;
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    cancelSeekRecovery();
    // An invalidated open no longer owns its finally block. Retire its evidence
    // flags here, while the handoff gate keeps late native events from publishing.
    _openingMedia = false;
    _awaitingOpenPosition = false;
    _nativeBuffering = false;
    await _player.pause();
    if (!_isCurrentSession(epoch) || !_externalPlaybackPaused) return;
    _updateStatus(PlaybackStatus.paused);
  }

  @override
  Future<void> resume() async {
    if (_disposed) return;
    if (_externalPlaybackPaused) {
      // A pending handoff pause must not publish after an explicit resume.
      _sessionEpoch++;
      _externalPlaybackPaused = false;
    }
    _pauseIntent = false;
    if (!_mpvOwnsPlayback) return _embeddedPause(false);
    await _player.play();
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    AppLogger.instance.info('player', '停止播放');
    if (_recording) {
      try {
        await stopRecording();
      } catch (_) {
        // 停止播放为主目标，录制清理失败不阻断。
      }
    }
    final epoch = ++_sessionEpoch;
    _openEpoch++;
    final closing = _retireEmbedded();
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    cancelSeekRecovery();
    _currentSpec = null;
    _pauseIntent = false;
    _externalPlaybackPaused = false;
    _openingMedia = false;
    _awaitingOpenPosition = false;
    if (closing != null) {
      await closing;
      if (!_isCurrentSession(epoch)) return;
    }
    final attaching = _localSubtitles.pending;
    if (attaching != null) {
      await attaching;
      if (!_isCurrentSession(epoch)) return;
    }
    await _player.stop();
    if (!_isCurrentSession(epoch)) return;
    _cacheReanchorTimer?.cancel();
    _cacheReanchorTimer = null;
    cacheStore.stop();
    _updateStatus(PlaybackStatus.idle);
  }

  @override
  Future<void> seek(Duration position) async {
    // 直播兜底拒绝：即使将来 UI 新增了 seek 入口（画中画 / 遥控 / 脚本），
    // 也不把直播推进「seek → 流错误 → 断流重连 → 从头播」的坑。
    if (_currentSpec?.isLive == true) {
      _recentLogs.add(
          '[seek-rejected] 直播会话忽略 seek 到 ${position.inMilliseconds}ms');
      return;
    }
    if (!_mpvOwnsPlayback) return _embeddedSeek(position);
    await _seekTo(position, originalPosition: _position);
  }

  Future<void> _seekTo(Duration position,
      {required Duration originalPosition}) async {
    if (_disposed || _currentSpec == null || _openingMedia) return;
    final target = position < Duration.zero
        ? Duration.zero
        : _duration > Duration.zero && position > _duration
            ? _duration
            : position;
    final epoch = _sessionEpoch;
    _cancelErrorConfirm();
    _seekEvidenceGeneration = null;
    final generation = _seekRecovery.begin(
        originalPosition: originalPosition, targetPosition: target);
    try {
      // 本地缓存：seek 后重锚下载前沿到新位置（失败不影响 seek）。
      _reanchorCacheAfterSeek(target);
      await _player.seek(target);
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation) {
        return;
      }
      _seekEvidenceGeneration = generation;
      await _readSettledSeekPosition();
    } catch (error) {
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation) {
        return;
      }
      _recentLogs.add('[seek-command-error] $error');
      _seekRecovery.fail(generation);
    }
  }

  @override
  Future<void> retrySeek() async {
    final recovery = _seekRecovery.value;
    if (!recovery.isRecoverable) return;
    await _seekTo(recovery.targetPosition!,
        originalPosition: recovery.originalPosition!);
  }

  @override
  Future<void> returnToPreSeekPosition() async {
    final recovery = _seekRecovery.value;
    if (!recovery.isRecoverable) return;
    await _seekTo(recovery.originalPosition!,
        originalPosition: recovery.originalPosition!);
  }

  @override
  void cancelSeekRecovery() {
    _seekEvidenceGeneration = null;
    _seekRecovery.cancel();
  }

  Future<void> _observeNativeSeekCompletion() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.observeProperty('seeking', (value) async {
        if (value == 'no') {
          await _readSettledSeekPosition();
          _readPendingLiveEvidence();
        }
      });
    } catch (error) {
      _recentLogs.add('[seek-observer] $error');
    }
  }

  Future<void> _readSettledSeekPosition() async {
    final generation = _seekEvidenceGeneration;
    if (generation == null || !_hasPendingSeek || !_acceptMediaEvents) return;
    final epoch = _sessionEpoch;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      if (await platform.getProperty('seeking') != 'no') return;
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation) {
        return;
      }
      final seconds = double.tryParse(await platform.getProperty('time-pos'));
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation) {
        return;
      }
      final buffering = await platform.getProperty('paused-for-cache');
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation ||
          seconds == null ||
          !seconds.isFinite ||
          buffering != 'no') {
        return;
      }
      _seekRecovery.onPosition(
        Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round()),
        generation: generation,
        isPaused: _pauseIntent,
        isBuffering: false,
      );
    } catch (error) {
      if (_isCurrentSession(epoch) &&
          _seekRecovery.value.generation == generation) {
        _recentLogs.add('[seek-evidence] $error');
      }
    }
  }

  /// 跳到缓存前沿之后时，把缓存任务的锚点挪到新位置。
  ///
  /// 缓存按「起播位置 → 片尾 → 回头补前缀」的顺序下，锚点定在起播那一刻。
  /// 用户一把拖到 40 分钟处（前沿才 6 分钟），下载仍在老锚点后方爬：新位置
  /// 只能走网络，看起来就像「缓存开着却没生效」，同时还继续下着没人看的前方分片。
  void _reanchorCacheAfterSeek(Duration position) {
    if (_disposed || _cacheDefaultRoot.isEmpty) return;
    final spec = _currentSpec;
    if (spec == null || !cacheStore.isRunning) return;
    // 前沿之前（含一点余量）已经缓存过，重锚只会白扔掉当前任务的进度。
    if (position.inMilliseconds <= cacheStore.progress.frontierMs + 30 * 1000) {
      return;
    }
    _cacheReanchorTimer?.cancel();
    _cacheReanchorTimer = Timer(const Duration(milliseconds: 600), () {
      final current = _currentSpec;
      if (_disposed || current == null || current.url != spec.url) return;
      unawaited(cacheStore.start(
        MediaPlaySpec(
          url: current.url,
          headers: current.headers,
          title: current.title,
          isLive: current.isLive,
          startPosition: position,
        ),
        defaultRoot: _cacheDefaultRoot,
      ));
    });
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    final clamped = volume.clamp(0.0, 100.0);
    if (!_mpvOwnsPlayback) return _embeddedVolume(clamped);
    await _player.setVolume(clamped);
  }

  @override
  Future<void> setRate(double rate) async {
    if (!_mpvOwnsPlayback) return;
    final clamped = rate.clamp(0.25, 4.0);
    // 立刻更新缓存而不等播放器事件回传：长按松开后紧接着切集时，
    // 起播链路要读到恢复后的倍速，不能读到回传前的临时倍率。
    _rate = clamped;
    await _player.setRate(clamped);
  }

  @override
  Future<void> setHardwareDecoding(String mode) async {
    if (!_mpvOwnsPlayback) return;
    await applyPlaybackSettings(
        playbackSettings.copyWith(hwdec: PlayerSettings.normalizeHwdec(mode)));
  }

  @override
  Future<void> selectAudioTrack(TrackInfo track) async {
    if (!_mpvOwnsPlayback) return;
    final nativeAudio = _player.state.tracks.audio.firstWhere(
      (a) => a.id == track.id,
      orElse: () => AudioTrack(track.id, track.title, track.language),
    );
    await _player.setAudioTrack(nativeAudio);
  }

  int? get subtitleSession => _nativeCreated && _acceptMediaEvents &&
          _openedMediaUri != null && _player.platform is NativePlayer
      ? _openEpoch
      : null;

  double get subtitleScale => _subtitleScale;

  static const _textSubtitleCodecs = {
    'subrip', 'srt', 'ass', 'ssa', 'webvtt', 'mov_text', 'text', 'ttml',
    'microdvd', 'sami', 'subviewer', 'subviewer1', 'mpl2', 'jacosub',
  };

  bool get canScaleSubtitle =>
      subtitleSession != null && _textSubtitleCodecs.contains(_subtitleCodec);

  Future<bool> setSubtitleScale(double factor) async {
    final session = subtitleSession;
    if (session == null) return false;
    if (!factor.isFinite || factor < 0.5 || factor > 2) {
      throw ArgumentError.value(factor, 'factor', '字幕缩放应在 0.5 到 2 之间');
    }
    final native = _player.platform as NativePlayer;
    final codec = await native.getProperty('current-tracks/sub/codec');
    if (session != subtitleSession) return false;
    if (!_textSubtitleCodecs.contains(codec)) {
      throw UnsupportedError('当前字幕轨不支持调整字号');
    }
    await native.setProperty('sub-scale', '$factor', waitForInitialization: false);
    final actual = double.tryParse(await native.getProperty('sub-scale'));
    if (session != subtitleSession) return false;
    if (actual == null || !actual.isFinite || (actual - factor).abs() > 0.001) {
      throw UnsupportedError('播放器未能调整字幕大小');
    }
    _subtitleScale = actual;
    return true;
  }

  Future<bool> loadLocalSubtitle(String path, {required int session}) async {
    if (session != subtitleSession) return false;
    final platform = _player.platform as NativePlayer;
    final choice = ++_subtitleChoice;
    final epoch = _sessionEpoch;
    bool current() => session == subtitleSession && _isCurrentSession(epoch) && choice == _subtitleChoice;
    final bool loaded;
    try {
      loaded = await _localSubtitles.load(platform, path, current);
    } finally {
      if (current()) await _refreshSubtitleTracks();
    }
    return loaded && current();
  }

  @override
  Future<void> selectSubtitleTrack(TrackInfo track) async {
    final choice = ++_subtitleChoice;
    final epoch = _openEpoch;
    final spec = _currentSpec;
    bool current() => _acceptMediaEvents && choice == _subtitleChoice && epoch == _openEpoch;
    final attaching = _localSubtitles.pending;
    if (attaching != null) await attaching;
    if (spec == null || !current()) return;
    final sourceIndex = spec.subtitles.asMap().keys
        .where((i) => track.id == 'source:$epoch:$i').firstOrNull;
    var id = track.id;
    if (sourceIndex != null) {
      final existing = _sourceSubtitleIds[sourceIndex];
      if (existing == null) {
        final source = spec.subtitles[sourceIndex];
        final platform = _player.platform;
        if (platform is! NativePlayer) throw UnsupportedError('当前播放器不支持站源外挂字幕');
        String text;
        try {
          text = await source.readText(mediaUrl: spec.url, headers: spec.headers,
              proxy: DanmakuApi.systemProxy);
        } catch (_) {
          throw UnsupportedError('站源字幕下载失败或格式不支持');
        }
        if (!current()) return;
        final previousIds = _player.state.tracks.subtitle.map((t) => t.id).toSet();
        await _player.setSubtitleTrack(SubtitleTrack.data(text, title: source.name));
        if (!current()) return;
        final added = await platform.getProperty('current-tracks/sub/id');
        final title = await platform.getProperty('current-tracks/sub/title');
        if (!current()) return;
        if (added.isEmpty || previousIds.contains(added) || title != source.name) {
          throw UnsupportedError('播放器未能启用这条站源字幕');
        }
        _sourceSubtitleIds[sourceIndex] = added;
        await _refreshSubtitleTracks();
        return;
      }
      id = existing;
    }
    final nativeSub = _player.state.tracks.subtitle.firstWhere((s) => s.id == id);
    await _player.setSubtitleTrack(nativeSub);
    final selected = await _refreshSubtitleTracks();
    if (current() && id != 'auto' && selected != id) {
      throw UnsupportedError('播放器未能启用这条字幕，请换一条字幕轨');
    }
  }

  Future<String?> _refreshSubtitleTracks() async {
    if (!_acceptMediaEvents) return null;
    final epoch = _openEpoch;
    final read = ++_subtitleRead;
    final platform = _player.platform;
    // media_kit 的 track 字段是请求值（含 auto 或未能解码的轨道），不是 mpv 的实际选择。
    String? selected;
    String? codec;
    try {
      selected = platform is NativePlayer
          ? await platform.getProperty('current-tracks/sub/id')
          : _player.state.track.subtitle.id;
      if (platform is NativePlayer && selected.isNotEmpty) {
        codec = await platform.getProperty('current-tracks/sub/codec');
      }
    } catch (error) {
      // 字幕状态不可读也不能让打开媒体失败，或留下上一部片的勾选。
      if (_acceptMediaEvents && epoch == _openEpoch) {
        _recentLogs.add('[subtitle] 无法读取当前字幕轨：$error');
      }
    }
    if (!_acceptMediaEvents || epoch != _openEpoch || read != _subtitleRead) return selected;
    _subtitleCodec = codec;
    final tracks = _player.state.tracks.subtitle;
    final sources = _currentSpec!.subtitles;
    _subtitleTracks = [
      if (tracks.any((t) => t.id != 'auto' && t.id != 'no'))
        const TrackInfo(id: 'auto', type: TrackType.subtitle, title: '自动选择'),
      for (final t in tracks)
        if (t.id != 'auto' && t.id != 'no' && !_sourceSubtitleIds.containsValue(t.id))
          TrackInfo(id: t.id, type: TrackType.subtitle, title: t.title,
              language: t.language, isSelected: t.id == selected),
      for (var i = 0; i < sources.length; i++)
        TrackInfo(id: 'source:$epoch:$i', type: TrackType.subtitle,
            title: sources[i].name,
            isSelected: selected != null && _sourceSubtitleIds[i] == selected),
    ];
    _subtitleTracksController.add(_subtitleTracks);
    return selected;
  }

  @override
  Future<void> disableSubtitle() async {
    if (!_mpvOwnsPlayback) return;
    final choice = ++_subtitleChoice;
    final epoch = _openEpoch;
    final attaching = _localSubtitles.pending;
    if (attaching != null) {
      await attaching;
      if (!_acceptMediaEvents || epoch != _openEpoch || choice != _subtitleChoice) return;
    }
    await _player.setSubtitleTrack(SubtitleTrack.no());
    await _refreshSubtitleTracks();
  }

  @override
  Future<void> addSubtitleFile(String path) async {
    // media_kit 1.2.6 没有公开的 openSubtitle：SubtitleTrack.uri 会走 mpv 的
    // `sub-add <path> select <title> <lang>`，加载即选中，并作为新字幕轨进轨道列表。
    await _player.setSubtitleTrack(
        SubtitleTrack.uri(path, title: p.basename(path)));
  }

  @override
  Future<void> selectVideoTrack(TrackInfo track) async {
    if (!_mpvOwnsPlayback) return;
    final VideoTrack native;
    if (track.id == 'auto') {
      native = VideoTrack.auto();
    } else if (track.id == 'no') {
      native = VideoTrack.no();
    } else {
      native = _player.state.tracks.video.firstWhere(
        (v) => v.id == track.id,
        orElse: () => VideoTrack(track.id, track.title, track.language),
      );
    }
    await _player.setVideoTrack(native);
  }

  void _updateStatus(PlaybackStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      _statusController.add(newStatus);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    if (_recording) {
      try {
        await stopRecording();
      } catch (_) {
        // 退出流程中录制清理失败不阻断资源释放。
      }
    }
    _disposed = true;
    _sessionEpoch++;
    _openEpoch++;
    final closing = _retireEmbedded();
    _embeddedTexture.dispose();
    _seekEvidenceGeneration = null;
    _seekRecovery.dispose();
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    _cacheReanchorTimer?.cancel();
    _cacheReanchorTimer = null;
    await cacheStore.dispose();
    await settingsApplication.dispose();
    if (closing != null) {
      try {
        await closing;
      } catch (_) {
        // A failed native release must not leak the mpv player or its streams.
      }
    }
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    final attaching = _localSubtitles.pending;
    if (attaching != null) await attaching;
    if (_nativeCreated) await _player.dispose();
    await _statusController.close();
    await _positionController.close();
    await _durationController.close();
    await _bufferController.close();
    await _volumeController.close();
    await _rateController.close();
    await _dimensionsController.close();
    await _errorController.close();
    await _audioTracksController.close();
    await _subtitleTracksController.close();
    await _videoTracksController.close();
    await _recordingController.close();
    await _recordingEndedController.close();
    await _recordingFinishedController.close();
  }

  // ==================== 录制 ====================

  @override
  bool get isRecording => _recording;

  @override
  Stream<bool> get recordingStream => _recordingController.stream;

  Stream<String> get recordingEndedStream => _recordingEndedController.stream;

  Stream<String> get recordingFinishedStream =>
      _recordingFinishedController.stream;

  /// 录制后台任务结束（点播清单下完 / 直播轮询被停）时，由 [startRecording]
  /// 挂的监听回调调用。用户没点停止，说明是后台自己结束的——要么是正常
  /// 录完（点播），要么是源断了（直播断流 / 中途报错），两者提示必须分开。
  void _onRecorderFinished(MediaRecorder recorder) {
    if (!_recording || _recordingStopRequested) return;
    final path = _recordingPath;
    // 先复位状态，UI 按钮随即回到「开始录制」。
    _recorder = null;
    _recording = false;
    _recordingPath = null;
    if (!_recordingController.isClosed) _recordingController.add(false);
    if (recorder.completed) {
      // 点播下完是正常结束，绝不能报成故障。
      if (!_recordingFinishedController.isClosed) {
        _recordingFinishedController
            .add(path == null ? '录制完成' : '录制完成：$path');
      }
      return;
    }
    // 已写入的部分仍是可用的分片流（直播尤其常见），照常保留并提示用户。
    final reason = path == null
        ? '录制已结束：视频源已断开'
        : '录制已结束：视频源已断开，已保留部分文件：$path';
    if (!_recordingEndedController.isClosed) {
      _recordingEndedController.add(reason);
    }
  }

  @override
  Future<void> startRecording(String path, {Duration? from}) async {
    if (_recording) throw StateError('已经在录制中');
    final spec = _currentSpec;
    if (spec == null || spec.url.isEmpty) throw StateError('当前没有正在播放的内容');
    // 目标目录必须先建好，否则文件根本落不了盘。
    try {
      Directory(File(path).parent.path).createSync(recursive: true);
    } catch (e) {
      throw StateError('无法创建录制目录：$e');
    }
    // 直接抓播放源：HLS 逐分片拼接 / 直链字节 dump。start() 返回时
    // 文件里已有真实字节，失败会抛出面向用户的错误信息。
    // from = 当前播放位置：点播从「正在看的地方」开始录（跳过贴片广告）。
    final fromMs = from?.inMilliseconds ?? 0;
    final durationMs = _duration.inMilliseconds;
    // 片尾 / 已播完时不要按当前位置起录：HLS 只会剩下最后一个分片，
    // 产物只有几秒，而且对「想留存这一集」的用户毫无价值。
    final tooLate = fromMs > 0 && durationMs > 0
        ? fromMs >= durationMs - _recordTailGuard.inMilliseconds
        : false;
    final recorder = MediaRecorder(
      url: spec.url,
      outputPath: path,
      headers: spec.headers,
      startOffset: tooLate ? Duration.zero : (from ?? Duration.zero),
    );
    try {
      await recorder.start();
    } catch (_) {
      await recorder.stop(); // 失败即收尾，避免后台任务悬挂
      rethrow;
    }
    _recorder = recorder;
    _recording = true;
    _recordingPath = path;
    _recordingStopRequested = false;
    // 后台任务自己结束（点播下完 / 直播断流）时通知 UI：否则按钮永远停在
    // 「停止录制」，用户只能反复点停止才可能发现录制早就不在跑了。
    // done 在 stop() 之后也会完成，此时 _recordingStopRequested 已拦住提示。
    unawaited(recorder.done.whenComplete(() => _onRecorderFinished(recorder)));
    if (!_recordingController.isClosed) _recordingController.add(true);
  }

  @override
  Future<String?> stopRecording() async {
    if (!_recording) return null;
    final path = _recordingPath;
    final recorder = _recorder;
    // 先立旗：recorder.stop() 会让 done 完成，回调里据此跳过「意外结束」提示
    // （用户点停止、换源中止都属于「我让它停的」）。
    _recordingStopRequested = true;
    _recorder = null;
    _recording = false;
    _recordingPath = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } catch (_) {
        // 停止失败的兜底：客户端已强制关闭，文件保留已写入部分。
      }
    }
    if (!_recordingController.isClosed) _recordingController.add(false);
    return path;
  }

  // --- 快照属性 ---
  @override
  PlaybackStatus get status => _status;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  Duration get buffer => _mpvOwnsPlayback ? _buffer : Duration.zero;
  @override
  double get volume => _volume;
  @override
  double get rate => _mpvOwnsPlayback ? _rate : 1.0;
  @override
  VideoDimensions get dimensions => _dimensions;
  @override
  String? get currentError => _currentError;
  @override
  MediaPlaySpec? get currentSpec => _currentSpec;

  /// 应用视频缓存偏好；记住默认根目录，之后的每次起播都会用它启动缓存任务。
  @override
  Future<void> applyCachePreferences(VideoCachePreferences preferences,
      {required String defaultRoot}) async {
    _cacheDefaultRoot = defaultRoot;
    await cacheStore.applyPreferences(preferences, defaultRoot: defaultRoot);
  }

  @override
  VideoCacheProgress get cacheProgress => cacheStore.progress;

  @override
  Stream<VideoCacheProgress> get cacheProgressStream =>
      cacheStore.progressStream;

  /// 最近 40 条引擎日志（④ 诊断闭环；只读快照，供错误面板展示与复制）。
  List<String> get recentPlayerLogs => _mpvOwnsPlayback ? _recentLogs.entries : const [];
  @override
  List<TrackInfo> get audioTracks => _mpvOwnsPlayback ? _audioTracks : const [];
  @override
  List<TrackInfo> get subtitleTracks => _mpvOwnsPlayback ? _subtitleTracks : const [];
  @override
  List<TrackInfo> get videoTracks => _mpvOwnsPlayback ? _videoTracks : const [];

  // --- 状态流 ---
  @override
  Stream<PlaybackStatus> get statusStream => _statusController.stream;
  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration> get durationStream => _durationController.stream;
  @override
  Stream<Duration> get bufferStream => _bufferController.stream;
  @override
  Stream<double> get volumeStream => _volumeController.stream;
  @override
  Stream<double> get rateStream => _rateController.stream;
  @override
  Stream<VideoDimensions> get dimensionsStream => _dimensionsController.stream;
  @override
  Stream<String?> get errorStream => _errorController.stream;
  @override
  Stream<List<TrackInfo>> get audioTracksStream =>
      _audioTracksController.stream;
  @override
  Stream<List<TrackInfo>> get subtitleTracksStream =>
      _subtitleTracksController.stream;
  @override
  Stream<List<TrackInfo>> get videoTracksStream =>
      _videoTracksController.stream;
}
