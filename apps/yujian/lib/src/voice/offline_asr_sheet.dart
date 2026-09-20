import 'package:flutter/material.dart';

import '../app_state.dart';
import '../privacy/net_log.dart';
import 'local_asr_native.dart' if (dart.library.js_interop) 'local_asr_web.dart';

/// 下载离线语音包（识别）的对话框：进度条，成功返回 true。下载本身进出网记录（只下载不上传）。
Future<bool> showOfflineAsrDownload(BuildContext context) async {
  final log = AppScope.maybeOf(context)?.netLog;
  Future<void> download(void Function(double) onProgress) => log == null
      ? LocalAsr.download(onProgress)
      : log.track(() => LocalAsr.download(onProgress), kind: 'download', purpose: 'asr_model', host: hostOf(LocalAsr.baseUrl), bytes: LocalAsr.approxMb * 1024 * 1024);
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadDialog(
      title: '离线语音包',
      desc: '中文离线识别模型（Paraformer，约 ${LocalAsr.approxMb} MB），从 ${hostOf(LocalAsr.baseUrl)} 下载一次，之后说话不联网、不看手机系统脸色。识别在本机跑，录音不上传；下载只拉文件，不带任何数据。',
      download: download,
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
