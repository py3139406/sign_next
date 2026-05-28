import 'package:flutter_test/flutter_test.dart';
import 'package:sign_next/main.dart';

void main() {
  testWidgets('SignNext app smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const SignNextApp());

    // Verify that our app name and current screen title are displayed.
    expect(find.text('SignNext'), findsAtLeastNWidgets(1));
    expect(find.text('Signing Studio'), findsAtLeastNWidgets(1));
  });
}
