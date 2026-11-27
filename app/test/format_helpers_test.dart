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

  group('storeName', () {
    test('title-cases receipt capitals', () {
      expect(storeName('THE HOME DEPOT'), 'The Home Depot');
      expect(storeName('BEST BUY'), 'Best Buy');
      expect(storeName("KOHL'S"), "Kohl's");
      expect(storeName('LG ELECTRONICS'), 'LG Electronics');
    });
    test('leaves typed names and empties alone', () {
      expect(storeName('Best Buy'), 'Best Buy');
      expect(storeName('eBay'), 'eBay');
      expect(storeName('  '), isNull);
      expect(storeName(null), isNull);
    });
  });

  group('docName', () {
    test('hides machine file names', () {
      expect(docName('image_picker_C584AFCE-DD71-49D3-A52F-D2B04BB5C971-27282-0000074704B7F1A7.jpg', 'receipt'), 'Receipt photo');
      expect(docName('PXL_20261115_101010.jpg', 'warranty'), 'Warranty document photo');
      expect(docName(null, 'manual'), 'Manual');
    });
    test('keeps real names', () {
      expect(docName('Best Buy receipt.pdf', 'receipt'), 'Best Buy receipt.pdf');
      expect(docName('Dyson V15 manual.pdf', 'manual'), 'Dyson V15 manual.pdf');
    });
  });

  test('productName tidies capitalised receipt lines but keeps model codes', () {
    expect(productName('PHILIPS AIRFRYER HD9252'), 'Philips Airfryer HD9252');
    expect(productName('BOSCH SMS6ZCI00G DISHWASHER'), 'Bosch SMS6ZCI00G Dishwasher');
    expect(productName('LG 55" OLED TV'), 'LG 55" OLED TV');
    expect(productName('Sony WH-1000XM5'), 'Sony WH-1000XM5');
  });
}
