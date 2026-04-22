import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'models/message_model.dart';
import 'platform/app_platform.dart';
import 'services/bluetooth_service.dart';
import 'services/encryption_service.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  // Ensure Flutter engine is ready
  WidgetsFlutterBinding.ensureInitialized();

  // ── Hive Persistence ──────────────────────────────────────────────────────
  // Initialize Hive for local message storage
  await Hive.initFlutter();
  Hive.registerAdapter(MessageAdapter());
  await Hive.openBox<Message>('messages');

  // ── Platform-Specific UI Config ───────────────────────────────────────────
  // Lock mobile devices to portrait mode for a consistent chat experience
  if (AppPlatform.isMobile) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  // Configure System UI (Status Bar & Navigation Bar)
  if (!AppPlatform.isWeb) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppTheme.bgDeep,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  runApp(const BtSecureChatApp());
}

class BtSecureChatApp extends StatelessWidget {
  const BtSecureChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Inject EncryptionService first as BluetoothService depends on it
        Provider(create: (_) => EncryptionService()),
        ChangeNotifierProvider(
          create: (context) => BluetoothService(
            encryption: context.read<EncryptionService>(),
          ),
        ),
      ],
      child: MaterialApp(
        title: 'BT SecureChat',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        builder: (context, child) {
          // Clamp text scaling to prevent accessibility settings from
          // breaking the hardware-dashboard UI layout.
          return MediaQuery.withClampedTextScaling(
            minScaleFactor: 0.8,
            maxScaleFactor: 1.25,
            child: child!,
          );
        },
        home: const AppShell(),
      ),
    );
  }
}

/// The AppShell manages the top-level navigation and responsiveness.
/// It switches between a BottomNavigationBar (Mobile) and
/// a NavigationRail (Desktop/Tablet).
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  // The main views of the application
  final List<Widget> _screens = const [
    HomeScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 720;

    return Scaffold(
      backgroundColor: AppTheme.bgDeep,
      body: Row(
        children: [
          // Show Navigation Rail on Wide Screens (Tablets/Desktop)
          if (isWide) ...[
            NavigationRail(
              backgroundColor: AppTheme.bgSurface,
              selectedIndex: _index,
              onDestinationSelected: (idx) => setState(() => _index = idx),
              labelType: NavigationRailLabelType.all,
              indicatorColor: AppTheme.accentCyan.withOpacity(0.1),
              selectedIconTheme:
                  const IconThemeData(color: AppTheme.accentCyan),
              unselectedIconTheme: const IconThemeData(color: AppTheme.textDim),
              selectedLabelTextStyle:
                  const TextStyle(color: AppTheme.accentCyan, fontSize: 12),
              unselectedLabelTextStyle:
                  const TextStyle(color: AppTheme.textDim, fontSize: 12),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.bluetooth),
                  label: Text('DEVICES'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.security),
                  label: Text('SECURITY'),
                ),
              ],
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: AppTheme.borderGlow),
          ],

          // Main Content Area
          Expanded(child: _screens[_index]),
        ],
      ),

      // Show Bottom Navigation Bar on Narrow Screens (Mobile)
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              height: 65,
              backgroundColor: AppTheme.bgSurface,
              selectedIndex: _index,
              onDestinationSelected: (idx) => setState(() => _index = idx),
              indicatorColor: AppTheme.accentCyan.withOpacity(0.1),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: const [
                NavigationDestination(
                  icon:
                      Icon(Icons.bluetooth_searching, color: AppTheme.textDim),
                  selectedIcon: Icon(Icons.bluetooth_searching,
                      color: AppTheme.accentCyan),
                  label: 'Devices',
                ),
                NavigationDestination(
                  icon: Icon(Icons.security, color: AppTheme.textDim),
                  selectedIcon:
                      Icon(Icons.security, color: AppTheme.accentCyan),
                  label: 'Security',
                ),
              ],
            ),
    );
  }
}
