import 'package:flutter_test/flutter_test.dart';
import 'package:warrantra/core/network/api_client.dart';
import 'package:warrantra/core/utils/format.dart';

void main() {
  group('durationEndDate mirrors backend durationEndDate', () {
    test('24 months from Nov 22 ends the day before the anniversary', () {
      expect(durationEndDate(DateTime(2026, 11, 22), 24), DateTime(2028, 11, 21));
    });
    test('month-end clamps instead of overflowing (Jan 31 + 1 month)', () {
      expect(durationEndDate(DateTime(2027, 1, 31), 1), DateTime(2027, 2, 27));
    });
    test('leap year clamp (Jan 31 + 1 month in 2028)', () {
      expect(durationEndDate(DateTime(2028, 1, 31), 1), DateTime(2028, 2, 28));
    });
    test('Feb 29 + 12 months', () {
      expect(durationEndDate(DateTime(2028, 2, 29), 12), DateTime(2029, 2, 27));
    });
  });

  group('isBadMoney', () {
    test('empty is fine (unknown price)', () => expect(isBadMoney('  '), isFalse));
    test('plain and formatted amounts are fine', () {
      expect(isBadMoney('749.99'), isFalse);
      expect(isBadMoney('\$1,299.5'), isFalse);
    });
    test('junk, negatives and 3 decimals are rejected', () {
      expect(isBadMoney('-7a49.999'), isTrue);
      expect(isBadMoney('-5'), isTrue);
      expect(isBadMoney('12.345'), isTrue);
    });
  });

  group('validationMessage', () {
    test('names the field instead of "Invalid body"', () {
      expect(
        validationMessage({
          'issues': [
            {'path': 'registration_url', 'message': 'Invalid url', 'code': 'invalid_string'},
          ],
        }),
        contains('https://'),
      );
      expect(validationMessage({'issues': [{'path': 'email'}]}), 'Enter a valid email address.');
    });
    test('unknown field gets a readable generic hint', () {
      expect(validationMessage({'issues': [{'path': 'lines.0.order_number'}]}), 'Check the Order number field and try again.');
    });
    test('no details', () => expect(validationMessage(null), contains('Check the form')));
  });
}
