/// 本地模型目录：两档 Qwen3.5（Apache-2.0，原生多模态）。文件从 ModelScope 直链拉（国内快、支持 Range 续传），
/// 备用 hf-mirror。大小是发版时核对过的字节数，下载完按它校验；改档位 / 换文件必须同步改这里。
class LocalModelFile {
  final String name;
  final int size;
  const LocalModelFile(this.name, this.size);
}

class LocalModelTier {
  final String id; // small | standard
  final String name;
  final String repo; // 例如 unsloth/Qwen3.5-0.8B-GGUF
  final LocalModelFile model;
  final LocalModelFile mmproj;
  final int approxRamMb; // 跑起来的常驻内存
  final int minTotalRamMb; // 低于这个总内存不推荐（不禁止）
  final String blurb;
  const LocalModelTier({
    required this.id,
    required this.name,
    required this.repo,
    required this.model,
    required this.mmproj,
    required this.approxRamMb,
    required this.minTotalRamMb,
    required this.blurb,
  });

  int get totalBytes => model.size + mmproj.size;
  double get totalGb => totalBytes / 1e9;
  List<LocalModelFile> get files => [model, mmproj];
}

class LocalModelCatalog {
  LocalModelCatalog._();

  static const small = LocalModelTier(
    id: 'small',
    name: 'Qwen3.5 0.8B',
    repo: 'unsloth/Qwen3.5-0.8B-GGUF',
    model: LocalModelFile('Qwen3.5-0.8B-Q4_K_M.gguf', 532517120),
    mmproj: LocalModelFile('mmproj-F16.gguf', 204987232),
    approxRamMb: 1100,
    minTotalRamMb: 4000,
    blurb: '0.74 GB。认截图、结构化够用；陪聊会憨。4 GB 内存的手机也能跑。',
  );

  static const standard = LocalModelTier(
    id: 'standard',
    name: 'Qwen3.5 2B',
    repo: 'unsloth/Qwen3.5-2B-GGUF',
    model: LocalModelFile('Qwen3.5-2B-Q4_K_M.gguf', 1280835840),
    mmproj: LocalModelFile('mmproj-F16.gguf', 668227264),
    approxRamMb: 2600,
    minTotalRamMb: 8000,
    blurb: '1.95 GB。明显更聪明，建议 8 GB 内存以上；后台只在前台服务里跑。',
  );

  /// 对照组：上一代 Qwen3-VL-2B（标准注意力）。Qwen3.5 是 Gated DeltaNet 混合架构，ARM CPU 上的算子可能还没优化好，
  /// 同一台手机跑一遍它就知道慢在模型还是慢在机器。
  static const compare = LocalModelTier(
    id: 'qwen3vl2b',
    name: 'Qwen3-VL 2B（对照）',
    repo: 'Qwen/Qwen3-VL-2B-Instruct-GGUF',
    model: LocalModelFile('Qwen3VL-2B-Instruct-Q4_K_M.gguf', 1107409952),
    mmproj: LocalModelFile('mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf', 445053216),
    approxRamMb: 2200,
    minTotalRamMb: 6000,
    blurb: '1.55 GB。老架构对照组，只为比速度。',
  );

  static const tiers = [small, standard, compare];

  static LocalModelTier? byId(String? id) {
    for (final t in tiers) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 按手机总内存推荐档位：< 6 GB 只给 0.8B；否则默认 2B。
  static LocalModelTier recommend({required int totalRamMb}) =>
      totalRamMb < 6000 ? small : standard;

  /// 下载源，按顺序试。ModelScope 国内直连；hf-mirror 兜底。
  static List<Uri> urls(LocalModelTier t, LocalModelFile f) => [
    Uri.parse(
      'https://modelscope.cn/models/${t.repo}/resolve/master/${f.name}',
    ),
    Uri.parse('https://hf-mirror.com/${t.repo}/resolve/main/${f.name}'),
  ];
}
