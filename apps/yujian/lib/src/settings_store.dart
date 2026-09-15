import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户设置。API Key 只进系统安全存储（Keystore / Keychain / 钥匙串 / Web Crypto），其余进普通偏好。
class Settings {
  final String? baseUrl;
  final String? model;
  final String? apiKey;
  final String personaId;
  const Settings({this.baseUrl, this.model, this.apiKey, this.personaId = 'minimalist'});

  ProviderConfig? get providerConfig {
    if (baseUrl == null || baseUrl!.isEmpty || model == null || model!.isEmpty) return null;
    final extra = <String, Object?>{if (baseUrl!.contains('openrouter.ai')) 'reasoning': {'enabled': false}};
    return ProviderConfig(name: 'user', type: ProviderType.openaiCompat, baseUrl: baseUrl!, apiKey: apiKey, model: model!, extraBody: extra);
  }

  Settings copyWith({String? baseUrl, String? model, String? apiKey, String? personaId}) =>
      Settings(baseUrl: baseUrl ?? this.baseUrl, model: model ?? this.model, apiKey: apiKey ?? this.apiKey, personaId: personaId ?? this.personaId);
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
    try {
      key = await _secure.read(key: 'llm_api_key');
    } catch (_) {
      key = null; // 安全存储不可用（如无 keyring 的桌面）：当作没配
    }
    return Settings(baseUrl: p.getString('llm_base_url'), model: p.getString('llm_model'), apiKey: key, personaId: p.getString('persona_id') ?? 'minimalist');
  }

  @override
  Future<void> save(Settings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('llm_base_url', s.baseUrl ?? '');
    await p.setString('llm_model', s.model ?? '');
    await p.setString('persona_id', s.personaId);
    try {
      if (s.apiKey == null || s.apiKey!.isEmpty) {
        await _secure.delete(key: 'llm_api_key');
      } else {
        await _secure.write(key: 'llm_api_key', value: s.apiKey);
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
