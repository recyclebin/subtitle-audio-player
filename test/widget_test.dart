import 'package:flutter_test/flutter_test.dart';

import 'package:tingjian/main.dart';

void main() {
  testWidgets('app renders without crashing', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('听见'), findsOneWidget);
  });
}
