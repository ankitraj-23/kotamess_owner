import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_service.dart';
import 'profile/owner_profile.dart';
import 'profile/owner_profile_service.dart';
import 'screens/chat_import_screen.dart';
import 'screens/customers_screen.dart';
import 'screens/daily_screen.dart';
import 'screens/home_screen.dart';
import 'screens/ledger_screen.dart';
import 'screens/meal_requests_screen.dart';
import 'screens/settings_screen.dart';
import 'services/database_service.dart';
import 'services/extraction_service.dart';
import 'supabase/supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseConfig.loadEnv();

  if (SupabaseConfig.isConfigured) {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      // SUPABASE_ANON_KEY holds the publishable (anon) key; the SDK renamed the
      // parameter from the now-deprecated `anonKey` to `publishableKey`.
      publishableKey: SupabaseConfig.anonKey,
    );
  }

  runApp(const KotaMessOwnerApp());
}

class KotaMessOwnerApp extends StatelessWidget {
  const KotaMessOwnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF16A34A),
      brightness: Brightness.light,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'KotaMess Owner',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF5F7F6),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F7F6),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.grey.shade200),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: SupabaseConfig.isConfigured
          ? AuthGate(
              authService: AuthService(),
              profileService: OwnerProfileService(),
            )
          : const _BackendNotConfiguredScreen(),
    );
  }
}

/// Shown when SUPABASE_URL / SUPABASE_ANON_KEY are missing so the app gives a
/// clear message instead of crashing on startup.
class _BackendNotConfiguredScreen extends StatelessWidget {
  const _BackendNotConfiguredScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.settings_suggest_outlined, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Backend not configured',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                'Add SUPABASE_URL and SUPABASE_ANON_KEY to the .env file '
                '(see .env.example), then restart the app.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Main app shell: bottom navigation across Home, Import, Requests, Daily and
/// Ledger, with Settings reachable from the app bar. All data is owner-scoped
/// through Supabase ([DatabaseService]); the legacy local demo store is gone.
class KotaShell extends StatefulWidget {
  const KotaShell({
    super.key,
    required this.profile,
    required this.profileService,
    required this.onSignOut,
  });

  final OwnerProfile profile;
  final OwnerProfileService profileService;
  final VoidCallback onSignOut;

  @override
  State<KotaShell> createState() => _KotaShellState();
}

class _KotaShellState extends State<KotaShell> {
  final _databaseService = DatabaseService();
  final _extractionService = ExtractionService();

  // Tab indices: 0 Home, 1 Customers, 2 Import, 3 Requests, 4 Daily, 5 Ledger.
  static const _tabHome = 0;
  static const _tabCustomers = 1;
  static const _tabImport = 2;
  static const _tabRequests = 3;
  static const _tabDaily = 4;
  static const _tabLedger = 5;

  final _homeKey = GlobalKey<HomeScreenState>();
  final _customersKey = GlobalKey<CustomersScreenState>();
  final _requestsKey = GlobalKey<MealRequestsScreenState>();
  final _dailyKey = GlobalKey<DailyScreenState>();
  final _ledgerKey = GlobalKey<LedgerScreenState>();

  late OwnerProfile _profile = widget.profile;
  int _index = 0;

  /// Bumped after "Reset app data" so the (always-mounted) Import screen clears
  /// its local draft via didUpdateWidget.
  int _resetToken = 0;

  /// Switch tabs and refresh the target screen so figures stay current after
  /// imports/approvals on other tabs.
  void _select(int index) {
    setState(() => _index = index);
    _refreshTab(index);
  }

  void _refreshTab(int index) {
    switch (index) {
      case _tabHome:
        _homeKey.currentState?.reload();
        break;
      case _tabCustomers:
        _customersKey.currentState?.reload();
        break;
      case _tabRequests:
        _requestsKey.currentState?.reload();
        break;
      case _tabDaily:
        _dailyKey.currentState?.reload();
        break;
      case _tabLedger:
        _ledgerKey.currentState?.reload();
        break;
    }
  }

  void _onImportSaved() {
    // Pending count and activity changed: refresh Home, then show Requests.
    _homeKey.currentState?.reload();
    _select(_tabRequests);
  }

  /// After the owner resets all app data: bump the reset token (clears the
  /// mounted Import tab's local draft), refresh every data tab so they refetch
  /// the now-empty account, and land back on Home. Auth/session is untouched.
  void _onDataReset() {
    setState(() {
      _resetToken++;
      _index = _tabHome;
    });
    _homeKey.currentState?.reload();
    _customersKey.currentState?.reload();
    _requestsKey.currentState?.reload();
    _dailyKey.currentState?.reload();
    _ledgerKey.currentState?.reload();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          profile: _profile,
          profileService: widget.profileService,
          databaseService: _databaseService,
          // Home and Daily auto-refresh via didUpdateWidget when base counts
          // change, so just push the new profile into the shell.
          onProfileUpdated: (updated) => setState(() => _profile = updated),
          onSignOut: widget.onSignOut,
          onDataReset: _onDataReset,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeScreen(
        key: _homeKey,
        profile: _profile,
        databaseService: _databaseService,
        onOpenCustomers: () => _select(_tabCustomers),
        onOpenImport: () => _select(_tabImport),
        onOpenRequests: () => _select(_tabRequests),
        onOpenDaily: () => _select(_tabDaily),
        onOpenLedger: () => _select(_tabLedger),
      ),
      CustomersScreen(key: _customersKey, databaseService: _databaseService),
      ChatImportScreen(
        extractionService: _extractionService,
        databaseService: _databaseService,
        onSavedGoToRequests: _onImportSaved,
        resetToken: _resetToken,
      ),
      MealRequestsScreen(key: _requestsKey, databaseService: _databaseService),
      DailyScreen(
        key: _dailyKey,
        profile: _profile,
        databaseService: _databaseService,
      ),
      LedgerScreen(key: _ledgerKey, databaseService: _databaseService),
    ];

    final initial = _profile.ownerName.isNotEmpty
        ? _profile.ownerName[0].toUpperCase()
        : '?';

    // Android back: if we're not on Home, swallow the pop and switch to Home
    // instead of exiting the app. On Home, allow the normal pop (exit/minimise).
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _select(0);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _profile.messName.isEmpty ? 'KotaMess Owner' : _profile.messName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                avatar: CircleAvatar(
                  radius: 11,
                  child: Text(initial, style: const TextStyle(fontSize: 12)),
                ),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 90),
                  child: Text(
                    _profile.ownerName.isEmpty ? 'Owner' : _profile.ownerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                side: BorderSide.none,
                backgroundColor: Colors.white,
              ),
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _openSettings,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          child: IndexedStack(index: _index, children: screens),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.groups_outlined),
                selectedIcon: Icon(Icons.groups),
                label: 'People'),
            NavigationDestination(
                icon: Icon(Icons.upload_file_outlined),
                selectedIcon: Icon(Icons.upload_file),
                label: 'Import'),
            NavigationDestination(
                icon: Icon(Icons.fact_check_outlined),
                selectedIcon: Icon(Icons.fact_check),
                label: 'Requests'),
            NavigationDestination(
                icon: Icon(Icons.restaurant_menu_outlined),
                selectedIcon: Icon(Icons.restaurant_menu),
                label: 'Daily'),
            NavigationDestination(
                icon: Icon(Icons.account_balance_wallet_outlined),
                selectedIcon: Icon(Icons.account_balance_wallet),
                label: 'Ledger'),
          ],
        ),
      ),
    );
  }
}
