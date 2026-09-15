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
  final String? visionModel; // 空 = 用 model
  final String? syncUrl;
  final String? syncToken;
  final String? backupPassphrase;
  const Settings({this.baseUrl, this.model, this.apiKey, this.personaId = 'minimalist', this.automationMode = AutomationMode.confirm, this.notificationsWanted = false, this.visionModel, this.syncUrl, this.syncToken, this.backupPassphrase});

  bool get syncConfigured => (syncUrl ?? '').isNotEmpty && (syncToken ?? '').isNotEmpty;

  ProviderConfig? get providerConfig {
    if (baseUrl == null || baseUrl!.isEmpty || model == null || model!.isEmpty) return null;
    final extra = <String, Object?>{if (baseUrl!.contains('openrouter.ai')) 'reasoning': {'enabled': false}};
    return ProviderConfig(name: 'user', type: ProviderType.openaiCompat, baseUrl: baseUrl!, apiKey: apiKey, model: model!, extraBody: extra, visionModel: (visionModel ?? '').isEmpty ? null : visionModel);
  }

  Settings copyWith({String? baseUrl, String? model, String? apiKey, String? personaId, AutomationMode? automationMode, bool? notificationsWanted, String? visionModel, String? syncUrl, String? syncToken, String? backupPassphrase}) => Settings(
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
        personaId: personaId ?? this.personaId,
        automationMode: automationMode ?? this.automationMode,
        notificationsWanted: notificationsWanted ?? this.notificationsWanted,
        visionModel: visionModel ?? this.visionModel,
        syncUrl: syncUrl ?? this.syncUrl,
        syncToken: syncToken ?? this.syncToken,
        backupPassphrase: backupPassphrase ?? this.backupPassphrase,
      );
}

abstract class SettingsStore {
  Future<Settings> load();
  Future<void> save(Settings s);
}

class PlatformSettingsStore implements SettingsStore {
  static const _secure = FlutterSecureStorage();

  @override
  Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    String? key;
    String? syncToken;
    String? passphrase;
    try {
      key = await _secure.read(key: 'llm_api_key');
      syncToken = await _secure.read(key: 'sync_token');
      passphrase = await _secure.read(key: 'backup_passphrase');
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
      visionModel: p.getString('llm_vision_model'),
      syncUrl: p.getString('sync_url'),
      syncToken: syncToken,
      backupPassphrase: passphrase,
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
    await p.setString('llm_vision_model', s.visionModel ?? '');
    await p.setString('sync_url', s.syncUrl ?? '');
    try {
      for (final e in {'llm_api_key': s.apiKey, 'sync_token': s.syncToken, 'backup_passphrase': s.backupPassphrase}.entries) {
        if (e.value == null || e.value!.isEmpty) {
          await _secure.delete(key: e.key);
        } else {
          await _secure.write(key: e.key, value: e.value);
        }
      }
    } catch (_) {}
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
