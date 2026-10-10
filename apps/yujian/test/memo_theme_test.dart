import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/main.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/settings_store.dart';
import 'package:yujian/src/theme.dart';
import 'package:yujian/src/widgets/dock_bar.dart';

/// 便签主题：浅灰底、白卡片、便签黄；黄太浅，底栏选中用正文色。
void main() {
  testWidgets('便签主题能渲染首页；强调色固定便签黄、黄上白字；底栏选中的不是黄字', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
    await state.saveSettings(const Settings(themeId: 'memo'));
    await tester.pumpWidget(YujianApp(state: state));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final t = themeById('memo').build(const Color(0xFF2F6B4F));
    expect(t.colorScheme.primary, const Color(0xFFF2B600), reason: '不跟人格的强调色走');
    expect(t.colorScheme.onPrimary, Colors.white);
    expect(t.scaffoldBackgroundColor, const Color(0xFFF2F2F4));
    // 底栏「首页」选中：文字颜色是正文色，不是看不清的黄
    final label = tester.widget<Text>(find.descendant(of: find.byType(DockBar), matching: find.text('首页')));
    final style = DefaultTextStyle.of(tester.element(find.descendant(of: find.byType(DockBar), matching: find.text('首页')))).style.merge(label.style);
    expect(style.color, isNot(const Color(0xFFF2B600)));
  });
}
