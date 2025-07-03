import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A simple widget we can use as the target for our tests.
class MyTestableWidget extends StatelessWidget {
  final String buttonText;

  const MyTestableWidget({super.key, required this.buttonText});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () {},
            child: Text(buttonText),
          ),
        ),
      ),
    );
  }
}

void main() {
  // Test group for text-based assertions
  group('Text assertion tests', () {
    testWidgets('finds a button with the correct text and passes',
        (WidgetTester tester) async {
      // ARRANGE: Pump the widget with specific text.
      await tester
          .pumpWidget(const MyTestableWidget(buttonText: 'Correct Text'));

      // ACT & ASSERT: Expect to find a widget with that exact text.
      expect(find.text('Correct Text'), findsOneWidget);
    });

    testWidgets('tries to find a button with the wrong text and fails',
        (WidgetTester tester) async {
      // ARRANGE: Pump the widget with specific text.
      await tester
          .pumpWidget(const MyTestableWidget(buttonText: 'Actual Text'));

      // ACT & ASSERT: Expect to find a widget with different text.
      // This assertion will fail because 'Incorrect Text' is not found.
      expect(find.text('Incorrect Text'), findsOneWidget);
    });
  });

  // Test group for golden file (screenshot) assertions
  group('Golden file tests', () {
    testWidgets('matches a golden file and passes',
        (WidgetTester tester) async {
      // ARRANGE: Pump the widget that we want to save as the "master" image.
      await tester
          .pumpWidget(const MyTestableWidget(buttonText: 'Golden Button'));

      // ACT & ASSERT: Compare the widget to the golden file.
      // The first time you run with `--update-goldens`, this will create the file.
      // Subsequent runs will compare against that master file.
      await expectLater(
        find.byType(MyTestableWidget),
        matchesGoldenFile('goldens/button.pass.png'),
      );
    });

    testWidgets('matches a golden file and fails', (WidgetTester tester) async {
      // ARRANGE: Pump the widget with different text than the master golden.
      await tester.pumpWidget(
          const MyTestableWidget(buttonText: 'Golden Button - Different'));

      // ACT & ASSERT: Compare this different widget against the original golden file.
      // This will fail because the pixels do not match.
      await expectLater(
        find.byType(MyTestableWidget),
        matchesGoldenFile('goldens/button.fail.png'),
      );
    });
  });
}
