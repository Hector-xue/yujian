import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:persona/persona.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/persona_avatar.dart';
import 'persona_editor_page.dart';

/// 人格与角色：选人格（点了就生效）、换头像、新建 / 编辑自定义角色、导入人格包、它记住的事。
class PersonaPage extends StatefulWidget {
  const PersonaPage({super.key});
  @override
  State<PersonaPage> createState() => _PersonaPageState();
}

class _PersonaPageState extends State<PersonaPage> {
  late String personaId;
  var memoryExpanded = false;

  @override
  void initState() {
    super.initState();
    personaId = AppScope.of(context).settings.personaId;
  }

  Future<void> _select(String id) async {
    setState(() => personaId = id);
    final app = AppScope.of(context);
    await app.saveSettings(app.settings.copyWith(personaId: id)); // 点了就生效，不用另按保存
  }

  /// 新建 / 编辑自定义角色；没有 profile 的（手写 JSON 导入）给删除选项。
  Future<void> _editPersona(BuildContext context, Map<String, Object?>? pack) async {
    final app = AppScope.of(context);
    if (pack != null && PersonaProfile.fromPack(pack) == null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('${pack['name']}'),
          content: const Text('这是导入的人格包，没有可编辑的表单；要删掉它吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('删除')),
          ],
        ),
      );
      if (ok == true) {
        await app.removeCustomPersona(pack['id'] as String);
        if (mounted) setState(() => personaId = app.settings.personaId);
      }
      return;
    }
    if (!context.mounted) return;
    final id = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => PersonaEditorPage(initial: pack == null ? null : PersonaProfile.fromPack(pack))));
    if (!mounted) return;
    setState(() => personaId = id ?? app.settings.personaId);
  }

  /// 点头像：换图 / 恢复默认。内置人格也能换。
  Future<void> _avatarSheet(BuildContext context, PersonaPack p) async {
    final app = AppScope.of(context);
    final has = app.settings.personaAvatars.containsKey(p.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: PersonaAvatar(p, size: 40), title: Text('${p.name} 的头像')),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('从相册选'), onTap: () => Navigator.pop(ctx, 'pick')),
          if (has) ListTile(leading: const Icon(Icons.restart_alt), title: const Text('恢复默认表情'), onTap: () => Navigator.pop(ctx, 'clear')),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'clear') {
      await app.setPersonaAvatar(p.id, null);
    } else {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 88);
      if (x == null) return;
      await app.setPersonaAvatar(p.id, await x.readAsBytes(), ext: x.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg');
    }
    if (mounted) setState(() {});
  }

  Future<void> _importPersona(BuildContext context) async {
    final app = AppScope.of(context);
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('人格包 JSON'),
        content: TextField(
            controller: ctl, maxLines: 8, decoration: const InputDecoration(hintText: '{"id":"my","name":"…","tagline":"…","style":"风格描述","templates":{"greeting":"…","recorded":"已记 {n} 笔"}}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('导入')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final j = (jsonDecode(ctl.text) as Map).cast<String, Object?>();
      final pack = PersonaPack.fromJson(j);
      if (pack.id.isEmpty || builtinPersonas.any((b) => b.id == pack.id)) throw const FormatException('id 不能为空或与内置重名');
      final missing = corePersonaEvents.where((e) => !pack.templates.containsKey(e.name)).map((e) => e.name).toList();
      if (missing.isNotEmpty) throw FormatException('templates 缺 ${missing.join('、')}');
      await app.upsertCustomPersona(j);
      if (mounted) setState(() => personaId = pack.id);
    } catch (e) {
      final msg = e is FormatException ? e.message : '$e';
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('人格包不合法：$msg')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('人格与角色')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text('只改语气。金额、时间、余额、确认流程它碰不到。点头像可以换成自己的图片；自定义角色点右侧铅笔改设定。选了就生效。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          // 角色列表一张卡（同质的一串行）；下面的按钮留在卡外
          GlassCard(
            child: RadioGroup<String>(
            groupValue: personaId,
            onChanged: (v) => v == null ? null : _select(v),
            child: Column(
              children: [
                for (final p in [...builtinPersonas, for (final c in app.settings.customPersonas) PersonaPack.fromJson(c)])
                  RadioListTile<String>(
                    value: p.id,
                    contentPadding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
                    // RadioListTile 只有 secondary 一个槽：头像 + （自定义的）编辑铅笔并排放
                    secondary: Row(mainAxisSize: MainAxisSize.min, children: [
                      InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _avatarSheet(context, p),
                        child: PersonaAvatar(p, size: 48),
                      ),
                      if (!builtinPersonas.any((b) => b.id == p.id))
                        IconButton(
                          tooltip: '编辑',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _editPersona(context, app.settings.customPersonaById(p.id)!),
                        ),
                    ]),
                    title: Text(p.name),
                    subtitle: Text('${p.tagline} · "${p.templates['recorded']?.replaceAll('{n}', '1') ?? ''}"', style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
            ),
          ),
          Wrap(children: [
            TextButton.icon(onPressed: () => _editPersona(context, null), icon: const Icon(Icons.person_add_alt_1_outlined, size: 18), label: const Text('新建角色')),
            TextButton.icon(onPressed: () => _importPersona(context), icon: const Icon(Icons.data_object, size: 18), label: const Text('导入人格包（JSON）')),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: Text('它记住的事', style: theme.textTheme.titleMedium)),
            if (app.memory.items.isNotEmpty)
              TextButton(
                  onPressed: () async {
                    await app.memory.clear();
                    if (mounted) setState(() {});
                  },
                  child: const Text('全部忘掉')),
          ]),
          const SizedBox(height: 4),
          Text('聊天里你主动说过的、关于你自己的事（称呼、习惯、家人宠物、目标）。只存本机，会带进之后的对话；不想让它记的点 × 删掉。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          if (app.memory.items.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(app.companion == null ? '配好模型后，聊着聊着它就会记住你。' : '还没记住什么，去对话里聊聊。', style: theme.textTheme.bodySmall))
          else
            // 一张卡、默认露 8 条（上限 60 条，全铺开要滑很久）
            GlassCard(
              child: Column(children: [
                for (final m in app.memory.items.reversed.take(memoryExpanded ? app.memory.items.length : 8))
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                    dense: true,
                    title: Text(m.text),
                    subtitle: m.atMs == 0 ? null : Text(DateTime.fromMillisecondsSinceEpoch(m.atMs).toIso8601String().substring(0, 10), style: theme.textTheme.bodySmall),
                    trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () async {
                          await app.memory.remove(m.text);
                          if (mounted) setState(() {});
                        }),
                  ),
                if (app.memory.items.length > 8)
                  Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.fromLTRB(8, 0, 0, 4), child: TextButton(onPressed: () => setState(() => memoryExpanded = !memoryExpanded), child: Text(memoryExpanded ? '收起' : '展开全部 ${app.memory.items.length} 条')))),
              ]),
            ),
        ],
      ),
    );
  }
}
