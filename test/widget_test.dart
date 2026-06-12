// Smoke test for KotaMess Owner.
//
// Without Supabase credentials the app should render the
// "Backend not configured" screen rather than crashing on startup.

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kotamess_owner/main.dart';

void main() {
  testWidgets('shows backend-not-configured screen without credentials',
      (WidgetTester tester) async {
    // Initialise dotenv with an empty env so SupabaseConfig reads as unconfigured.
    dotenv.testLoad(fileInput: '');

    await tester.pumpWidget(const KotaMessOwnerApp());

    expect(find.text('Backend not configured'), findsOneWidget);
  });
}
