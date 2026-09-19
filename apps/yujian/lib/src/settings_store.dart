import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户设置。API Key 只进系统安全存储（Keystore / Keychain / 钥匙串 / Web Crypto），其余进普通偏好。
/// 自动记账模式（§11.4）。
enum AutomationMode { confirm, smart, silent }

class Settings {
  final String? baseUrl;
  final String? model;
  final String? apiKey;
  final String personaId;
  final AutomationMode automationMode;
  final bool notificationsWanted; // 用户在余见里打开了开关（系统授权另查）
  final bool screenWanted; // 支付页识别（无障碍）开关（系统授权另查）
  final bool screenshotWanted; // 截图自动记账开关（相册权限另查）
  final String screenshotMode; // 截图怎么认：local 仅本机 OCR + 规则 / text 本地认不出时只发脱敏后的文字 / image 原图发给视觉模型
  final String? visionModel; // 空 = 用 model
  final String? syncUrl;
  final String? syncToken;
  final String? backupPassphrase;
  final List<Map<String, Object?>> userTemplates; // 用户通知模板（notification_templates JSON）
  final List<Map<String, Object?>> customPersonas; // 自定义人格包 JSON（表单建的带 profile，导入的没有）
  final Map<String, String> personaAvatars; // 人格 id → 自定义头像文件路径（本机）
  final String providerType; // openai | anthropic
  final bool localOnly; // 仅本地模型：端点不在本机/内网就不调
  final bool redact; // 发送前脱敏
  final String? assistantName; // 对话页显示名，空 = 人格名
  final String themeId; // 外观主题
  final String? transcribeModel; // 语音转写模型（/audio/transcriptions），空 = 不用云转写
  final String? speechModel; // 语音合成模型（/audio/speech），空 = 用系统 TTS
  final String? speechVoice; // 音色名，各服务不同（alloy / anna / …）
  final String? speechStyle; // 语气说明，只有 gpt-4o-mini-tts 这类认；空不发
  final String speechEngine; // 朗读用哪个：system | cloud | doubao | minimax | omni（0.8.7 起没有 offline 了，读到就当 system）
  final String? doubaoApiKey; // 豆包语音（火山引擎新控制台的 API Key，安全存储）
  final String? doubaoAppId; // 老账号：App ID + Access Key
  final String? doubaoAccessKey;
  final String doubaoVoice; // voice_type
  final String? minimaxApiKey;
  final String? minimaxGroupId;
  final String minimaxVoice; // voice_id
  final String minimaxModel;
  final String omniVoice; // 多模态模型自带语音的音色（Qwen-Omni：Cherry / Serena / Ethan / Chelsie）
  final String? backgroundImage; // 自定义全局背景图路径（本机）；空 = 用主题自己的背景
  final double backgroundOpacity; // 背景图可见度 0–1
  const Settings({this.baseUrl, this.model, this.apiKey, this.personaId = 'minimalist', this.automationMode = AutomationMode.confirm, this.notificationsWanted = false, this.screenWanted = false, this.screenshotWanted = false, this.screenshotMode = 'local', this.visionModel, this.syncUrl, this.syncToken, this.backupPassphrase, this.userTemplates = const [], this.customPersonas = const [], this.personaAvatars = const {}, this.providerType = 'openai', this.localOnly = false, this.redact = true, this.assistantName, this.themeId = 'glass', this.transcribeModel, this.speechModel, this.speechVoice, this.speechStyle, this.speechEngine = 'system', this.backgroundImage, this.backgroundOpacity = 0.6, this.doubaoApiKey, this.doubaoAppId, this.doubaoAccessKey, this.doubaoVoice = 'zh_female_vv_uranus_bigtts', this.minimaxApiKey, this.minimaxGroupId, this.minimaxVoice = 'female-shaonv', this.minimaxModel = 'speech-02-hd', this.omniVoice = 'Cherry'});

  /// 找某个 id 的自定义人格包；没有返回 null。
  Map<String, Object?>? customPersonaById(String id) {
    for (final c in customPersonas) {
      if (c['id'] == id) return c;
    }
    return null;
  }

  DoubaoTtsConfig get doubaoTts => DoubaoTtsConfig(apiKey: doubaoApiKey, appId: doubaoAppId, accessKey: doubaoAccessKey, voice: doubaoVoice);
  MiniMaxTtsConfig get minimaxTts => MiniMaxTtsConfig(apiKey: minimaxApiKey ?? '', groupId: minimaxGroupId, model: minimaxModel, voice: minimaxVoice);

  bool get syncConfigured => (syncUrl ?? '').isNotEmpty && (syncToken ?? '').isNotEmpty;

  ProviderConfig? get providerConfig {
    if (baseUrl == null || baseUrl!.isEmpty || model == null || model!.isEmpty) return null;
    final extra = <String, Object?>{if (baseUrl!.contains('openrouter.ai')) 'reasoning': {'enabled': false}};
    if (localOnly && !isLocalEndpoint(baseUrl!)) return null; // 开了"仅本地"但端点在云上：当作没配
    return ProviderConfig(name: 'user', type: providerType == 'anthropic' ? ProviderType.anthropic : ProviderType.openaiCompat, baseUrl: baseUrl!, apiKey: apiKey, model: model!, extraBody: extra, visionModel: (visionModel ?? '').isEmpty ? null : visionModel);
  }

  Settings copyWith({String? baseUrl, String? model, String? apiKey, String? personaId, AutomationMode? automationMode, bool? notificationsWanted, bool? screenWanted, bool? screenshotWanted, String? screenshotMode, String? visionModel, String? syncUrl, String? syncToken, String? backupPassphrase, List<Map<String, Object?>>? userTemplates, List<Map<String, Object?>>? customPersonas, Map<String, String>? personaAvatars, String? providerType, bool? localOnly, bool? redact, String? assistantName, String? themeId, String? transcribeModel, String? speechModel, String? speechVoice, String? speechStyle, String? speechEngine, String? backgroundImage, double? backgroundOpacity, String? doubaoApiKey, String? doubaoAppId, String? doubaoAccessKey, String? doubaoVoice, String? minimaxApiKey, String? minimaxGroupId, String? minimaxVoice, String? minimaxModel, String? omniVoice}) => Settings(
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
        personaId: personaId ?? this.personaId,
        automationMode: automationMode ?? this.automationMode,
        notificationsWanted: notificationsWanted ?? this.notificationsWanted,
        screenWanted: screenWanted ?? this.screenWanted,
        screenshotWanted: screenshotWanted ?? this.screenshotWanted,
        screenshotMode: screenshotMode ?? this.screenshotMode,
        visionModel: visionModel ?? this.visionModel,
        syncUrl: syncUrl ?? this.syncUrl,
        syncToken: syncToken ?? this.syncToken,
        backupPassphrase: backupPassphrase ?? this.backupPassphrase,
        userTemplates: userTemplates ?? this.userTemplates,
        customPersonas: customPersonas ?? this.customPersonas,
        personaAvatars: personaAvatars ?? this.personaAvatars,
        providerType: providerType ?? this.providerType,
        localOnly: localOnly ?? this.localOnly,
        redact: redact ?? this.redact,
        assistantName: assistantName ?? this.assistantName,
        themeId: themeId ?? this.themeId,
        transcribeModel: transcribeModel ?? this.transcribeModel,
        speechModel: speechModel ?? this.speechModel,
        speechVoice: speechVoice ?? this.speechVoice,
        speechStyle: speechStyle ?? this.speechStyle,
        speechEngine: speechEngine ?? this.speechEngine,
        backgroundImage: backgroundImage ?? this.backgroundImage,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        doubaoApiKey: doubaoApiKey ?? this.doubaoApiKey,
        doubaoAppId: doubaoAppId ?? this.doubaoAppId,
        doubaoAccessKey: doubaoAccessKey ?? this.doubaoAccessKey,
        doubaoVoice: doubaoVoice ?? this.doubaoVoice,
        minimaxApiKey: minimaxApiKey ?? this.minimaxApiKey,
        minimaxGroupId: minimaxGroupId ?? this.minimaxGroupId,
        minimaxVoice: minimaxVoice ?? this.minimaxVoice,
        minimaxModel: minimaxModel ?? this.minimaxModel,
        omniVoice: omniVoice ?? this.omniVoice,
      );
}

abstract class SettingsStore {
  Future<Settings> load();
  Future<void> save(Settings s);
}

/// 0.8.7 去掉了离线语音包（Kokoro）：老设置里选的 offline 退回系统朗读，其余原样。
String _engine(String v) => v == 'offline' ? 'system' : v;

class PlatformSettingsStore implements SettingsStore {
  static const _secure = FlutterSecureStorage();

  @override
  Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    String? key;
    String? syncToken;
    String? passphrase;
    String? doubaoKey;
    String? doubaoAccess;
    String? minimaxKey;
    try {
      key = await _secure.read(key: 'llm_api_key');
      syncToken = await _secure.read(key: 'sync_token');
      passphrase = await _secure.read(key: 'backup_passphrase');
      doubaoKey = await _secure.read(key: 'doubao_api_key');
      doubaoAccess = await _secure.read(key: 'doubao_access_key');
      minimaxKey = await _secure.read(key: 'minimax_api_key');
    } catch (_) {
      key = null; // 安全存储不可用（如无 keyring 的桌面）：当作没配
    }
    return Settings(
      baseUrl: p.getString('llm_base_url'),
      model: p.getString('llm_model'),
      apiKey: key,
      personaId: p.getString('persona_id') ?? 'minimalist',
      automationMode: AutomationMode.values.asNameMap()[p.getString('automation_mode') ?? ''] ?? AutomationMode.confirm,
      notificationsWanted: p.getBool('notifications_wanted') ?? false,
      screenWanted: p.getBool('screen_wanted') ?? false,
      screenshotWanted: p.getBool('screenshot_wanted') ?? false,
      screenshotMode: p.getString('screenshot_mode') ?? 'local',
      visionModel: p.getString('llm_vision_model'),
      syncUrl: p.getString('sync_url'),
      syncToken: syncToken,
      backupPassphrase: passphrase,
      userTemplates: _jsonList(p.getString('user_templates')),
      customPersonas: _customPersonas(p),
      personaAvatars: (_jsonMap(p.getString('persona_avatars')) ?? const {}).map((k, v) => MapEntry(k, '$v')),
      providerType: p.getString('provider_type') ?? 'openai',
      localOnly: p.getBool('local_only') ?? false,
      redact: p.getBool('redact') ?? true,
      assistantName: _emptyToNull(p.getString('assistant_name')),
      themeId: p.getString('theme_id') ?? 'glass',
      transcribeModel: _emptyToNull(p.getString('transcribe_model')),
      speechModel: _emptyToNull(p.getString('speech_model')),
      speechVoice: _emptyToNull(p.getString('speech_voice')),
      speechStyle: _emptyToNull(p.getString('speech_style')),
      // 0.8.4 及之前没有这个键：那时配了云端模型就是在用云端，照旧；离线包的迁移在 AppState.loadSettings 里（要查文件）
      speechEngine: _engine(p.getString('speech_engine') ?? ((p.getString('speech_model') ?? '').isNotEmpty ? 'cloud' : 'system')),
      backgroundImage: _emptyToNull(p.getString('background_image')),
      backgroundOpacity: p.getDouble('background_opacity') ?? 0.6,
      doubaoApiKey: _emptyToNull(doubaoKey),
      doubaoAppId: _emptyToNull(p.getString('doubao_app_id')),
      doubaoAccessKey: _emptyToNull(doubaoAccess),
      doubaoVoice: _emptyToNull(p.getString('doubao_voice')) ?? 'zh_female_vv_uranus_bigtts',
      minimaxApiKey: _emptyToNull(minimaxKey),
      minimaxGroupId: _emptyToNull(p.getString('minimax_group_id')),
      minimaxVoice: _emptyToNull(p.getString('minimax_voice')) ?? 'female-shaonv',
      minimaxModel: _emptyToNull(p.getString('minimax_model')) ?? 'speech-02-hd',
      omniVoice: _emptyToNull(p.getString('omni_voice')) ?? 'Cherry',
    );
  }

  @override
  Future<void> save(Settings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('llm_base_url', s.baseUrl ?? '');
    await p.setString('llm_model', s.model ?? '');
    await p.setString('persona_id', s.personaId);
    await p.setString('automation_mode', s.automationMode.name);
    await p.setBool('notifications_wanted', s.notificationsWanted);
    await p.setBool('screen_wanted', s.screenWanted);
    await p.setBool('screenshot_wanted', s.screenshotWanted);
    await p.setString('screenshot_mode', s.screenshotMode);
    await p.setString('llm_vision_model', s.visionModel ?? '');
    await p.setString('sync_url', s.syncUrl ?? '');
    await p.setString('user_templates', jsonEncode(s.userTemplates));
    await p.setString('custom_personas', jsonEncode(s.customPersonas));
    await p.remove('custom_persona'); // 旧单个键：已并进列表，留着会在用户删掉它之后复活
    await p.setString('persona_avatars', jsonEncode(s.personaAvatars));
    await p.setString('provider_type', s.providerType);
    await p.setBool('local_only', s.localOnly);
    await p.setBool('redact', s.redact);
    await p.setString('assistant_name', s.assistantName ?? '');
    await p.setString('theme_id', s.themeId);
    await p.setString('transcribe_model', s.transcribeModel ?? '');
    await p.setString('speech_model', s.speechModel ?? '');
    await p.setString('speech_voice', s.speechVoice ?? '');
    await p.setString('speech_style', s.speechStyle ?? '');
    await p.setString('speech_engine', s.speechEngine);
    await p.setString('background_image', s.backgroundImage ?? '');
    await p.setDouble('background_opacity', s.backgroundOpacity);
    await p.setString('doubao_app_id', s.doubaoAppId ?? '');
    await p.setString('doubao_voice', s.doubaoVoice);
    await p.setString('minimax_group_id', s.minimaxGroupId ?? '');
    await p.setString('minimax_voice', s.minimaxVoice);
    await p.setString('minimax_model', s.minimaxModel);
    await p.setString('omni_voice', s.omniVoice);
    try {
      for (final e in {'llm_api_key': s.apiKey, 'sync_token': s.syncToken, 'backup_passphrase': s.backupPassphrase, 'doubao_api_key': s.doubaoApiKey, 'doubao_access_key': s.doubaoAccessKey, 'minimax_api_key': s.minimaxApiKey}.entries) {
        if (e.value == null || e.value!.isEmpty) {
          await _secure.delete(key: e.key);
        } else {
          await _secure.write(key: e.key, value: e.value);
        }
      }
    } catch (_) {}
  }
}

List<Map<String, Object?>> _jsonList(String? s) {
  if (s == null || s.isEmpty) return const [];
  try {
    return (jsonDecode(s) as List).cast<Map>().map((m) => m.cast<String, Object?>()).toList();
  } catch (_) {
    return const [];
  }
}

Map<String, Object?>? _jsonMap(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    return (jsonDecode(s) as Map).cast<String, Object?>();
  } catch (_) {
    return null;
  }
}

class MemorySettingsStore implements SettingsStore {
  Settings current;
  MemorySettingsStore([this.current = const Settings()]);
  @override
  Future<Settings> load() async => current;
  @override
  Future<void> save(Settings s) async => current = s;
}

String? _emptyToNull(String? v) => v == null || v.isEmpty ? null : v;

/// 自定义人格：新键 `custom_personas`（列表）；0.8.1 及之前只有一个 `custom_persona`，第一次读到就并进列表，下次保存时删旧键。
List<Map<String, Object?>> _customPersonas(SharedPreferences p) {
  final list = _jsonList(p.getString('custom_personas'));
  final old = _jsonMap(p.getString('custom_persona'));
  if (old != null && old['id'] is String && !list.any((c) => c['id'] == old['id'])) return [old, ...list];
  return list;
}
