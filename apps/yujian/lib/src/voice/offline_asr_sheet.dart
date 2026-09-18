import 'package:flutter/material.dart';

import 'local_asr_native.dart' if (dart.library.js_interop) 'local_asr_web.dart';
import 'local_tts_native.dart' if (dart.library.js_interop) 'local_tts_web.dart';

/// 下载离线语音包（识别）的对话框：进度条，成功返回 true。
Future<bool> showOfflineAsrDownload(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadDialog(
      title: '离线语音包',
      desc: '中文离线识别模型（Paraformer，约 ${LocalAsr.approxMb} MB），下载一次，之后说话不联网、不看手机系统脸色。识别在本机跑，录音不上传。',
      download: LocalAsr.download,
    ),
  );
  return r ?? false;
}

/// 下载离线真人感语音包（合成）的对话框。
Future<bool> showOfflineTtsDownload(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadDialog(
      title: '离线真人感语音包',
      desc: '中文神经网络语音合成模型（Kokoro，约 ${LocalTts.approxMb} MB），下载一次。之后它说话有语气有语调，在本机合成，不联网、不花 API 钱。旧一点的手机第一句会等一两秒。',
      download: LocalTts.download,
    ),
  );
  return r ?? false;
}

class _DownloadDialog extends StatefulWidget {
  final String title;
  final String desc;
  final Future<void> Function(void Function(double)) download;
  const _DownloadDialog({required this.title, required this.desc, required this.download});
  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  double progress = 0;
  String? error;
  var started = false;

  Future<void> _go() async {
    setState(() {
      started = true;
      error = null;
    });
    try {
      await widget.download((p) {
        if (mounted) setState(() => progress = p);
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          started = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.desc, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 14),
          if (started) ...[
            LinearProgressIndicator(value: progress == 0 ? null : progress),
            const SizedBox(height: 6),
            Text('${(progress * 100).toStringAsFixed(0)}%', style: theme.textTheme.bodySmall),
          ],
          if (error != null) Text('下载失败：$error', style: theme.textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(onPressed: started ? null : () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: started ? null : _go, child: Text(error == null ? '下载' : '重试')),
      ],
    );
  }
}
