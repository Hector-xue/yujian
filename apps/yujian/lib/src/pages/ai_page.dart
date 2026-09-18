import 'package:flutter/material.dart';

import 'model_page.dart';
import 'voice_page.dart';

/// 所有模型相关的配置一个入口：「主模型」（读字 / 看图 / 陪聊 + 用量）和「语音」（识别 / 朗读）两个标签页。
/// 教程（申请 API、开通配音）都从各自标签页里进，更多页不再平铺六个入口。
class AiPage extends StatelessWidget {
  final int initialTab; // 0 主模型 · 1 语音
  const AiPage({super.key, this.initialTab = 0});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('模型与语音'),
          bottom: const TabBar(tabs: [Tab(text: '主模型'), Tab(text: '语音')]),
        ),
        body: const TabBarView(children: [ModelPage(embedded: true), VoicePage(embedded: true)]),
      ),
    );
  }
}
