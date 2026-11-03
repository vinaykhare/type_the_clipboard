import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:type_the_clipboard/app/auto_typer_home.dart';
import 'package:type_the_clipboard/services/settings_service.dart';

void main() {
  testWidgets('App renders main tabs', (WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsService.getInstance();

    await tester.pumpWidget(
      MaterialApp(home: AutoTyperHome(settings: settings)),
    );
    await tester.pump();

    expect(find.text('Clipboard'), findsOneWidget);
    expect(find.text('OTP'), findsOneWidget);
    expect(find.text('Credentials'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('⚙'), findsOneWidget);
  });
}
