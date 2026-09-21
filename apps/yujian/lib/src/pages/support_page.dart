import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../support/support_config.dart';
import '../support/support_gallery_native.dart' if (dart.library.js_interop) '../support/support_gallery_web.dart';
import '../theme.dart';

/// 支持余见：¥1，自觉制。付款走支付宝一键拉起 / 微信存码去扫；「我已支持」一点永久关；
/// 开着支付页识别或通知记账的，付完自动认出来。整页不联网。
class SupportPage extends StatefulWidget {
  const SupportPage({super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  bool _busy = false;

  bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final since = app.ledger.profile.supporterSince;
        final supporter = since != null;
        return Scaffold(
          appBar: AppBar(title: const Text('支持余见')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                      Text('¥1', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
                      const SizedBox(width: 10),
                      Text('一杯白开水的钱', style: theme.textTheme.bodyMedium?.copyWith(color: y.muted)),
                    ]),
                    const SizedBox(height: 12),
                    Text(
                      supporter ? '你在 $since 支持过余见。谢谢。' : '余见是一个人写的：开源、无广告、账本不出手机。\n付一块钱，「支持余见」那条提醒永久关掉；不付也一样用，功能不差一分。',
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              if (SupportConfig.configured) ...[
                if (_isAndroid) ...[
                  if (SupportConfig.hasAlipay)
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _alipay,
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('支付宝 · 一键打开'),
                    ),
                  if (SupportConfig.hasAlipay && SupportConfig.hasWechat) const SizedBox(height: 8),
                  if (SupportConfig.hasWechat)
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _wechat,
                      icon: const Icon(Icons.qr_code_2, size: 18),
                      label: const Text('微信 · 存码去扫'),
                    ),
                ] else
                  GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Wrap(spacing: 20, runSpacing: 12, alignment: WrapAlignment.center, children: [
                        if (SupportConfig.hasAlipay) _QrTile(data: SupportConfig.alipayQr, caption: '手机支付宝扫'),
                        if (SupportConfig.hasWechat) _QrTile(data: SupportConfig.wechatQr, caption: '手机微信扫'),
                      ]),
                    ),
                  ),
                const SizedBox(height: 14),
              ],
              if (!supporter) ...[
                FilledButton(
                  onPressed: _busy ? null : _confirmSupported,
                  child: const Text('我已支持，永久关闭'),
                ),
                if (app.supportPromptVisible)
                  TextButton(
                    onPressed: () {
                      app.snoozeSupport();
                      Navigator.of(context).pop();
                    },
                    child: Text('先不了，${SupportConfig.snoozeDays} 天后再说'),
                  ),
              ],
              const SizedBox(height: 10),
              Text(
                '这一页不联网、不上报。开着「支付页识别」或「通知自动记账」的，付完 ¥1 会自动认出来并关掉提醒，不用再点。',
                style: theme.textTheme.bodySmall?.copyWith(color: y.muted, height: 1.5),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmSupported() async {
    final app = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('谢谢'),
        content: const Text('确认后这条提醒不再出现（同步到别的设备也不提）。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('确认')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    app.markSupporter(via: 'manual');
  }

  /// 支付宝：拉起到收款码的付款页；拉不起来（没装 / 被拦）就展示二维码。
  Future<void> _alipay() async {
    final app = AppScope.of(context);
    app.noteSupportPayTapped();
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await launchUrl(SupportConfig.alipayLaunchUri, mode: LaunchMode.externalNonBrowserApplication);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) await _showQr(SupportConfig.alipayQr, '没能打开支付宝。用另一台手机扫这个码，或截图后在支付宝「扫一扫 → 相册」里选。');
  }

  /// 微信：把码画成图存进相册，再拉起扫一扫；存不进去（老系统）就展示二维码让人截图。
  Future<void> _wechat() async {
    final app = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    app.noteSupportPayTapped();
    setState(() => _busy = true);
    var saved = false;
    try {
      final png = await renderQrPng(SupportConfig.wechatQr, 720);
      saved = png != null && await saveImageToGallery(png, 'yujian-support-wechat.png');
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!saved) {
      await _showQr(SupportConfig.wechatQr, '截图这张码，微信「扫一扫 → 右上角相册」里选它。');
      return;
    }
    var opened = false;
    try {
      opened = await launchUrl(SupportConfig.wechatScanUri, mode: LaunchMode.externalNonBrowserApplication);
    } catch (_) {
      opened = false;
    }
    messenger.showSnackBar(SnackBar(content: Text(opened ? '收款码已存到相册，扫一扫里点右上角相册选它' : '收款码已存到相册。打开微信 → 扫一扫 → 右上角相册，选它')));
  }

  Future<void> _showQr(String data, String hint) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _QrTile(data: data, caption: null, size: 240),
          const SizedBox(height: 12),
          Text(hint, style: Theme.of(ctx).textTheme.bodySmall, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

/// 白底的二维码（微信 / 支付宝扫码要有安静区，透明底在深色主题下扫不出来）。
class _QrTile extends StatelessWidget {
  final String data;
  final String? caption;
  final double size;
  const _QrTile({required this.data, required this.caption, this.size = 168});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: QrImageView(data: data, version: QrVersions.auto, size: size, backgroundColor: Colors.white, eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black), dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black)),
      ),
      if (caption != null) ...[
        const SizedBox(height: 6),
        Text(caption!, style: theme.textTheme.bodySmall),
      ],
    ]);
  }
}

/// 把二维码画成白底 PNG（带安静区），存相册用。画不出来返回 null。
Future<Uint8List?> renderQrPng(String data, int size) async {
  final validation = QrValidator.validate(data: data, version: QrVersions.auto, errorCorrectionLevel: QrErrorCorrectLevel.M);
  final code = validation.qrCode;
  if (validation.status != QrValidationStatus.valid || code == null) return null;
  final painter = QrPainter.withQr(qr: code, gapless: true, eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black), dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black));
  final quiet = size / 12;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final total = size + quiet * 2;
  canvas.drawRect(Rect.fromLTWH(0, 0, total, total), Paint()..color = Colors.white);
  canvas.translate(quiet, quiet);
  painter.paint(canvas, Size(size.toDouble(), size.toDouble()));
  final image = await recorder.endRecording().toImage(total.round(), total.round());
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
