import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/feedback/feedback_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeedbackStore.resetMemory();
  });

  test('草稿：离开页面（flush）后，App 重启（清内存）再读还在', () async {
    FeedbackStore.saveDraft(const FeedbackDraft(kind: 'idea', text: '想要按月导出', contact: 'wx:abc', withInfo: false));
    expect(FeedbackStore.cached!.text, '想要按月导出'); // 同一次打开 App：内存里立刻有
    await FeedbackStore.flushDraft();
    FeedbackStore.resetMemory();
    final d = await FeedbackStore.loadDraft();
    expect(d.kind, 'idea');
    expect(d.text, '想要按月导出');
    expect(d.contact, 'wx:abc');
    expect(d.withInfo, isFalse);
  });

  test('草稿：清空后磁盘上也没了；空草稿不落盘', () async {
    FeedbackStore.saveDraft(const FeedbackDraft(text: '一半'));
    await FeedbackStore.flushDraft();
    await FeedbackStore.clearDraft();
    FeedbackStore.resetMemory();
    expect((await FeedbackStore.loadDraft()).isEmpty, isTrue);
    FeedbackStore.saveDraft(const FeedbackDraft());
    await FeedbackStore.flushDraft();
    expect((await SharedPreferences.getInstance()).getString(FeedbackStore.draftKey), isNull);
  });

  test('历史：新的在前，同编号不重复，超过上限丢最老的，能单条删除', () async {
    for (var i = 0; i < FeedbackStore.historyCap + 3; i++) {
      await FeedbackStore.addHistory(FeedbackRecord(id: 'id$i', atMs: i, kind: 'bug', text: '第 $i 条'), const []);
    }
    await FeedbackStore.addHistory(const FeedbackRecord(id: 'id52', atMs: 99, kind: 'bug', text: '重发'), const []);
    var h = await FeedbackStore.history();
    expect(h.length, FeedbackStore.historyCap);
    expect(h.first.id, 'id52');
    expect(h.first.text, '重发');
    expect(h.where((e) => e.id == 'id52').length, 1);
    expect(h.any((e) => e.id == 'id0'), isFalse);
    await FeedbackStore.removeHistory('id51');
    h = await FeedbackStore.history();
    expect(h.any((e) => e.id == 'id51'), isFalse);
    expect(h.length, FeedbackStore.historyCap - 1);
  });

  test('历史记录 JSON 往返', () {
    const r = FeedbackRecord(id: '20260925-103343-940d0c', atMs: 1790000000000, kind: 'bug', text: '屏幕右侧和下面有阴影', contact: 'x', imageCount: 2);
    final back = FeedbackRecord.fromJson(r.toJson());
    expect(back.id, r.id);
    expect(back.atMs, r.atMs);
    expect(back.imageCount, 2);
    expect(FeedbackRecord.kindName('idea'), '建议');
  });
}
