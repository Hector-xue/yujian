import 'package:flutter/material.dart';

/// Web 没有本地模型这回事（模型文件和 llama.cpp 都在手机 / 桌面端）。
class LocalModelLabPage extends StatelessWidget {
  const LocalModelLabPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('本地模型（打样）')),
      body: const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('本地模型只在 Android / 桌面版可用，网页版不支持。'))),
    );
  }
}
