import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:persona/persona.dart';

import '../app_state.dart';
import '../widgets/persona_avatar.dart';

/// 自定义角色：填名字 / 性别 / 年龄 / 身份 / 性格 / 称呼 / 口头禅，存成人格包（带 profile 可再编辑）。
/// 只管"它怎么说话、长什么样"；金额、时间、确认流程它碰不到——和内置人格一样只替换提示词的风格段。
class PersonaEditorPage extends StatefulWidget {
  final PersonaProfile? initial;
  const PersonaEditorPage({super.key, this.initial});
  @override
  State<PersonaEditorPage> createState() => _PersonaEditorPageState();
}

class _PersonaEditorPageState extends State<PersonaEditorPage> {
  late final TextEditingController name = TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController age = TextEditingController(text: widget.initial?.age?.toString() ?? '');
  late final TextEditingController identity = TextEditingController(text: widget.initial?.identity ?? '');
  late final TextEditingController userCall = TextEditingController(text: widget.initial?.userCall ?? '你');
  late final TextEditingController tone = TextEditingController(text: widget.initial?.tone ?? '');
  late final TextEditingController catchphrase = TextEditingController(text: widget.initial?.catchphrase ?? '');
  late final TextEditingController extra = TextEditingController(text: widget.initial?.extra ?? '');
  late final TextEditingController customTrait = TextEditingController();
  late String gender = widget.initial?.gender ?? '';
  late List<String> traits = [...?widget.initial?.traits];
  late String emoji = widget.initial?.emoji ?? '🙂';
  late int accent = widget.initial?.accent ?? _swatches.first;
  Uint8List? pickedAvatar; // 本次选的图，保存时才落盘
  String? pickedExt;
  bool clearAvatar = false;
  bool saving = false;

  static const _swatches = [0x2F6B4F, 0xC2617A, 0x2E6DB4, 0x8A63D2, 0xB8422E, 0xD98E04, 0x1B9AAA, 0x5A5F66];
  static const _emojis = ['🙂', '😺', '🐶', '🐰', '🦊', '🐻', '🐼', '🦄', '🌸', '🌙', '⭐', '🍀', '🔥', '💎', '🎀', '🎧', '📚', '☕', '🧑‍💻', '👩‍🍳', '🧙', '🤖'];

  late final String _id = widget.initial?.id ?? 'custom_${DateTime.now().millisecondsSinceEpoch}';

  PersonaProfile _profile() => PersonaProfile(
        id: _id,
        name: name.text.trim(),
        gender: gender,
        age: int.tryParse(age.text.trim()),
        identity: identity.text.trim(),
        traits: traits,
        userCall: userCall.text.trim().isEmpty ? '你' : userCall.text.trim(),
        tone: tone.text.trim(),
        catchphrase: catchphrase.text.trim(),
        extra: extra.text.trim(),
        emoji: emoji,
        accent: accent,
      );

  Future<void> _pickAvatar() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 88);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    setState(() {
      pickedAvatar = bytes;
      pickedExt = x.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      clearAvatar = false;
    });
  }

  Future<void> _save() async {
    final app = AppScope.of(context);
    if (name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('先给它起个名字')));
      return;
    }
    setState(() => saving = true);
    final profile = _profile();
    await app.upsertCustomPersona(profile.buildPack());
    if (pickedAvatar != null) {
      await app.setPersonaAvatar(profile.id, pickedAvatar, ext: pickedExt ?? 'jpg');
    } else if (clearAvatar) {
      await app.setPersonaAvatar(profile.id, null);
    }
    if (mounted) Navigator.of(context).pop(profile.id);
  }

  Future<void> _delete() async {
    final app = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除这个角色？'),
        content: const Text('它的设定和头像会一起删掉；账本不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await app.removeCustomPersona(widget.initial!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final preview = _profile().build();
    final existingAvatar = app.settings.personaAvatars[_id];
    final previewPath = clearAvatar ? '' : existingAvatar;
    Widget field(String label, TextEditingController c, {String? hint, int maxLines = 1, TextInputType? type}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(controller: c, maxLines: maxLines, keyboardType: type, decoration: InputDecoration(labelText: label, hintText: hint, isDense: true), onChanged: (_) => setState(() {})),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? '新建角色' : '编辑角色'),
        actions: [if (widget.initial != null) IconButton(tooltip: '删除', onPressed: _delete, icon: const Icon(Icons.delete_outline))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Center(
            child: Column(children: [
              Stack(alignment: Alignment.bottomRight, children: [
                pickedAvatar != null
                    ? Container(
                        width: 96,
                        height: 96,
                        clipBehavior: Clip.antiAlias,
                        decoration: const BoxDecoration(shape: BoxShape.circle),
                        child: Image.memory(pickedAvatar!, fit: BoxFit.cover),
                      )
                    : PersonaAvatar(preview, size: 96, imagePath: previewPath),
                Material(
                  color: theme.colorScheme.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _pickAvatar,
                    child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.photo_camera_outlined, size: 18, color: Colors.white)),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 4, children: [
                TextButton(onPressed: _pickAvatar, child: const Text('从相册选头像')),
                if (pickedAvatar != null || (existingAvatar != null && !clearAvatar))
                  TextButton(
                      onPressed: () => setState(() {
                            pickedAvatar = null;
                            clearAvatar = true;
                          }),
                      child: const Text('用表情当头像')),
              ]),
            ]),
          ),
          const SizedBox(height: 8),
          field('名字', name, hint: '它叫什么'),
          Text('性别', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(spacing: 8, children: [
            for (final g in const ['女', '男', '其他', '不设'])
              ChoiceChip(label: Text(g), selected: (g == '不设' ? '' : g) == gender, onSelected: (_) => setState(() => gender = g == '不设' ? '' : g)),
          ]),
          const SizedBox(height: 12),
          field('年龄', age, hint: '不填也行', type: TextInputType.number),
          field('身份 / 设定', identity, hint: '邻家学姐、退休老会计、赛博管家……'),
          Text('性格', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final t in [...personaTraitOptions, ...traits.where((t) => !personaTraitOptions.contains(t))])
              FilterChip(label: Text(t), selected: traits.contains(t), onSelected: (v) => setState(() => v ? traits.add(t) : traits.remove(t))),
          ]),
          Row(children: [
            Expanded(child: TextField(controller: customTrait, decoration: const InputDecoration(hintText: '自己填一个性格', isDense: true))),
            TextButton(
                onPressed: () {
                  final t = customTrait.text.trim();
                  if (t.isEmpty) return;
                  setState(() {
                    if (!traits.contains(t)) traits.add(t);
                    customTrait.clear();
                  });
                },
                child: const Text('加')),
          ]),
          const SizedBox(height: 12),
          field('怎么称呼你', userCall, hint: '你 / 主人 / 老板 / 小名'),
          field('说话习惯', tone, hint: '爱用"啦"结尾、喜欢反问、说话带点古风……'),
          field('口头禅 / 句尾', catchphrase, hint: '喵～ / 哒 / 你说是不是'),
          field('其他补充', extra, hint: '想让它记住的设定，写给模型看的', maxLines: 3),
          Text('表情（没有头像图时用）', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final e in _emojis)
              ChoiceChip(label: Text(e, style: const TextStyle(fontSize: 18)), selected: e == emoji, onSelected: (_) => setState(() => emoji = e), showCheckmark: false, padding: EdgeInsets.zero),
          ]),
          const SizedBox(height: 12),
          Text('主题色（对话里的强调色跟着它）', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 10, children: [
            for (final c in _swatches)
              InkWell(
                onTap: () => setState(() => accent = c),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: Color(0xFF000000 | c), shape: BoxShape.circle, border: Border.all(color: c == accent ? theme.colorScheme.onSurface : Colors.transparent, width: 2)),
                  child: c == accent ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                ),
              ),
          ]),
          const SizedBox(height: 20),
          Text('它会这样开口', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text('"${preview.templates['greeting']}"\n"${preview.templates['recorded']?.replaceAll('{n}', '1')}"', style: theme.textTheme.bodySmall),
          const SizedBox(height: 20),
          FilledButton(onPressed: saving ? null : _save, child: Text(saving ? '保存中…' : '保存并使用')),
        ],
      ),
    );
  }
}
