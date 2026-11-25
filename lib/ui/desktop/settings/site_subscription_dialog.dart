import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../../../core/settings/models/site_subscription.dart';

/// 站源订阅录入 / 编辑弹窗：填写远程配置链接 + 展示名 + 自动刷新间隔。
class SiteSubscriptionDialog extends StatefulWidget {
  /// 传入则进入编辑模式（回填字段），否则为新建。
  final SiteSubscription? initial;

  const SiteSubscriptionDialog({super.key, this.initial});

  /// 返回 null 表示取消；否则返回填好的订阅对象（编辑模式保留原 id）。
  static Future<SiteSubscription?> show(
    BuildContext context, {
    SiteSubscription? initial,
  }) =>
      showDialog<SiteSubscription>(
        context: context,
        builder: (_) => SiteSubscriptionDialog(initial: initial),
      );

  @override
  State<SiteSubscriptionDialog> createState() => _SiteSubscriptionDialogState();
}

class _SiteSubscriptionDialogState extends State<SiteSubscriptionDialog> {
  late final TextEditingController _urlController =
      TextEditingController(text: widget.initial?.url ?? '');
  late final TextEditingController _nameController =
      TextEditingController(text: widget.initial?.name ?? '');

  /// 下拉候选：30 分钟 ~ 7 天。
  static const List<(int, String)> _intervalChoices = [
    (30, '30 分钟'),
    (60, '1 小时'),
    (360, '6 小时'),
    (720, '12 小时'),
    (1440, '每天'),
    (4320, '每 3 天'),
    (10080, '每周'),
  ];

  late int _interval = widget.initial?.refreshIntervalMinutes ?? 360;

  bool get _isEditing => widget.initial != null;

  bool get _canSubmit =>
      _urlController.text.trim().startsWith(RegExp('http://|https://'));

  @override
  void initState() {
    super.initState();
    // 自定义间隔不在候选里时补一个动态项
    if (!_intervalChoices.any((c) => c.$1 == _interval)) {
      _interval = 360;
    }
    _urlController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _urlController.text.trim();
    if (!url.startsWith(RegExp('http://|https://'))) return;
    final name = _nameController.text.trim();
    if (_isEditing) {
      Navigator.of(context).pop(widget.initial!.copyWith(
        url: url,
        name: name.isEmpty ? url : name,
        refreshIntervalMinutes: _interval,
      ));
    } else {
      Navigator.of(context).pop(SiteSubscription.create(
        url: url,
        name: name,
        refreshIntervalMinutes: _interval,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      backgroundColor: palette.raised,
      title: Text(_isEditing ? '编辑站源订阅' : '添加站源订阅',
          style: TextStyle(
              fontSize: AppType.heading, color: palette.textTitle)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('订阅链接（远程配置 JSON，拉取后与当前配置的站源合并）',
                style: TextStyle(
                    fontSize: AppType.caption, color: palette.textSub)),
            const SizedBox(height: 6),
            TextField(
              controller: _urlController,
              autofocus: !_isEditing,
              style: TextStyle(fontSize: AppType.label, color: palette.textMain),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'https://example.com/sources.json',
                hintStyle: TextStyle(
                    fontSize: AppType.label, color: palette.textSub),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _canSubmit ? _submit() : null,
            ),
            const SizedBox(height: 14),
            Text('展示名（可留空，默认取链接）',
                style: TextStyle(
                    fontSize: AppType.caption, color: palette.textSub)),
            const SizedBox(height: 6),
            TextField(
              controller: _nameController,
              style: TextStyle(fontSize: AppType.label, color: palette.textMain),
              decoration: InputDecoration(
                isDense: true,
                hintText: '例如：社区共享源',
                hintStyle: TextStyle(
                    fontSize: AppType.label, color: palette.textSub),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _canSubmit ? _submit() : null,
            ),
            const SizedBox(height: 14),
            Text('自动刷新间隔（启动时检查，到期才拉取）',
                style: TextStyle(
                    fontSize: AppType.caption, color: palette.textSub)),
            const SizedBox(height: 6),
            DropdownButton<int>(
              value: _interval,
              isExpanded: true,
              dropdownColor: palette.raised,
              style: TextStyle(
                  fontSize: AppType.label, color: palette.textMain),
              items: [
                for (final (minutes, label) in _intervalChoices)
                  DropdownMenuItem(value: minutes, child: Text(label)),
              ],
              onChanged: (value) =>
                  setState(() => _interval = value ?? _interval),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(_isEditing ? '保存' : '添加',
              style: TextStyle(
                  color: _canSubmit ? palette.accent : palette.textSub)),
        ),
      ],
    );
  }
}
