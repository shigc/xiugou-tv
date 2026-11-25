import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/diagnostics/app_logger.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/app_message.dart';

/// 日志页（设置 → 日志）：分级查看应用日志。
///
/// 两个数据源：本次运行（内存环形缓冲，实时刷新）与 `app.log`（落盘文件，
/// 含上一份滚动备份）。两处都支持按级别筛选；高级别用醒目色标出来。
class LogPanel extends StatefulWidget {
  final AppLogger log;

  const LogPanel({super.key, required this.log});

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  AppLogLevel? _levelFilter;
  bool _fileMode = false;
  List<AppLogEntry> _fileEntries = const [];

  List<AppLogEntry> get _visibleEntries {
    final source = _fileMode ? _fileEntries : widget.log.entries;
    final filtered = _levelFilter == null
        ? source
        : source.where((e) => e.level == _levelFilter!);
    return filtered.toList().reversed.toList(); // 新的在上
  }

  void _loadFile() {
    setState(() => _fileEntries = widget.log.readFile());
  }

  Future<void> _openFile() async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [widget.log.path]);
      }
    } catch (error) {
      showAppMessage('无法打开日志文件：$error', type: AppMessageType.error);
    }
  }

  Future<void> _copyAll(List<AppLogEntry> entries) async {
    if (entries.isEmpty) return;
    await Clipboard.setData(
        ClipboardData(text: AppLogger.formatEntries(entries.reversed)));
    if (mounted) showAppMessage('已复制 ${entries.length} 条日志', type: AppMessageType.success);
  }

  void _clear() {
    setState(() {
      if (_fileMode) {
        final ok = widget.log.clearFile();
        showAppMessage(ok ? '日志文件已清空' : '清空失败：文件可能被占用',
            type: ok ? AppMessageType.success : AppMessageType.error);
        _fileEntries = const [];
      } else {
        widget.log.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('日志',
                        style: TextStyle(
                            fontSize: AppType.h2,
                            fontWeight: FontWeight.bold,
                            color: palette.textTitle)),
                    const SizedBox(height: 4),
                    Text(
                      _fileMode
                          ? '落盘文件：${widget.log.path}（含上一份 .1 备份，最多显示 500 条）'
                          : '本次运行的分级日志，自动写入 app.log；可切换查看历史文件。',
                      style: TextStyle(fontSize: AppType.body, color: palette.textSub),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ListenableBuilder(
                listenable: widget.log,
                builder: (context, _) {
                  final entries = _visibleEntries;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('log-copy-all'),
                        onPressed: entries.isEmpty ? null : () => _copyAll(entries),
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text('复制'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('log-clear'),
                        onPressed: entries.isEmpty ? null : _clear,
                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                        label: const Text('清除'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('log-open-file'),
                        onPressed: _openFile,
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: const Text('打开文件'),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _filterDropdown(
                label: '级别',
                value: _levelFilter,
                items: [
                  const DropdownMenuItem<AppLogLevel?>(
                    key: ValueKey('log-level-all'),
                    value: null,
                    child: Text('全部级别'),
                  ),
                  ...AppLogLevel.values.map(
                    (level) => DropdownMenuItem<AppLogLevel?>(
                      key: ValueKey('log-level-${level.label}'),
                      value: level,
                      child: Text(level.label),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _levelFilter = value),
              ),
              _filterDropdown(
                label: '来源',
                value: _fileMode,
                items: const [
                  DropdownMenuItem<bool>(value: false, child: Text('本次运行')),
                  DropdownMenuItem<bool>(value: true, child: Text('日志文件')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _fileMode = value);
                  if (value) _loadFile();
                },
              ),
              TextButton.icon(
                key: const ValueKey('log-refresh'),
                onPressed: _fileMode ? _loadFile : null,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('刷新'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.log,
            builder: (context, _) {
              final entries = _visibleEntries;
              if (entries.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Text(
                      _levelFilter == null
                          ? (_fileMode ? '日志文件暂无内容' : '本次运行暂无日志')
                          : '没有 ${_levelFilter!.label} 级别的日志',
                      style: TextStyle(fontSize: AppType.label, color: palette.textSub),
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                itemCount: entries.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: palette.divider),
                itemBuilder: (context, i) => _LogEntryTile(entry: entries[i]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _filterDropdown<T>({
    required String label,
    required T? value,
    required List<DropdownMenuItem<T?>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final palette = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label：', style: TextStyle(fontSize: AppType.label, color: palette.textSub)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: palette.raised,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(color: palette.borderStrong),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T?>(
              value: value,
              isDense: true,
              items: items,
              onChanged: onChanged,
              style: TextStyle(fontSize: AppType.label, color: palette.textMain),
              dropdownColor: palette.card,
            ),
          ),
        ),
      ],
    );
  }
}

Color _levelColor(AppLogLevel level, AppPalette palette) => switch (level) {
      AppLogLevel.debug => palette.textDim,
      AppLogLevel.info => palette.accent,
      AppLogLevel.warning => palette.warning,
      AppLogLevel.error || AppLogLevel.fatal => palette.danger,
    };

class _LogEntryTile extends StatelessWidget {
  final AppLogEntry entry;

  const _LogEntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final mono = TextStyle(
      fontSize: AppType.caption,
      color: palette.textSub,
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Courier New', 'monospace'],
      height: 1.45,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(entry.timeText,
                style: TextStyle(
                    fontSize: AppType.body,
                    color: palette.textSub,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _levelColor(entry.level, palette).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadii.xs),
              ),
              child: Text(entry.level.label,
                  style: TextStyle(
                      fontSize: AppType.caption,
                      color: _levelColor(entry.level, palette))),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadii.xs),
              ),
              child: Text(entry.tag,
                  style: TextStyle(fontSize: AppType.caption, color: palette.accent)),
            ),
          ]),
          const SizedBox(height: 4),
          SelectableText(entry.message,
              style: TextStyle(fontSize: AppType.body, color: palette.textMain)),
          if (entry.detail != null)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('详情',
                    style: TextStyle(fontSize: AppType.caption, color: palette.textSub)),
                children: [
                  Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(entry.detail!, style: mono)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
