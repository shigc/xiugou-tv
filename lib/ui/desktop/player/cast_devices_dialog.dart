import 'package:flutter/material.dart';

import '../../../core/dlna/dlna_cast_controller.dart';
import '../../../core/dlna/dlna_device.dart';
import '../../../core/player/models/player_state.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../dialogs/app_dialog.dart';
import '../dialogs/escape_closable.dart';

/// 投屏设备选择弹窗：SSDP 扫描局域网 DLNA 设备，点击即把当前播放推送过去。
///
/// 返回值：成功推送的设备名（用于宿主 OSD 提示）；取消 / 失败返回 null。
/// 服务由宿主的长生命周期 [DlnaCastController] 提供，弹窗关闭不会中断投屏。
class CastDevicesDialog extends StatefulWidget {
  const CastDevicesDialog({
    super.key,
    required this.spec,
    required this.controller,
  });

  /// 当前播放内容（取 url / title 推送到电视）。
  final MediaPlaySpec spec;

  /// 应用级投屏会话控制器（持有服务与当前设备）。
  final DlnaCastController controller;

  static Future<String?> show(
    BuildContext context, {
    required MediaPlaySpec spec,
    required DlnaCastController controller,
  }) =>
      showAppDialog<String>(
        context: context,
        builder: (_) => EscapeClosable(
          child: CastDevicesDialog(spec: spec, controller: controller),
        ),
      );

  @override
  State<CastDevicesDialog> createState() => _CastDevicesDialogState();
}

class _CastDevicesDialogState extends State<CastDevicesDialog> {
  final TextEditingController _ipController = TextEditingController();

  bool _scanning = true;
  bool _casting = false;
  bool _probing = false;
  bool _busy = false;
  String? _error;
  List<DlnaDevice> _devices = const [];

  DlnaCastController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final devices = await _controller.service.discover();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = '扫描失败：$e';
      });
    }
  }

  /// 按 IP 直连探测（SSDP 组播被防火墙/路由卡住时的兜底通道）。
  Future<void> _probeByIp() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty || _probing) return;
    setState(() {
      _probing = true;
      _error = null;
    });
    try {
      final device = await _controller.service.probeDevice(ip);
      if (!mounted) return;
      setState(() {
        _probing = false;
        if (device == null) {
          _error = '未在 $ip 上发现可投屏服务（需电视开启 DLNA / 多屏互动）';
        } else {
          _devices = [
            device,
            ..._devices.where((d) => d.usn != device.usn),
          ];
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _probing = false;
        _error = '探测失败：$e';
      });
    }
  }

  Future<void> _cast(DlnaDevice device) async {
    if (_casting) return;
    setState(() {
      _casting = true;
      _error = null;
    });
    try {
      await _controller.cast(
        device,
        widget.spec.url,
        title: widget.spec.title,
      );
      if (!mounted) return;
      Navigator.of(context).pop(device.friendlyName);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _casting = false;
        // 展示真实失败原因（SOAP 错误码 / 连接异常），笼统提示无法定位问题。
        _error = '投屏到「${device.friendlyName}」失败：$e';
      });
    }
  }

  Future<void> _runCastAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ValueListenableBuilder(
      valueListenable: _controller.state,
      builder: (context, state, _) {
        final connected = state.connected;
        return AlertDialog(
          backgroundColor: palette.raised,
          title: Row(
            children: [
              Icon(
                connected ? Icons.cast_connected_rounded : Icons.cast_rounded,
                size: 22,
                color: connected ? palette.accentInk : palette.textTitle,
              ),
              const SizedBox(width: 8),
              Text('投屏到电视',
                  style: TextStyle(
                      fontSize: AppType.heading, color: palette.textTitle)),
              const Spacer(),
              if (!connected)
                // Tooltip 内部是 OverlayPortal；不包独立 Semantics 容器时，portal
                // 的语义锚点会落到标题行共享节点上，有无障碍客户端时产生孤儿节点
                // 导致 AXTree 每帧更新失败刷屏（同 2026-11-24 播放器 Slider 的修法）。
                Semantics(
                  container: true,
                  child: IconButton(
                    tooltip: '重新扫描',
                    onPressed: _scanning || _casting ? null : _scan,
                    icon: _scanning
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: palette.accentInk),
                          )
                        : Icon(Icons.refresh_rounded,
                            size: 20, color: palette.textSub),
                  ),
                ),
            ],
          ),
          content: SizedBox(
            width: 380,
            height: connected ? 250 : 286,
            child: Column(
              children: [
                if (connected)
                  Expanded(child: _buildConnectedPanel(palette, state))
                else
                  Expanded(child: _buildBody(palette)),
                if (!connected) ...[
                  const SizedBox(height: 12),
                  _buildIpProbeFooter(palette),
                ],
              ],
            ),
          ),
          actions: [
            if (connected)
              TextButton(
                onPressed: _busy
                    ? null
                    : () {
                        _controller.disconnect();
                        Navigator.of(context).pop();
                      },
                child: Text('断开投屏',
                    style: TextStyle(
                        color: palette.danger, fontSize: AppType.label)),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('关闭',
                  style: TextStyle(
                      color: palette.textSub, fontSize: AppType.label)),
            ),
          ],
        );
      },
    );
  }

  /// 正在投屏时的面板：显示设备 / 标题，并提供电视端播放控制。
  Widget _buildConnectedPanel(AppPalette palette, DlnaCastState castState) {
    final device = castState.device!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          child: Row(
            children: [
              Icon(Icons.tv_rounded, size: 22, color: palette.accentInk),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.friendlyName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppType.label,
                            color: palette.textMain)),
                    const SizedBox(height: 2),
                    Text(
                      (castState.title ?? castState.url ?? '').isEmpty
                          ? '已推送当前画面'
                          : (castState.title ?? castState.url!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppType.caption, color: palette.textSub)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _runCastAction(() => castState.paused
                        ? _controller.play()
                        : _controller.pause()),
                icon: Icon(
                    castState.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    size: 18),
                label: Text(castState.paused ? '继续' : '暂停'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _runCastAction(_controller.stop),
                icon: const Icon(Icons.stop_rounded, size: 18),
                label: const Text('停止'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('换集 / 换线时会自动把新地址推送到这台设备。',
            style: TextStyle(fontSize: AppType.caption, color: palette.textSub)),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              style: TextStyle(fontSize: AppType.caption, color: palette.danger)),
        ],
      ],
    );
  }

  /// 底部「按 IP 查找」页脚卡片：电视不响应组播扫描时手动输入 IP 直连探测。
  ///
  /// 与设备卡片同款的 panel 底 + 圆角，视觉上作为独立区块贴底；
  /// 提示语、输入框、按钮紧凑成组，避免散开漂浮。
  Widget _buildIpProbeFooter(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('找不到设备？手动输入电视 IP 直连查找',
              style: TextStyle(
                  fontSize: AppType.caption, color: palette.textSub)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _ipController,
                    enabled: !_probing,
                    style: TextStyle(
                        fontSize: AppType.caption, color: palette.textMain),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '如 192.168.6.155',
                      hintStyle: TextStyle(
                          fontSize: AppType.caption, color: palette.textSub),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      filled: true,
                      fillColor: palette.raised,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                        borderSide: BorderSide(color: palette.borderStrong),
                      ),
                    ),
                    onSubmitted: (_) => _probeByIp(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _probing ? null : _probeByIp,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                ),
                child: _probing
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: palette.accentInk))
                    : Text('查找',
                        style: TextStyle(
                            fontSize: AppType.caption,
                            color: palette.accentInk)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppPalette palette) {
    if (_scanning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: palette.accentInk),
            const SizedBox(height: 12),
            Text('正在扫描局域网内的 DLNA 设备…',
                style: TextStyle(
                    fontSize: AppType.body, color: palette.textSub)),
          ],
        ),
      );
    }
    if (_error != null && _devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 32, color: palette.textSub),
            const SizedBox(height: 8),
            Text(_error!,
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: AppType.body, color: palette.textSub)),
          ],
        ),
      );
    }
    if (_devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tv_off_rounded, size: 32, color: palette.textSub),
            const SizedBox(height: 8),
            Text(
              '未发现可投屏设备\n请确认电视 / 盒子已开启 DLNA，并与电脑在同一局域网',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: AppType.body, color: palette.textSub),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.spec.headers != null && widget.spec.headers!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 15, color: palette.accentInk),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '该地址带鉴权请求头，电视可能无法直接播放。',
                    style: TextStyle(
                        fontSize: AppType.caption, color: palette.textSub),
                  ),
                ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!,
                style: TextStyle(
                    fontSize: AppType.caption, color: palette.danger)),
          ),
        Expanded(
          child: ListView.separated(
            itemCount: _devices.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final device = _devices[index];
              final busy = _casting;
              return Material(
                color: palette.panel,
                borderRadius: BorderRadius.circular(AppRadii.md),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  onTap: busy ? null : () => _cast(device),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Icon(Icons.tv_rounded,
                            size: 20, color: palette.accentInk),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(device.friendlyName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: AppType.label,
                                      color: palette.textMain)),
                              Text(device.host,
                                  style: TextStyle(
                                      fontSize: AppType.caption,
                                      color: palette.textSub)),
                            ],
                          ),
                        ),
                        if (busy)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: palette.accentInk),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
