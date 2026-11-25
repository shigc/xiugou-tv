import 'dart:io';

import 'package:path/path.dart' as p;

/// 内置画质增强着色器（Anime4K 风格，纯本地实现）的资源解析。
///
/// 着色器随安装包分发在 `<exe 目录>/runtime/shaders/anime4k/` 下
/// （构建脚本 `scripts/build_windows.ps1` 负责拷贝，安装包递归包含）。
/// 开发期若未随包分发（仅源码），[resolveSuperResolutionShader] 返回 null，
/// 调用方据此让该特性静默失效而不抛错。
class ShaderResources {
  static const String _shaderDir = 'runtime/shaders/anime4k';

  /// 强度档位 → 着色器文件名。如需替换为官方 Anime4K，把官方 `.glsl`
  /// 放进同一目录并修改此处映射即可。
  static const Map<String, String> strengthFiles = {
    'soft': 'xiugou_sr_soft.glsl',
    'strong': 'xiugou_sr_strong.glsl',
  };

  /// 返回指定强度的着色器绝对路径；强度未知或文件不存在时返回 null。
  static String? resolveSuperResolutionShader(String strength) {
    final fileName = strengthFiles[strength] ?? strengthFiles['strong'];
    if (fileName == null) return null;
    final dir = p.join(p.dirname(Platform.resolvedExecutable), _shaderDir);
    final file = File(p.join(dir, fileName));
    if (!file.existsSync()) return null;
    return file.path;
  }
}
