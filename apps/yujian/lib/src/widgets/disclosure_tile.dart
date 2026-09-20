import 'package:flutter/material.dart';

/// 表单里的「高级 / 可选」折叠行：一行小字 + 箭头，点开露出几个输入框。
/// 直接用 ExpansionTile 的话，它的标题行是个 ListTile，按下去的高亮是一块按整行宽画的矩形（全局主题把它的形状设成了无边框的
/// Border()，水波就没有圆角可裁）——夹在有内边距的表单里就是一块突兀的灰色长方形。这种一行字的折叠开关不需要按压高亮，
/// 展开 / 收起的动画本身就是反馈，这里把水波和高亮一起关掉。
class DisclosureTile extends StatelessWidget {
  final Widget title;
  final Widget? subtitle;
  final List<Widget> children;
  final bool initiallyExpanded;
  const DisclosureTile({super.key, required this.title, this.subtitle, required this.children, this.initiallyExpanded = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(splashFactory: NoSplash.splashFactory, splashColor: Colors.transparent, highlightColor: Colors.transparent, hoverColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: initiallyExpanded,
        title: title,
        subtitle: subtitle,
        children: children,
      ),
    );
  }
}
