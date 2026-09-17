import 'package:flutter/material.dart';

import 'local_asr_native.dart' if (dart.library.js_interop) 'local_asr_web.dart';

/// 下载离线语音包的对话框：进度条，成功返回 true。
Future<bool> showOfflineAsrDownload(BuildContext context) async {
  final r = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => const _DownloadDialog());
  return r ?? false;
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog();
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
      await LocalAsr.download((p) {
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
      title: const Text('离线语音包'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('中文离线识别模型（Paraformer，约 ${LocalAsr.approxMb} MB），下载一次，之后说话不联网、不看手机系统脸色。识别在本机跑，录音不上传。', style: theme.textTheme.bodyMedium),
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
