import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'updater.dart';

/// 新版本提示：Android 直接下载安装；其他平台给下载页。
Future<void> showUpdateSheet(BuildContext context, ReleaseInfo r, {VoidCallback? onSkip}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _UpdateSheet(release: r, onSkip: onSkip),
  );
}

class _UpdateSheet extends StatefulWidget {
  final ReleaseInfo release;
  final VoidCallback? onSkip;
  const _UpdateSheet({required this.release, this.onSkip});
  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  double? progress;
  String? error;

  Future<void> _install() async {
    setState(() {
      progress = 0;
      error = null;
    });
    try {
      await Updater.downloadAndInstall(widget.release, (p) {
        if (mounted) setState(() => progress = p);
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          progress = null;
          error = '下载失败：$e';
        });
      }
    }
  }

  Future<void> _open(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) {
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(const SnackBar(content: Text('打不开浏览器，链接已复制')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.release;
    final direct = r.downloadForThisPlatform;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('新版本 ${r.version}', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (r.notes.trim().isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(child: Text(r.notes.trim(), style: theme.textTheme.bodyMedium)),
              ),
            const SizedBox(height: 16),
            if (progress != null) ...[
              LinearProgressIndicator(value: progress == 0 ? null : progress),
              const SizedBox(height: 6),
              Text(progress == 0 ? '连接中…' : '下载中 ${(progress! * 100).toStringAsFixed(0)}%', style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(error!, style: theme.textTheme.bodySmall)),
            Row(
              children: [
                if (widget.onSkip != null)
                  TextButton(
                      onPressed: progress != null
                          ? null
                          : () {
                              widget.onSkip!();
                              Navigator.pop(context);
                            },
                      child: const Text('跳过这版')),
                const Spacer(),
                TextButton(onPressed: progress != null ? null : () => _open(r.page), child: const Text('去官网')),
                const SizedBox(width: 8),
                if (Updater.canInstallInApp && r.androidArm64 != null)
                  FilledButton.icon(onPressed: progress != null ? null : _install, icon: const Icon(Icons.system_update_alt, size: 18), label: const Text('下载并安装'))
                else if (direct != null)
                  FilledButton.icon(onPressed: () => _open(direct), icon: const Icon(Icons.download, size: 18), label: const Text('下载'))
                else
                  FilledButton(onPressed: () => _open(r.page), child: const Text('打开下载页')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
