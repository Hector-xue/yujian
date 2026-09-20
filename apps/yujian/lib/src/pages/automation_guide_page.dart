import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'privacy_statement_page.dart';

/// 自动记账设置教程：三条路各要什么权限、去哪开、怎么开、系统弹危险警告时该怎么理解，以及国产系统的后台保活。
/// 每一步能跳的都给按钮（系统设置页 / 无障碍页 / 应用信息页）。
class AutomationGuidePage extends StatelessWidget {
  const AutomationGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    final n = app.notifications;
    final supported = n.supported;

    Widget h(String t) => Padding(padding: const EdgeInsets.fromLTRB(0, 22, 0, 6), child: Text(t, style: theme.textTheme.titleMedium));
    Widget p(String t) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t, style: theme.textTheme.bodyMedium));
    Widget step(int i, String t, {String? sub}) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Text('$i', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: theme.textTheme.bodyMedium),
                if (sub != null) Text(sub, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ]),
            ),
          ]),
        );
    // 系统弹危险权限警告之前，先把实话说在前面
    Widget reassure(String t) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.verified_user_outlined, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(t, style: theme.textTheme.bodySmall)),
              ]),
            ),
          ),
        );
    Widget btn(String label, IconData icon, Future<void> Function() go) => TextButton.icon(onPressed: supported ? () => go() : null, icon: Icon(icon, size: 18), label: Text(label));

    return Scaffold(
      appBar: AppBar(title: const Text('自动记账设置教程')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (!supported) p('自动记账只有 Android 版有。这页在别的平台只能看。'),
          p('三条路各自独立，按需开。每条都要在手机系统里显式授权——余见自己给不了自己权限。'),
          reassure('先说清楚：余见没有任何自己的服务器，通知、屏幕、截图读到的内容全部只在这台手机上比对规则；三条路默认都不联网。整个 App 唯一会把数据发出去的地方，是你自己填的大模型（发前默认打码），而且可以一键关掉（更多 → 隐私 → 纯本地模式）。下面每一个系统警告，都是 Android 对所有申请该权限的 App 的统一措辞，不是余见特别做了什么。'),

          h('① 支付页识别（微信 / 支付宝付完款那一刻）'),
          p('要的权限：无障碍（辅助功能）。付款时 App 在前台，系统不弹通知，只有这条路能抓到「支付成功」那一页。'),
          reassure('开无障碍时系统会警告「允许余见拥有对您设备的完全控制权？可以查看和控制屏幕、执行操作」。余见的服务只在微信、支付宝、淘宝、京东、美团等名单内的 App 出现「支付成功」那一刻读一次金额和商户；不点任何按钮，不看别的 App，读到的内容不出手机。'),
          step(1, '打开手机「设置」→「无障碍」（有的叫「辅助功能」「更多设置 → 无障碍」）'),
          step(2, '找到「已下载的应用」或「更多已下载的服务」，点「余见 · 支付页识别」', sub: '小米 / HyperOS 在「无障碍 → 更多已下载的服务」；华为在「辅助功能 → 已安装的服务」；OPPO / vivo 在「其他设置 → 无障碍」'),
          step(3, '打开开关，系统弹警告，点「允许」'),
          step(4, '点不动、灰的，或提示「受限制的设置 / 为了安全已限制」？', sub: 'Android 13 起对非商店安装的 App 的限制：先到余见的应用信息页，右上角 ⋮ →「允许受限设置」，再回来开'),
          step(5, '回到余见「自动记账」页，把「支付页识别」拨开；付一笔，看「识别诊断」有没有变化', sub: '小米 / HyperOS 在 App 更新或重启后常把无障碍掐掉，掐了就去系统里关一下再开'),
          Wrap(children: [
            btn('去无障碍设置', Icons.accessibility_new, n.openScreenSettings),
            btn('应用信息页', Icons.info_outline, n.openAppInfo),
          ]),

          h('② 通知自动记账（银行 / 购物平台的到账、支付通知）'),
          p('要的权限：通知使用权（通知读取）。'),
          reassure('开的时候系统会警告「此应用将能读取所有通知，包括联系人姓名、照片和您收到的消息内容」。余见拿到通知后只做一件事：和支付类模板比对。像支付的留下（金额、方向、商户），不像的当场丢掉，不存、不发。你可以在自动记账页「教它认一种通知」看到它到底认了什么。'),
          step(1, '打开手机「设置」→「通知」→「通知使用权」（有的叫「通知读取权限」「设备和应用通知」）', sub: '小米 / HyperOS：设置 → 通知与控制中心 → 通知使用权；华为：设置 → 通知和状态栏 → 更多通知设置 → 通知使用权；找不到就在设置里搜「通知使用权」'),
          step(2, '找到「余见」，打开开关，系统弹警告，点「允许」'),
          step(3, '提示「已拒绝此应用获取敏感权限 / 未知来源应用」？', sub: '同上：应用信息页 → ⋮ →「允许受限设置」，再回来开'),
          step(4, '回到余见「自动记账」页拨开「通知自动记账」。收到一条支付通知后到收件箱看', sub: '微信 / 支付宝付款本身不发通知，那是①的活；这条路管银行、购物平台、外卖等'),
          Wrap(children: [
            btn('去通知使用权设置', Icons.notifications_active_outlined, n.openSettings),
            btn('应用信息页', Icons.info_outline, n.openAppInfo),
          ]),

          h('③ 截图自动记账（订单页、账单、小票）'),
          p('要的权限：相册 / 照片读取。截一张图，不用打开余见也能记。'),
          reassure('系统会问「允许余见访问设备上的照片和视频？」。余见只盯相册里新出现的、文件名带「截图」的图；默认「仅本机」档：本机 OCR + 规则，图和字都不出手机；不像账单的截图当场忽略。只有你自己把档位改成「发文字」或「发原图」，才会有东西发给你填的模型。'),
          step(1, '在余见「自动记账」页拨开「截图自动记账」，系统弹权限框'),
          step(2, '选「允许全部」', sub: 'Android 14 起有「选择照片」（只给部分）：那样看不到新截图，等于没开。已经选了部分的，到应用信息页 → 权限 → 照片和视频 → 改成「允许全部」'),
          step(3, '截一张支付页 / 订单页试试，看页面下方「截图处理记录」'),
          Wrap(children: [btn('应用信息页', Icons.info_outline, n.openAppInfo)]),

          h('④ 让它在后台活着（国产系统必做）'),
          p('三条路都靠余见进程在后台。国产系统默认会杀掉，要手动放行：'),
          step(1, '应用信息页 →「自启动」打开', sub: '小米 / HyperOS：应用信息 → 自启动；华为：应用启动管理 → 关掉「自动管理」，手动三项全开；OPPO：应用信息 → 允许自动启动；vivo：i 管家 → 应用管理 → 自启动'),
          step(2, '省电策略 / 电池 →「无限制」或「允许后台高耗电」', sub: '小米：应用信息 → 省电策略 → 无限制；华为：电池 → 应用启动管理；vivo：后台高耗电 → 允许'),
          step(3, '最近任务里把余见「锁定」（下拉卡片或长按 → 锁）', sub: '一键清理就不会把它带走'),
          step(4, '被杀过也不用慌：截图那条路下次打开余见会补扫最近 24 小时；通知和支付页那两条路系统会自动重新拉起服务'),
          Wrap(children: [btn('应用信息页', Icons.info_outline, n.openAppInfo)]),

          h('⑤ 桌面小部件（可选）'),
          step(1, '小米 / HyperOS 添加不了小部件时，应用信息页 → 权限 →「桌面快捷方式」允许'),

          h('用不着的权限'),
          p('余见不申请位置、通讯录、短信、电话、日历、蓝牙扫描。清单里的「蓝牙连接」只是录音库为了走蓝牙耳机麦克风声明的，不扫设备。'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PrivacyStatementPage())),
            icon: const Icon(Icons.privacy_tip_outlined, size: 18),
            label: const Text('完整隐私声明'),
          ),
        ],
      ),
    );
  }
}
