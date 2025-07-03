import 'package:flutter_test/flutter_test.dart';

void main() {
  // A test outside of a group
  test('Simple bool test', () {
    expect(true, isTrue);
  });

  group('Top Level Group', () {
    test('Bool test in group', () {
      expect(false, isFalse);
    });

    group('Nested Group', () {
      group('Deeply Nested Group', () {
        test('Bool test in deeply nested group', () {
          expect(1 + 1 == 2, isTrue);
        });
      });
    });

    test(
      'Skipped test',
      () {
        expect(true, isFalse);
      },
      skip: 'This test is skipped intentionally',
    );
  });

  test('Always fails', () {
    expect(true, false, reason: 'This test always fails');
  });

  test('Always takes long', () async {
    await Future.delayed(const Duration(seconds: 2));
    expect(true, isTrue);
  });

  test('Will cause an error', () async {
    bool? nullableBool;

    bool nonNullableBool = nullableBool!; // This will throw an error

    expect(true, nonNullableBool);
  });
}
