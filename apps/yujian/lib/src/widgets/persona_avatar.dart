import 'package:flutter/material.dart';
import 'package:persona/persona.dart';

import '../app_state.dart';
import '../platform/avatar_files_native.dart' if (dart.library.js_interop) '../platform/avatar_files_web.dart';

/// 人格头像：用户给这个人格换过图就显示图（圆形裁切），否则主题色底 + emoji。
/// [imagePath] 不传时从设置里按人格 id 取；传空串 = 强制 emoji（编辑页预览用）。
class PersonaAvatar extends StatelessWidget {
  final PersonaPack persona;
  final double size;
  final String? imagePath;
  const PersonaAvatar(this.persona, {super.key, this.size = 40, this.imagePath});

  @override
  Widget build(BuildContext context) {
    final accent = Color(0xFF000000 | persona.accent);
    final path = imagePath ?? AppScope.maybeOf(context)?.settings.personaAvatars[persona.id];
    final img = path == null || path.isEmpty ? null : avatarImage(path, size);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), shape: BoxShape.circle, border: Border.all(color: accent.withValues(alpha: 0.35), width: 0.8)),
      child: img ?? Text(persona.emoji, style: TextStyle(fontSize: size * 0.52, height: 1, color: accent)),
    );
  }
}
