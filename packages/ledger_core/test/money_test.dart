import 'package:ledger_core/ledger_core.dart';
import 'package:test/test.dart';

void main() {
  group('Money', () {
    test('parse decimal into minor units', () {
      expect(Money.parse('28.50', 'CNY').minor, 2850);
      expect(Money.parse('28', 'CNY').minor, 2800);
      expect(Money.parse('0.05', 'CNY').minor, 5);
      expect(Money.parse('1,234.56', 'USD').minor, 123456);
      expect(Money.parse('-3.10', 'CNY').minor, -310);
    });
    test('zero-decimal currency', () {
      expect(Money.parse('1200', 'JPY').minor, 1200);
      expect(const Money(1200, 'JPY').toDecimalString(), '1200');
      expect(() => Money.parse('12.5', 'JPY'), throwsFormatException);
    });
    test('rejects excess precision instead of rounding', () {
      expect(() => Money.parse('1.005', 'CNY'), throwsFormatException);
    });
    test('rejects unknown currency', () {
      expect(() => Money.parse('1', 'XXX'), throwsArgumentError);
    });
    test('format', () {
      expect(const Money(2850, 'CNY').toDecimalString(), '28.50');
      expect(const Money(-5, 'CNY').toDecimalString(), '-0.05');
      expect(const Money(100, 'KWD').toDecimalString(), '0.100');
    });
    test('arithmetic guards currency', () {
      expect(const Money(100, 'CNY') + const Money(50, 'CNY'), const Money(150, 'CNY'));
      expect(() => const Money(100, 'CNY') + const Money(50, 'USD'), throwsArgumentError);
    });
  });

  group('OccurredAt', () {
    test('parse with offset keeps wall time and offset', () {
      final t = OccurredAt.parse('2026-09-14T20:00:00+08:00');
      expect(t.offsetMinutes, 480);
      expect(t.utc.toIso8601String(), '2026-09-14T12:00:00.000Z');
      expect(t.toIso8601String(), '2026-09-14T20:00:00.000+08:00');
      expect(t.localDate, '2026-09-14');
    });
    test('parse Z and negative offset', () {
      expect(OccurredAt.parse('2026-01-01T00:00:00Z').offsetMinutes, 0);
      final t = OccurredAt.parse('2026-01-01T00:00:00-05:30');
      expect(t.offsetMinutes, -330);
      expect(t.toIso8601String(), '2026-01-01T00:00:00.000-05:30');
    });
    test('naive time rejected unless fallback given', () {
      expect(() => OccurredAt.parse('2026-09-14T20:00:00'), throwsFormatException);
      final t = OccurredAt.parse('2026-09-14T20:00:00', fallbackOffsetMinutes: 480);
      expect(t.utc.toIso8601String(), '2026-09-14T12:00:00.000Z');
    });
    test('round trip through millis', () {
      final t = OccurredAt.parse('2026-09-14T20:00:00+08:00');
      expect(OccurredAt.fromMillis(t.millis, t.offsetMinutes), t);
    });
  });

  group('Ulid', () {
    test('26 chars, valid alphabet, time-sortable', () {
      final a = Ulid.next(at: DateTime.utc(2026, 1, 1));
      final b = Ulid.next(at: DateTime.utc(2026, 1, 2));
      expect(a.length, 26);
      expect(Ulid.isValid(a), isTrue);
      expect(a.compareTo(b), lessThan(0));
    });
  });
}
