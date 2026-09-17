import 'package:flutter/material.dart';
import 'package:persona/persona.dart';

/// 人格头像：主题色底 + emoji。
class PersonaAvatar extends StatelessWidget {
  final PersonaPack persona;
  final double size;
  const PersonaAvatar(this.persona, {super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final accent = Color(0xFF000000 | persona.accent);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), shape: BoxShape.circle, border: Border.all(color: accent.withValues(alpha: 0.35), width: 0.8)),
      child: Text(persona.emoji, style: TextStyle(fontSize: size * 0.5, height: 1, color: accent)),
    );
  }
}
