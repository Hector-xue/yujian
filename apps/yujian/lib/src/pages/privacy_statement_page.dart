import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../version.dart';

/// 源码地址：隐私声明里「可查」指的就是它（AGPL-3.0；仓库公开后任何人可逐行查）。
const sourceRepoUrl = 'https://github.com/Hector-xue/yujian';

/// 隐私声明：哪些数据会出手机、哪些永远不会、每个权限要来干什么、我们承诺什么、你怎么核对。
/// 全部按代码里实际的出网路径写，改了路径必须同步改这里（出网记录的 explain 也是）。
class PrivacyStatementPage extends StatelessWidget {
  const PrivacyStatementPage({super.key});

  Future<void> _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    Widget h(String t) => Padding(padding: const EdgeInsets.fromLTRB(0, 22, 0, 6), child: Text(t, style: theme.textTheme.titleMedium));
    Widget p(String t) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t, style: theme.textTheme.bodyMedium));
    Widget li(String t, {String? sub}) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('•  ', style: theme.textTheme.bodyMedium),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: theme.textTheme.bodyMedium),
                if (sub != null) Text(sub, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ]),
            ),
          ]),
        );
    // 出网表：一行一条路。列：什么功能 / 发什么 / 发给谁 / 什么时候 / 怎么关
    Widget row(String feature, String what, String to, String when, String off) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(feature, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                _kv(context, '发什么', what),
                _kv(context, '发给谁', to),
                _kv(context, '什么时候', when),
                _kv(context, '怎么关', off),
              ]),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('隐私声明')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          Text('余见 $appVersion · 本声明按代码里实际存在的每一条出网路径写，不是法务模板。', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          h('一句话'),
          p('账本在你的手机上。余见没有统计、埋点、广告 SDK，自家服务器只在你主动点「反馈」发送时收你写的那条反馈。会把数据发出手机的，是你自己填进去的大模型 / 语音服务——发之前默认打码，每一次都写进「出网记录」。打开「纯本地模式」，连这条路也掐掉。'),
          h('哪些数据会出手机（且只在你开了对应功能时）'),
          row('对话里记账 / 查询（配了模型）', '你说的那句话（默认打码：卡号、手机号、身份证、订单号、邮箱换成占位符；金额不动），加上你的账户名、分类名、常去商户表、最近 10 笔记录（模型要靠它们判断记到哪、改哪笔）', '你在「模型与语音」里填的端点（DeepSeek、硅基流动、你自己的 Ollama……余见不指定）', '你在对话里发一句话，且本机规则没能独立解析时', '不配模型，或开「纯本地模式」；只用本机规则记账'),
          row('陪聊', '你的话（打码）、最近几轮对话、它「记住的事」、账本速览（今天 / 本月的合计数与最近几笔）', '同上', '你说的不是记账也不是查询时', '同上。记住的事可在「人格与角色」里删'),
          row('人格口吻', '事件名和数字（比如「记了 2 笔」）+ 记住的事。不含你的原话，不含账本明细', '同上', '每次记账 / 查询后生成那句回应时', '同上'),
          row('财富游戏：周任务候选 / 月度复盘润色', '账本速览（合计数与最近几笔）+ 目标名和进度（「换手机 30%」）；复盘只发那段规则生成的文字', '同上', '每周第一次打开（候选）/ 每月第一次打开（复盘）', '同上。没模型时只有内置模板，复盘只有原文'),
          row('对话里发图片', '整张原图，不打码（你主动发的图，视为你已经看过）', '你填的看图模型', '你点「发图」时', '不发'),
          row('截图自动记账', '默认「仅本机」：什么都不发。「本机认不出时发文字」：本机 OCR 出的文字打码后发；图永远不发。「发原图」：相册里每张新截图原图发（含和钱无关的截图）', '你填的模型', '相册里出现新截图、且本机判断像账单时', '自动记账页把档位改回「仅本机」，或关掉这条路'),
          row('云端语音转写（配了转写模型）', '你按住说话的那段录音', '你填的端点', '装了离线语音包就不走这条；没装且系统识别不可用时', '装离线语音包（识别在本机跑），或不填转写模型'),
          row('云端语音合成（豆包 / MiniMax / 你的端点）', '助手要朗读的回复文字（是它说的话，不是你的话）', '豆包 openspeech.bytedance.com / MiniMax api.minimaxi.com / 你填的端点', '你开了朗读且选了云端音色时', '朗读改「系统朗读」'),
          row('同步与云备份（你自己填了服务器）', '同步：账本变更明文（走 HTTPS）。备份：整本账本用你的口令 AES-GCM 加密后的密文，没口令谁也解不开', '你自己填的那台服务器（余见不提供）', '每次打开 App 自动同步一轮；备份要你手动点', '不填服务器地址'),
          row('版本检查', '只有请求本身：服务器能看到你的 IP 和 App 版本号，不带任何账本数据', 'yujian.ivyea.com（余见唯一的自家域名：版本检查、离线模型包和安装包分发、接收你主动发的反馈）', '每天最多一次；纯本地模式下只有你手动点「检查更新」', '开「纯本地模式」'),
          row('下载离线语音包 / 新版本安装包', '只下载，不上传', 'yujian.ivyea.com / GitHub', '你手动点下载时', '不点'),
          row('拉模型列表', '你的 API Key（用来鉴权），无账本数据', '你填的端点', '你点「从端点拉模型列表」时', '手填模型名'),
          row('反馈 BUG / 建议', '你写的文字、你选的截图（最多 4 张）、你留的联系方式（可不留），以及你没取消勾选的附带信息：App 版本、系统、屏幕尺寸、当前主题。不带任何账本数据', 'yujian.ivyea.com（余见作者的服务器，存下后转到作者的飞书；截图不放任何公开链接）', '只在你点「发送」时', '不点发送；纯本地模式下发送按钮不可用'),
          h('哪些永远不出手机'),
          li('账本本身：yujian.db 数据库文件、账户、分类、每一笔记录、草稿、审计日志'),
          li('API Key、同步 token、备份口令', sub: '存在系统安全存储（Android Keystore），普通偏好文件里没有'),
          li('通知自动记账读到的通知原文', sub: '只在本机和模板比对，不发给模型'),
          li('支付页识别（无障碍）读到的屏幕内容和截屏位图', sub: '截屏只在内存里过一下本机 OCR，不落盘、不上传'),
          li('相册截图（「仅本机」档）', sub: 'ML Kit 中文识别模型打进了安装包，离线跑，不依赖 Google 服务'),
          li('离线语音包识别时的录音'),
          li('陪聊记住的事、自定义人格、头像、背景图'),
          li('目标、周任务、成就、财富指标（可花的 / 等级 / 净资产）', sub: '全在本机算；陪聊和周任务候选会带上目标名和进度（见上表）'),
          li('用量记录、出网记录', sub: '它们本身也只在本机'),
          li('「支持余见」页', sub: '不联网、不上报你有没有付过；「支持过」只是账本画像里的一个日期（随同步走），付款本身在支付宝 / 微信里完成，余见拿不到任何支付信息'),
          h('手机系统自己的能力（不受余见控制）'),
          p('「系统朗读」和「系统语音识别」是手机厂商 / Google 提供的引擎，有的会联网。想彻底不出网：朗读关掉，识别装离线语音包。输入法同理。'),
          h('每个权限要来干什么'),
          li('通知使用权 —— 通知自动记账', sub: '系统会警告「此应用将能读取所有通知」：这是 Android 对所有申请这项权限的 App 的统一提示。余见只匹配支付类模板，其余通知看一眼就丢，任何通知内容都不出手机。不给：这条路不工作，别的都正常'),
          li('无障碍 —— 支付页识别', sub: '系统会警告「查看和控制屏幕」：同样是统一提示。余见只在名单里的支付 / 购物 App 出现「支付成功」那一刻读一次金额和商户，不点任何东西，不出手机。不给：这条路不工作'),
          li('相册 / 照片 —— 截图自动记账', sub: '只看新出现的截图，默认本机识别。Android 14 起可以只给「部分照片」，那样看不到新截图，要「允许全部」。不给：这条路不工作'),
          li('麦克风 —— 按住说话', sub: '装了离线语音包录音不出手机。不给：只能打字'),
          li('安装未知应用 —— 应用内更新', sub: '下载新版本后拉起系统安装器。不给：去门户手动下载'),
          li('自启动 / 后台运行（国产系统） —— 让自动记账在后台活着', sub: '不给：App 被杀后自动记账停，下次打开补扫'),
          h('我们承诺'),
          li('没有后门，没有隐藏的上报，没有第三方统计 / 广告 SDK。安装包里的第三方库只有开源社区的常见组件（数据库、语音、音频、HTTP）'),
          li('余见的服务器 yujian.ivyea.com 只做三件事：放版本号文件和离线模型包、分发安装包、接收你主动发送的反馈。不接收账本，不做任何统计'),
          li('源码按 AGPL-3.0 授权：任何人拿到源码都可以逐行查、自己编译对比，改了拿去提供服务也必须公开源码', sub: sourceRepoUrl),
          li('出网记录是完整的：所有对外通信都经过同一层记账（失败也记）。没有记录 = 没有发生'),
          h('你怎么核对'),
          li('看「出网记录」：每一条都写了发给谁、发了什么类型的东西、多大'),
          li('关掉 Wi-Fi 和流量：记账、查询、统计、通知 / 支付页 / 截图自动记账（仅本机档）照常工作，这就是「本机运行」'),
          li('抓包：用任何抓包工具看余见连过哪些域名，和出网记录对得上'),
          const SizedBox(height: 16),
          OutlinedButton.icon(onPressed: () => _open(sourceRepoUrl), icon: const Icon(Icons.code, size: 18), label: const Text('看源码')),
        ],
      ),
    );
  }

  static Widget _kv(BuildContext context, String k, String v) {
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 58, child: Text(k, style: theme.textTheme.bodySmall?.copyWith(color: muted))),
        Expanded(child: Text(v, style: theme.textTheme.bodySmall)),
      ]),
    );
  }
}
