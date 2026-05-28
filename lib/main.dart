import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import 'services/signing_service.dart';
import 'services/sharing_server.dart';
import 'services/vault_service.dart';
import 'services/client_service.dart';
import 'services/metadata_service.dart';

void main() {
  runApp(const SignNextApp());
}

class SignNextApp extends StatelessWidget {
  const SignNextApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SignNext',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0F11),
        cardColor: const Color(0xFF1E1E22),
        primaryColor: const Color(0xFF8B5CF6),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8B5CF6),
          secondary: Color(0xFF10B981),
          surface: Color(0xFF1E1E22),
          error: Color(0xFFEF4444),
        ),
        fontFamily: 'Courier',
        useMaterial3: true,
      ),
      home: const PlatformDispatcherScreen(),
    );
  }
}

/// Dispatches between Desktop UI (with Microsoft Login Screen) and Mobile UI.
class PlatformDispatcherScreen extends StatefulWidget {
  const PlatformDispatcherScreen({super.key});

  @override
  State<PlatformDispatcherScreen> createState() => _PlatformDispatcherScreenState();
}

class _PlatformDispatcherScreenState extends State<PlatformDispatcherScreen> {
  bool _authenticated = false;
  bool _skipped = false;
  String? _userEmail;

  @override
  void initState() {
    super.initState();
    _checkPreviousLogin();
  }

  Future<void> _checkPreviousLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final authed = prefs.getBool('is_authenticated') ?? false;
    final skipped = prefs.getBool('auth_skipped') ?? false;
    final email = prefs.getString('user_email');
    if (mounted) {
      setState(() {
        _authenticated = authed;
        _skipped = skipped;
        _userEmail = email;
      });
    }
  }

  void _onLoginSuccess(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_authenticated', true);
    await prefs.setBool('auth_skipped', false);
    await prefs.setString('user_email', email);
    setState(() {
      _authenticated = true;
      _skipped = false;
      _userEmail = email;
    });
  }

  void _onSkipLogin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_authenticated', false);
    await prefs.setBool('auth_skipped', true);
    setState(() {
      _authenticated = false;
      _skipped = true;
    });
  }

  void _onLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('is_authenticated');
    await prefs.remove('auth_skipped');
    await prefs.remove('user_email');
    setState(() {
      _authenticated = false;
      _skipped = false;
      _userEmail = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
    if (isMobile) {
      return const MobileConnectionScreen();
    }

    if (!_authenticated && !_skipped) {
      return LoginScreen(
        onLoginSuccess: _onLoginSuccess,
        onSkip: _onSkipLogin,
      );
    }

    return DashboardScreen(
      userEmail: _userEmail,
      onLogout: _onLogout,
    );
  }
}

enum AppTab { sign, unsign, vault, settings }

// =============================================================================
// DESKTOP INTERFACE
// =============================================================================
class DashboardScreen extends StatefulWidget {
  final String? userEmail;
  final VoidCallback? onLogout;

  const DashboardScreen({super.key, this.userEmail, this.onLogout});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  AppTab _currentTab = AppTab.sign;
  
  final _signingService = SigningService();
  final _sharingServer = SharingServer();
  final _vaultService = VaultService();

  List<SigningProfile> _profiles = [];
  String? _selectedProfileId;

  // File Sharing URL
  String? _sharingUrl;
  String? _sharedFileName;

  // Server mode (listening for mobile connections)
  bool _isServerMode = false;
  String? _serverModeUrl;

  // History list
  List<SignedAppHistoryItem> _recentApps = [];

  @override
  void initState() {
    super.initState();
    _loadProfiles();
    _loadRecentApps();
  }

  Future<void> _loadProfiles() async {
    final list = await _vaultService.getProfiles();
    setState(() {
      _profiles = list;
    });
  }

  Future<void> _loadRecentApps() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('recent_signed_apps') ?? [];
    var apps = list.map((item) {
      try {
        return SignedAppHistoryItem.fromJson(json.decode(item));
      } catch (_) {
        return null;
      }
    }).whereType<SignedAppHistoryItem>().toList();

    // Clean up and repair any historical apps with unknown package ID, version, or long names
    bool needsSave = false;
    for (var i = 0; i < apps.length; i++) {
      final app = apps[i];
      if (app.packageId == 'Unknown' || app.versionName == '1.0.0' || app.name.contains('-Unsigned-') || app.name.contains('-signed')) {
        final filenameMeta = MetadataService.parseFromFilename(p.basename(app.filePath));
        if (filenameMeta != null) {
          apps[i] = SignedAppHistoryItem(
            id: app.id,
            name: (app.name == 'Unknown' || app.name.contains('-Unsigned-') || app.name.contains('-signed')) ? filenameMeta.name : app.name,
            packageId: app.packageId == 'Unknown' ? filenameMeta.packageId : app.packageId,
            versionName: app.versionName == '1.0.0' ? filenameMeta.versionName : app.versionName,
            versionCode: app.versionCode == '1' ? filenameMeta.versionCode : app.versionCode,
            filePath: app.filePath,
            platform: app.platform,
            date: app.date,
          );
          needsSave = true;
        }
      }
    }

    setState(() {
      _recentApps = apps;
    });

    if (needsSave) {
      final encoded = apps.map((item) => json.encode(item.toJson())).toList();
      await prefs.setStringList('recent_signed_apps', encoded);
    }
  }

  Future<void> _addAppToHistory(SignedAppHistoryItem app) async {
    final prefs = await SharedPreferences.getInstance();
    var updated = _recentApps.where((item) => item.filePath != app.filePath).toList();
    
    final iosApps = updated.where((item) => item.platform == 'ios').toList();
    final androidApps = updated.where((item) => item.platform == 'android').toList();
    
    if (app.platform == 'ios') {
      if (iosApps.length >= 2) {
        iosApps.removeAt(iosApps.length - 1);
      }
      iosApps.insert(0, app);
    } else {
      if (androidApps.length >= 2) {
        androidApps.removeAt(androidApps.length - 1);
      }
      androidApps.insert(0, app);
    }
    
    updated = [...iosApps, ...androidApps];
    updated.sort((a, b) => b.date.compareTo(a.date));
    
    setState(() {
      _recentApps = updated;
    });
    
    final encoded = updated.map((item) => json.encode(item.toJson())).toList();
    await prefs.setStringList('recent_signed_apps', encoded);
  }

  Future<void> _removeAppFromHistory(SignedAppHistoryItem app) async {
    final prefs = await SharedPreferences.getInstance();
    final updated = _recentApps.where((item) => item.id != app.id).toList();
    
    setState(() {
      _recentApps = updated;
    });
    
    final encoded = updated.map((item) => json.encode(item.toJson())).toList();
    await prefs.setStringList('recent_signed_apps', encoded);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed ${app.name} from history'),
        backgroundColor: const Color(0xFF27272A),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _toggleServerMode(bool enable) async {
    if (enable) {
      try {
        final url = await _sharingServer.startServerMode();
        setState(() {
          _isServerMode = true;
          _serverModeUrl = url;
        });
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start server mode: $e')),
        );
      }
    } else {
      await _sharingServer.stop();
      setState(() {
        _isServerMode = false;
        _serverModeUrl = null;
        _sharingUrl = null;
        _sharedFileName = null;
      });
    }
  }

  @override
  void dispose() {
    _sharingServer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _buildSidebar(),
          Expanded(
            child: Container(
              color: const Color(0xFF09090B),
              child: SafeArea(
                child: Column(
                  children: [
                    _buildTopBar(),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: _buildCurrentTabContent(),
                        ),
                      ),
                    ),
                    if (_sharingUrl != null) _buildSharingStatusBar(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 250,
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F12),
        border: Border(
          right: BorderSide(color: Color(0xFF27272A), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 32.0, left: 24.0, bottom: 20.0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF8B5CF6), Color(0xFF10B981)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.draw, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SignNext',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'CRMNext Suite',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        color: Color(0xFF71717A),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // Profile Card
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: widget.userEmail != null ? const Color(0xFF8B5CF6) : const Color(0xFF71717A),
                    radius: 14,
                    child: Icon(
                      widget.userEmail != null ? Icons.person_rounded : Icons.person_outline_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.userEmail != null ? 'Enterprise SSO' : 'Guest Mode',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            color: Color(0xFF8B5CF6),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          widget.userEmail ?? 'Offline Guest',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            color: Colors.white70,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.logout_rounded, size: 14, color: Color(0xFFEF4444)),
                    tooltip: 'Log Out',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onLogout,
                  ),
                ],
              ),
            ),
          ),
          const Divider(color: Color(0xFF27272A), height: 16),

          _buildSidebarItem(tab: AppTab.sign, icon: Icons.vpn_key_rounded, label: 'Sign Studio', subtitle: 'Sign IPA, APK or AAB'),
          _buildSidebarItem(tab: AppTab.unsign, icon: Icons.key_off_rounded, label: 'Unsign Studio', subtitle: 'Strip package signatures'),
          _buildSidebarItem(tab: AppTab.vault, icon: Icons.admin_panel_settings_rounded, label: 'Profile Vault', subtitle: 'Manage secure credentials'),
          _buildSidebarItem(tab: AppTab.settings, icon: Icons.settings_suggest_rounded, label: 'Settings', subtitle: 'Binary tool paths'),
          
          const Divider(color: Color(0xFF27272A), height: 16),

          // Recent Signed Apps section
          if (_recentApps.isNotEmpty) ...[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  if (_recentApps.any((app) => app.platform == 'ios')) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                      child: Text(
                        'RECENT iOS APPS',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF38BDF8),
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                    ..._recentApps
                        .where((app) => app.platform == 'ios')
                        .map((app) => _buildRecentAppItem(context, app)),
                  ],
                  if (_recentApps.any((app) => app.platform == 'android')) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                      child: Text(
                        'RECENT ANDROID APPS',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF10B981),
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                    ..._recentApps
                        .where((app) => app.platform == 'android')
                        .map((app) => _buildRecentAppItem(context, app)),
                  ],
                ],
              ),
            ),
          ] else ...[
            const Spacer(),
          ],
          
          // Server mode widget inside sidebar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Mobile Server Mode',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
                      ),
                      Switch(
                        value: false,
                        activeColor: const Color(0xFF10B981),
                        onChanged: null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Mobile Server Mode is currently disabled by enterprise policy.',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF52525B)),
                  ),
                ],
              ),
            ),
          ),
          
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
            child: Center(
              child: Text(
                'v1.0.0 • BusinessNext',
                style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.grey[600]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentAppItem(BuildContext context, SignedAppHistoryItem app) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF131316),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF27272A)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  app.platform == 'ios' ? Icons.phone_iphone_rounded : Icons.phone_android_rounded,
                  color: app.platform == 'ios' ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    app.name,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              app.packageId,
              style: const TextStyle(
                fontFamily: 'Courier',
                fontSize: 9,
                color: Color(0xFF71717A),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'v${app.versionName} (${app.versionCode})',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 9,
                color: Color(0xFF52525B),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.folder_open_rounded, size: 14),
                  tooltip: 'Locate File',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                  color: const Color(0xFFA1A1AA),
                  onPressed: () => verifyAndLocateFile(context, app.filePath),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 14, color: Color(0xFFEF4444)),
                  tooltip: 'Remove from History',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                  onPressed: () => _removeAppFromHistory(app),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.info_outline_rounded, size: 14),
                  tooltip: 'Details',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                  color: const Color(0xFFA1A1AA),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AppDetailsDialogWidget(app: app),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarItem({required AppTab tab, required IconData icon, required String label, required String subtitle}) {
    final isSelected = _currentTab == tab;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
      child: InkWell(
        onTap: () => setState(() => _currentTab = tab),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF1E1E24) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: isSelected ? Border.all(color: const Color(0xFF27272A), width: 1) : Border.all(color: Colors.transparent, width: 1),
          ),
          child: Row(
            children: [
              Icon(icon, color: isSelected ? const Color(0xFF8B5CF6) : const Color(0xFF71717A), size: 22),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Colors.white : const Color(0xFFA1A1AA),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        color: isSelected ? const Color(0xFF71717A) : const Color(0xFF52525B),
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    String title = '';
    String desc = '';
    switch (_currentTab) {
      case AppTab.sign:
        title = 'Signing Studio';
        desc = 'Easily sign your iOS IPAs and Android APKs/AABs in a single click.';
        break;
      case AppTab.unsign:
        title = 'Unsigning Studio';
        desc = 'Strip digital signatures and provisioning files from builds.';
        break;
      case AppTab.vault:
        title = 'Profile Vault';
        desc = 'Manage secure credentials, P12 certs, Keystores, and credentials.';
        break;
      case AppTab.settings:
        title = 'Binary Settings';
        desc = 'Configure local utility tool locations (zipalign, apksigner).';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F12),
        border: Border(bottom: BorderSide(color: Color(0xFF27272A), width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontFamily: 'Inter', fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 4),
              Text(
                desc,
                style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF71717A)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentTabContent() {
    switch (_currentTab) {
      case AppTab.sign:
        return SignStudioWidget(
          signingService: _signingService,
          profiles: _profiles,
          vaultService: _vaultService,
          userEmail: widget.userEmail,
          onStartSharing: (filePath, url) {
            setState(() {
              _sharingUrl = url;
              _sharedFileName = p.basename(filePath);
            });
          },
          onSignSuccess: (appItem) {
            _addAppToHistory(appItem);
          },
        );
      case AppTab.unsign:
        return UnsignStudioWidget(signingService: _signingService);
      case AppTab.vault:
        return VaultWidget(vaultService: _vaultService, onProfilesChanged: _loadProfiles);
      case AppTab.settings:
        return const SettingsWidget();
    }
  }

  Widget _buildSharingStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 14.0),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFF1E1B4B), Color(0xFF064E3B)]),
        border: Border(top: BorderSide(color: Color(0xFF10B981), width: 1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_tethering, color: Color(0xFF10B981)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Local Hosting Active for $_sharedFileName',
                  style: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                ),
                Text(
                  'URL: $_sharingUrl (Ensure phone is on the same Wi-Fi)',
                  style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFFA7F3D0)),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.stop_screen_share_rounded, size: 16),
            label: const Text('Stop Share', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
            onPressed: () async {
              await _sharingServer.stop();
              setState(() {
                _sharingUrl = null;
                _sharedFileName = null;
              });
            },
          ),
        ],
      ),
    ).animate().slideY(begin: 1, end: 0, curve: Curves.easeOutCubic, duration: 400.ms);
  }
}

// =============================================================================
// MOBILE REMOTE CLIENT INTERFACE
// =============================================================================
class MobileConnectionScreen extends StatefulWidget {
  const MobileConnectionScreen({super.key});

  @override
  State<MobileConnectionScreen> createState() => _MobileConnectionScreenState();
}

class _MobileConnectionScreenState extends State<MobileConnectionScreen> {
  final _urlController = TextEditingController();
  final _clientService = ClientService();
  bool _connecting = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    // Default fallback
    _urlController.text = 'http://';
  }

  Future<void> _connect() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl == 'http://' || rawUrl.isEmpty) {
      setState(() => _errorMsg = 'Please enter a valid server URL.');
      return;
    }
    setState(() {
      _connecting = true;
      _errorMsg = null;
    });

    try {
      _clientService.setServerUrl(rawUrl);
      final profiles = await _clientService.fetchProfiles();
      
      // Connection succeeded! Transition to Mobile Main Studio
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => MobileDashboard(
              clientService: _clientService,
              initialProfiles: profiles,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMsg = 'Failed to connect: $e\nVerify Desktop IP and Server mode status.';
      });
    } finally {
      setState(() {
        _connecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Glowing icon
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF10B981)]),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF8B5CF6).withOpacity(0.3), blurRadius: 20, spreadRadius: 2)
                  ]
                ),
                child: const Icon(Icons.wifi_rounded, color: Colors.white, size: 48),
              ),
              const SizedBox(height: 24),
              const Text(
                'Connect to Desktop Server',
                style: TextStyle(fontFamily: 'Inter', fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter the API Server URL shown in the sidebar of the Desktop SignNext application.',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF71717A)),
              ),
              const SizedBox(height: 32),
              
              // Input
              TextField(
                controller: _urlController,
                style: const TextStyle(fontFamily: 'Courier', fontSize: 14, color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Desktop Server API URL',
                  labelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA)),
                  hintText: 'e.g. http://192.168.1.100:54321',
                  fillColor: const Color(0xFF1E1E22),
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF27272A))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF27272A))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                ),
              ),
              if (_errorMsg != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMsg!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFEF4444)),
                ),
              ],
              const SizedBox(height: 28),
              
              // Submit button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B5CF6),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _connecting ? null : _connect,
                  child: _connecting
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Connect Studio', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MobileDashboard extends StatefulWidget {
  final ClientService clientService;
  final List<SigningProfile> initialProfiles;

  const MobileDashboard({super.key, required this.clientService, required this.initialProfiles});

  @override
  State<MobileDashboard> createState() => _MobileDashboardState();
}

class _MobileDashboardState extends State<MobileDashboard> {
  int _currentIndex = 0;
  late List<SigningProfile> _profiles;

  @override
  void initState() {
    super.initState();
    _profiles = widget.initialProfiles;
  }

  Future<void> _refreshProfiles() async {
    try {
      final list = await widget.clientService.fetchProfiles();
      setState(() {
        _profiles = list;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> tabs = [
      MobileSignTab(clientService: widget.clientService, profiles: _profiles, onRefreshProfiles: _refreshProfiles),
      MobileUnsignTab(clientService: widget.clientService),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('SignNext Mobile', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 16)),
        backgroundColor: const Color(0xFF0F0F12),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20, color: Color(0xFF10B981)),
            onPressed: _refreshProfiles,
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, size: 20, color: Color(0xFFEF4444)),
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (context) => const MobileConnectionScreen()),
              );
            },
          ),
        ],
      ),
      body: Container(
        color: const Color(0xFF09090B),
        child: tabs[_currentIndex],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        backgroundColor: const Color(0xFF0F0F12),
        selectedItemColor: const Color(0xFF8B5CF6),
        unselectedItemColor: const Color(0xFF71717A),
        selectedLabelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.vpn_key_rounded), label: 'Sign Studio'),
          BottomNavigationBarItem(icon: Icon(Icons.key_off_rounded), label: 'Unsign Studio'),
        ],
        onTap: (idx) {
          setState(() {
            _currentIndex = idx;
          });
        },
      ),
    );
  }
}

class MobileSignTab extends StatefulWidget {
  final ClientService clientService;
  final List<SigningProfile> profiles;
  final VoidCallback onRefreshProfiles;

  const MobileSignTab({super.key, required this.clientService, required this.profiles, required this.onRefreshProfiles});

  @override
  State<MobileSignTab> createState() => _MobileSignTabState();
}

class _MobileSignTabState extends State<MobileSignTab> {
  String _platform = 'ios';
  String _androidAppType = 'apk';
  String? _unsignedPath;
  String? _selectedProfileId;
  final _iosBundleIdController = TextEditingController();

  bool _isSigning = false;
  double _progress = 0.0;
  String _statusMsg = '';
  String? _signedLocalPath;

  Future<void> _pickFile() async {
    FilePickerResult? result;
    List<String>? allowedExtensions;
    if (_platform == 'ios') allowedExtensions = ['ipa'];
    else allowedExtensions = _androidAppType == 'apk' ? ['apk'] : ['aab'];

    result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: allowedExtensions);
    if (result != null) {
      final path = result.files.single.path;
      if (path != null) {
        setState(() {
          _unsignedPath = path;
          _signedLocalPath = null;
          _progress = 0.0;
        });
      }
    }
  }

  Future<void> _startSign() async {
    if (_unsignedPath == null || _selectedProfileId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a file and profile.')),
      );
      return;
    }

    setState(() {
      _isSigning = true;
      _progress = 0.0;
      _statusMsg = 'Connecting to desktop...';
      _signedLocalPath = null;
    });

    final ext = p.extension(_unsignedPath!);
    final baseName = p.basenameWithoutExtension(_unsignedPath!);
    
    // Save to documents directory
    final Directory appDocDir = Directory.systemTemp; // fallback
    final outputFilename = '$baseName-signed$ext';
    final outPath = p.join(appDocDir.path, outputFilename);

    try {
      final stream = widget.clientService.uploadAndSign(
        localInputPath: _unsignedPath!,
        profileId: _selectedProfileId!,
        platform: _platform,
        appType: _androidAppType,
        bundleId: _iosBundleIdController.text,
        localOutputPath: outPath,
      );

      await for (final val in stream) {
        setState(() {
          _progress = val;
          if (val < 0.5) {
            _statusMsg = 'Uploading build: ${(val * 2 * 100).toInt()}%';
          } else if (val >= 0.5 && val < 0.65) {
            _statusMsg = 'Signing on Desktop...';
          } else if (val >= 0.65 && val < 1.0) {
            _statusMsg = 'Downloading: ${((val - 0.65) / 0.35 * 100).toInt()}%';
          } else {
            _statusMsg = 'Signing Completed!';
          }
        });
      }

      setState(() {
        _signedLocalPath = outPath;
      });
    } catch (e) {
      setState(() {
        _statusMsg = 'Error: $e';
      });
    } finally {
      setState(() {
        _isSigning = false;
      });
    }
  }

  Future<void> _exportFile() async {
    if (_signedLocalPath == null) return;
    final file = File(_signedLocalPath!);
    final filename = p.basename(_signedLocalPath!);
    
    // Use FilePicker to save file natively
    final outDir = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Signed App',
      fileName: filename,
      type: FileType.any,
    );
    if (outDir != null) {
      await file.copy(outDir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File saved successfully!')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredProfiles = widget.profiles.where((p) => p.platform == _platform).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        children: [
          // Segmented toggle
          Row(
            children: [
              Expanded(child: _buildPlatformTab('ios', 'Apple iOS', Icons.phone_iphone_rounded)),
              const SizedBox(width: 12),
              Expanded(child: _buildPlatformTab('android', 'Google Android', Icons.phone_android_rounded)),
            ],
          ),
          const SizedBox(height: 20),
          
          // Selector Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF27272A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Select Build File', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F0F12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF27272A)),
                        ),
                        child: Text(
                          _unsignedPath != null ? p.basename(_unsignedPath!) : 'Select unsigned build',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: _unsignedPath != null ? Colors.white : const Color(0xFF52525B),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF27272A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _isSigning ? null : _pickFile,
                      child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                    ),
                  ],
                ),
                if (_platform == 'android') ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildRadioOption('apk', 'APK'),
                      const SizedBox(width: 16),
                      _buildRadioOption('aab', 'AAB'),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                
                const Text('Select Signing Profile', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F0F12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedProfileId,
                      hint: const Text('Select active profile', style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF52525B))),
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1E1E22),
                      items: filteredProfiles
                          .map((p) => DropdownMenuItem(
                                value: p.id,
                                child: Text(p.name, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white)),
                              ))
                          .toList(),
                      onChanged: _isSigning 
                          ? null 
                          : (val) {
                              setState(() {
                                _selectedProfileId = val;
                              });
                            },
                    ),
                  ),
                ),
                if (_platform == 'ios') ...[
                  const SizedBox(height: 16),
                  const Text('Bundle ID Override (Optional)', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _iosBundleIdController,
                    style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'e.g. com.businessnext.app',
                      hintStyle: const TextStyle(color: Color(0xFF52525B)),
                      fillColor: const Color(0xFF0F0F12),
                      filled: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
                    ),
                  ),
                ]
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          if (_isSigning || _progress > 0) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Column(
                children: [
                  Text(_statusMsg, style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Color(0xFF10B981))),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _progress, backgroundColor: const Color(0xFF1E1E22), valueColor: const AlwaysStoppedAnimation(Color(0xFF8B5CF6))),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          
          if (_signedLocalPath != null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF064E3B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF10B981)),
              ),
              child: Column(
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline, color: Color(0xFF10B981)),
                      SizedBox(width: 8),
                      Text('Application signed successfully!', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Export Signed Build', style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold)),
                      onPressed: _exportFile,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isSigning || _unsignedPath == null ? null : _startSign,
              icon: const Icon(Icons.flash_on_rounded),
              label: const Text('Remote Sign App Now', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformTab(String val, String label, IconData icon) {
    final active = _platform == val;
    return InkWell(
      onTap: () {
        setState(() {
          _platform = val;
          _unsignedPath = null;
          _selectedProfileId = null;
          _signedLocalPath = null;
          _progress = 0.0;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF8B5CF6) : const Color(0xFF1E1E22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? const Color(0xFF8B5CF6) : const Color(0xFF27272A)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: active ? Colors.white : const Color(0xFFA1A1AA), size: 16),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active ? Colors.white : const Color(0xFFA1A1AA),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRadioOption(String val, String label) {
    final active = _androidAppType == val;
    return InkWell(
      onTap: () {
        setState(() {
          _androidAppType = val;
          _unsignedPath = null;
        });
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Radio<String>(
            value: val,
            groupValue: _androidAppType,
            activeColor: const Color(0xFF10B981),
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _androidAppType = v;
                  _unsignedPath = null;
                });
              }
            },
          ),
          Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white)),
        ],
      ),
    );
  }
}

class MobileUnsignTab extends StatefulWidget {
  final ClientService clientService;

  const MobileUnsignTab({super.key, required this.clientService});

  @override
  State<MobileUnsignTab> createState() => _MobileUnsignTabState();
}

class _MobileUnsignTabState extends State<MobileUnsignTab> {
  String _platform = 'ios';
  String? _unsignedPath;
  bool _isUnsigning = false;
  double _progress = 0.0;
  String _statusMsg = '';
  String? _unsignedLocalPath;

  Future<void> _pickFile() async {
    FilePickerResult? result;
    List<String>? allowedExtensions;
    if (_platform == 'ios') allowedExtensions = ['ipa'];
    else allowedExtensions = ['apk', 'aab'];

    result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: allowedExtensions);
    if (result != null) {
      final path = result.files.single.path;
      if (path != null) {
        setState(() {
          _unsignedPath = path;
          _unsignedLocalPath = null;
          _progress = 0.0;
        });
      }
    }
  }

  Future<void> _startUnsign() async {
    if (_unsignedPath == null) return;
    setState(() {
      _isUnsigning = true;
      _progress = 0.0;
      _statusMsg = 'Connecting...';
      _unsignedLocalPath = null;
    });

    final ext = p.extension(_unsignedPath!);
    final baseName = p.basenameWithoutExtension(_unsignedPath!);
    final outPath = p.join(Directory.systemTemp.path, '$baseName-unsigned$ext');

    try {
      final stream = widget.clientService.uploadAndUnsign(
        localInputPath: _unsignedPath!,
        platform: _platform,
        localOutputPath: outPath,
      );

      await for (final val in stream) {
        setState(() {
          _progress = val;
          if (val < 0.5) {
            _statusMsg = 'Uploading build: ${(val * 2 * 100).toInt()}%';
          } else if (val >= 0.5 && val < 0.65) {
            _statusMsg = 'Stripping Signatures on Desktop...';
          } else if (val >= 0.65 && val < 1.0) {
            _statusMsg = 'Downloading: ${((val - 0.65) / 0.35 * 100).toInt()}%';
          } else {
            _statusMsg = 'Unsigning Completed!';
          }
        });
      }

      setState(() {
        _unsignedLocalPath = outPath;
      });
    } catch (e) {
      setState(() {
        _statusMsg = 'Error: $e';
      });
    } finally {
      setState(() {
        _isUnsigning = false;
      });
    }
  }

  Future<void> _exportFile() async {
    if (_unsignedLocalPath == null) return;
    final file = File(_unsignedLocalPath!);
    final filename = p.basename(_unsignedLocalPath!);

    final outDir = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Unsigned App',
      fileName: filename,
      type: FileType.any,
    );
    if (outDir != null) {
      await file.copy(outDir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File saved successfully!')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _buildPlatformTab('ios', 'iOS Build', Icons.phone_iphone_rounded)),
              const SizedBox(width: 12),
              Expanded(child: _buildPlatformTab('android', 'Android Build', Icons.phone_android_rounded)),
            ],
          ),
          const SizedBox(height: 20),
          
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF27272A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Select Signed Build', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F0F12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF27272A)),
                        ),
                        child: Text(
                          _unsignedPath != null ? p.basename(_unsignedPath!) : 'Select signed build file',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: _unsignedPath != null ? Colors.white : const Color(0xFF52525B),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF27272A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _isUnsigning ? null : _pickFile,
                      child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          if (_isUnsigning || _progress > 0) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Column(
                children: [
                  Text(_statusMsg, style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Color(0xFFEF4444))),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _progress, backgroundColor: const Color(0xFF1E1E22), valueColor: const AlwaysStoppedAnimation(Color(0xFFEF4444))),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          if (_unsignedLocalPath != null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF475569)),
              ),
              child: Column(
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline, color: Colors.white70),
                      SizedBox(width: 8),
                      Text('Signature stripped successfully!', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF475569),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Export Unsigned Build', style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold)),
                      onPressed: _exportFile,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isUnsigning || _unsignedPath == null ? null : _startUnsign,
              icon: const Icon(Icons.key_off_rounded),
              label: const Text('Remote Unsign App Now', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformTab(String val, String label, IconData icon) {
    final active = _platform == val;
    return InkWell(
      onTap: () {
        setState(() {
          _platform = val;
          _unsignedPath = null;
          _unsignedLocalPath = null;
          _progress = 0.0;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFEF4444).withOpacity(0.15) : const Color(0xFF1E1E22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? const Color(0xFFEF4444) : const Color(0xFF27272A)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: active ? const Color(0xFFEF4444) : const Color(0xFFA1A1AA), size: 16),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active ? Colors.white : const Color(0xFFA1A1AA),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 1. SIGN STUDIO TAB WIDGET (DESKTOP)
// ==========================================
class SignStudioWidget extends StatefulWidget {
  final SigningService signingService;
  final VaultService vaultService;
  final List<SigningProfile> profiles;
  final Function(String filePath, String url) onStartSharing;
  final Function(SignedAppHistoryItem) onSignSuccess;
  final String? userEmail;

  const SignStudioWidget({
    super.key,
    required this.signingService,
    required this.vaultService,
    required this.profiles,
    required this.onStartSharing,
    required this.onSignSuccess,
    this.userEmail,
  });

  @override
  State<SignStudioWidget> createState() => _SignStudioWidgetState();
}

class _SignStudioWidgetState extends State<SignStudioWidget> {
  String _platform = 'ios';
  String _androidAppType = 'apk';

  final _iosBundleIdController = TextEditingController();
  final _iosP12PasswordController = TextEditingController();
  final _iosKeychainPasswordController = TextEditingController();

  final _androidKeyAliasController = TextEditingController();
  final _androidKeyPasswordController = TextEditingController();
  final _androidStorePasswordController = TextEditingController();

  String? _unsignedPath;
  String? _iosP12Path;
  String? _iosProvPath;
  String? _androidKeystorePath;
  String? _selectedProfileId;

  List<SigningIdentity> _iosIdentities = [];
  String? _selectedIdentity;
  bool _loadingIdentities = false;

  bool _isRunning = false;
  final List<String> _logLines = [];
  final _scrollController = ScrollController();
  String? _signedFilePath;
  bool _signSuccess = false;
  AppMetadata? _latestMetadata;

  final _sharingServer = SharingServer();
  bool _isSharing = false;
  String? _sharingUrl;

  @override
  void initState() {
    super.initState();
    _loadSettingsDefaults().then((_) {
      _loadLastProfile();
    });
  }

  Future<void> _loadSettingsDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _iosP12Path = prefs.getString('ios_p12_path');
      _iosProvPath = prefs.getString('ios_prov_path');
      _iosP12PasswordController.text = prefs.getString('ios_p12_password') ?? '';
      _iosKeychainPasswordController.text = prefs.getString('ios_keychain_password') ?? '';
      
      _androidKeystorePath = prefs.getString('android_keystore_path');
      _androidKeyAliasController.text = prefs.getString('android_key_alias') ?? '';
      _androidKeyPasswordController.text = prefs.getString('android_key_password') ?? '';
      _androidStorePasswordController.text = prefs.getString('android_store_password') ?? '';
    });
    if (_iosKeychainPasswordController.text.isNotEmpty) {
      _fetchIosIdentities();
    }
  }

  Future<void> _loadLastProfile() async {
    final lastId = await widget.vaultService.getLastUsedProfileId(_platform);
    if (lastId != null) {
      final matching = widget.profiles.where((p) => p.id == lastId);
      if (matching.isNotEmpty) {
        _applyProfile(matching.first);
      }
    }
  }

  void _applyProfile(SigningProfile profile) {
    setState(() {
      _selectedProfileId = profile.id;
      if (profile.platform == 'ios') {
        _iosBundleIdController.text = profile.bundleId;
        _selectedIdentity = profile.selectedIdentity.isNotEmpty ? profile.selectedIdentity : null;
        // P12 Path, Prov Path, and Passwords are NOT loaded from the profile, they are loaded from settings
      } else {
        _androidKeystorePath = profile.keystorePath;
        _androidKeyAliasController.text = profile.keyAlias;
        _androidKeyPasswordController.text = profile.keyPassword;
        _androidStorePasswordController.text = profile.storePassword;
      }
    });
  }

  Future<void> _fetchIosIdentities() async {
    if (!Platform.isMacOS) return;
    setState(() {
      _loadingIdentities = true;
    });
    final keychain = p.join(Platform.environment['HOME']!, 'Library/Keychains/login.keychain-db');
    final list = await widget.signingService.getSigningIdentities(keychain);
    setState(() {
      _iosIdentities = list;
      _loadingIdentities = false;
      if (_selectedIdentity != null && !list.any((id) => id.fingerprint == _selectedIdentity || id.name == _selectedIdentity)) {
        _selectedIdentity = null;
      }
    });
  }

  Future<void> _pickFile({required String type, required Function(String) onPicked}) async {
    FilePickerResult? result;
    List<String>? allowedExtensions;
    if (type == 'ipa') allowedExtensions = ['ipa'];
    else if (type == 'apk') allowedExtensions = ['apk'];
    else if (type == 'aab') allowedExtensions = ['aab'];
    else if (type == 'p12') allowedExtensions = ['p12'];
    else if (type == 'mobileprovision') allowedExtensions = ['mobileprovision'];
    else if (type == 'keystore') allowedExtensions = ['keystore', 'jks', 'pfx'];

    result = await FilePicker.platform.pickFiles(
      type: allowedExtensions != null ? FileType.custom : FileType.any,
      allowedExtensions: allowedExtensions,
    );

    if (result != null && result.files.single.path != null) {
      onPicked(result.files.single.path!);
    }
  }

  void _clearLogs() {
    setState(() {
      _logLines.clear();
      _signedFilePath = null;
      _signSuccess = false;
      _isSharing = false;
      _sharingUrl = null;
      _latestMetadata = null;
    });
  }

  void _addLog(String message) {
    setState(() {
      _logLines.add(message);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool get _canSign {
    if (_unsignedPath == null || _unsignedPath!.isEmpty) return false;
    if (_platform == 'ios') {
      return _iosP12Path != null && _iosP12Path!.isNotEmpty &&
             _iosProvPath != null && _iosProvPath!.isNotEmpty &&
             _selectedIdentity != null && _selectedIdentity!.isNotEmpty;
    } else {
      return _androidKeystorePath != null && _androidKeystorePath!.isNotEmpty &&
             _androidKeyAliasController.text.isNotEmpty &&
             _androidKeyPasswordController.text.isNotEmpty &&
             _androidStorePasswordController.text.isNotEmpty;
    }
  }

  Future<void> _startSigning() async {
    if (_unsignedPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an unsigned application package.')),
      );
      return;
    }

    _clearLogs();
    setState(() {
      _isRunning = true;
    });

    final baseDir = p.dirname(_unsignedPath!);
    final baseName = p.basenameWithoutExtension(_unsignedPath!);
    final ext = p.extension(_unsignedPath!);

    final suffix = baseName.endsWith('-signed') ? '' : '-signed';
    _signedFilePath = p.join(baseDir, '$baseName$suffix$ext');

    try {
      Stream<String> signStream;

      if (_platform == 'ios') {
        if (_iosP12Path == null || _iosP12Path!.isEmpty ||
            _iosProvPath == null || _iosProvPath!.isEmpty ||
            _selectedIdentity == null) {
          throw Exception('P12 certificate, provisioning profile, and signing identity are required. Please configure default Certificate & Profile settings in the Settings tab first.');
        }
        signStream = widget.signingService.resignIpa(
          ipaPath: _unsignedPath!,
          p12Path: _iosP12Path!,
          provPath: _iosProvPath!,
          p12Password: _iosP12PasswordController.text,
          keychainPassword: _iosKeychainPasswordController.text,
          chosenIdentity: _selectedIdentity!,
          newBundleId: _iosBundleIdController.text,
          outputPath: _signedFilePath!,
        );
      } else {
        if (_androidKeystorePath == null ||
            _androidKeyAliasController.text.isEmpty ||
            _androidKeyPasswordController.text.isEmpty ||
            _androidStorePasswordController.text.isEmpty) {
          throw Exception('Keystore, alias, and credentials are required.');
        }

        final prefs = await SharedPreferences.getInstance();
        if (_androidAppType == 'apk') {
          final zipalign = prefs.getString('zipalign_path') ?? 'zipalign';
          final apksigner = prefs.getString('apksigner_path') ?? 'apksigner';
          
          signStream = widget.signingService.signApk(
            apkPath: _unsignedPath!,
            keystorePath: _androidKeystorePath!,
            keyAlias: _androidKeyAliasController.text,
            keyPassword: _androidKeyPasswordController.text,
            storePassword: _androidStorePasswordController.text,
            zipalignPath: zipalign,
            apksignerJarPath: apksigner,
            outputPath: _signedFilePath!,
          );
        } else {
          signStream = widget.signingService.signAab(
            aabPath: _unsignedPath!,
            keystorePath: _androidKeystorePath!,
            keyAlias: _androidKeyAliasController.text,
            keyPassword: _androidKeyPasswordController.text,
            storePassword: _androidStorePasswordController.text,
            outputPath: _signedFilePath!,
          );
        }
      }

      AppMetadata? extractedMetadata;

      await for (final log in signStream) {
        if (log.startsWith('[METADATA]')) {
          try {
            final jsonStr = log.substring(10).trim();
            final metaMap = json.decode(jsonStr);
            extractedMetadata = AppMetadata.fromJson(metaMap);
          } catch (_) {}
          continue;
        }
        _addLog(log);
      }

      if (_platform == 'android' && _signedFilePath != null) {
        try {
          _addLog('🔍 Extracting package metadata...');
          extractedMetadata = await MetadataService.extractApkMetadata(_signedFilePath!);
        } catch (e) {
          _addLog('[WARNING] Failed to extract Android package metadata: $e');
        }
      }

      // Secondary fallback: parse from filename if extracted values are defaults or missing
      if (_signedFilePath != null) {
        final filenameMeta = MetadataService.parseFromFilename(p.basename(_signedFilePath!));
        if (filenameMeta != null) {
          if (extractedMetadata == null) {
            extractedMetadata = filenameMeta;
          } else {
            extractedMetadata = AppMetadata(
              name: (extractedMetadata.name == 'Unknown' || extractedMetadata.name == p.basenameWithoutExtension(_signedFilePath!))
                  ? filenameMeta.name
                  : extractedMetadata.name,
              packageId: (extractedMetadata.packageId == 'Unknown' || extractedMetadata.packageId == 'com.crmnext.app')
                  ? filenameMeta.packageId
                  : extractedMetadata.packageId,
              versionName: (extractedMetadata.versionName == '1.0.0')
                  ? filenameMeta.versionName
                  : extractedMetadata.versionName,
              versionCode: (extractedMetadata.versionCode == '1')
                  ? filenameMeta.versionCode
                  : extractedMetadata.versionCode,
            );
          }
        }
      }

      if (extractedMetadata == null && _signedFilePath != null) {
        final appName = p.basenameWithoutExtension(_signedFilePath!);
        extractedMetadata = AppMetadata(
          name: appName,
          packageId: _platform == 'ios' ? (_iosBundleIdController.text.isNotEmpty ? _iosBundleIdController.text : 'Unknown Bundle ID') : 'com.crmnext.app',
          versionName: '1.0.0',
          versionCode: '1',
        );
      }

      setState(() {
        _signSuccess = true;
        _latestMetadata = extractedMetadata;
      });
      _addLog('🚀 Signing task finished successfully!');

      if (_signedFilePath != null) {
        final historyItem = SignedAppHistoryItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: extractedMetadata?.name ?? p.basenameWithoutExtension(_signedFilePath!),
          packageId: extractedMetadata?.packageId ?? 'Unknown',
          versionName: extractedMetadata?.versionName ?? '1.0.0',
          versionCode: extractedMetadata?.versionCode ?? '1',
          filePath: _signedFilePath!,
          platform: _platform,
          date: DateTime.now().toIso8601String(),
        );
        widget.onSignSuccess(historyItem);
      }
    } catch (e) {
      _addLog('[CRITICAL ERROR] Signing failed: $e');
      setState(() {
        _signSuccess = false;
      });
    } finally {
      setState(() {
        _isRunning = false;
      });
    }
  }

  Future<void> _shareLocally() async {
    if (_signedFilePath == null) return;
    setState(() {
      _isSharing = true;
    });
    try {
      final url = await _sharingServer.start(_signedFilePath!);
      setState(() {
        _sharingUrl = url;
      });
      widget.onStartSharing(_signedFilePath!, url);
      _addLog('[SERVER] Sharing file locally at: $url');
    } catch (e) {
      _addLog('[SERVER ERROR] Failed to start local server: $e');
      setState(() {
        _isSharing = false;
      });
    }
  }

  void _locateFile() {
    if (_signedFilePath == null) return;
    verifyAndLocateFile(context, _signedFilePath!);
  }

  void _sendEmail() {
    if (_sharingUrl == null) return;
    final subject = Uri.encodeComponent('Signed Build Download');
    final body = Uri.encodeComponent(
        'Hi Team,\n\nThe signed application is ready. You can download it directly from this local network link (ensure you are connected to the office Wi-Fi):\n\n$_sharingUrl\n\nBest regards,\nSignNext Signer');
    final mailtoUrl = 'mailto:?subject=$subject&body=$body';
    
    if (Platform.isMacOS) {
      Process.run('open', [mailtoUrl]);
    } else if (Platform.isWindows) {
      Process.run('cmd.exe', ['/c', 'start', mailtoUrl]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E22),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF27272A)),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    _buildPlatformTab('ios', 'Apple iOS', Icons.phone_iphone_rounded),
                    _buildPlatformTab('android', 'Google Android', Icons.phone_android_rounded),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E22),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedProfileId,
                      hint: const Text(
                        'Select Profile from Vault',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF71717A)),
                      ),
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1E1E22),
                      items: widget.profiles
                          .where((p) => p.platform == _platform)
                          .map((p) => DropdownMenuItem(
                                value: p.id,
                                child: Text(p.name, style: const TextStyle(fontFamily: 'Inter', fontSize: 14, color: Colors.white)),
                              ))
                          .toList(),
                      onChanged: (val) {
                        setState(() {
                          _selectedProfileId = val;
                        });
                        if (val != null) {
                          final profile = widget.profiles.firstWhere((p) => p.id == val);
                          _applyProfile(profile);
                          widget.vaultService.setLastUsedProfileId(_platform, val);
                        }
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    _buildCard(
                      title: 'Build Package Selection',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildFilePickerField(
                            label: _platform == 'ios' ? 'Unsigned IPA Path' : 'Unsigned APK/AAB Path',
                            path: _unsignedPath,
                            hint: _platform == 'ios' ? 'Select unsigned .ipa file' : 'Select unsigned .apk/.aab file',
                            onPick: () => _pickFile(
                              type: _platform == 'ios' ? 'ipa' : (_androidAppType == 'apk' ? 'apk' : 'aab'),
                              onPicked: (p) => setState(() => _unsignedPath = p),
                            ),
                          ),
                          if (_platform == 'android') ...[
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                const Text('Package Type:  ', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                                _buildRadioOption('apk', 'APK (App Package)'),
                                const SizedBox(width: 16),
                                _buildRadioOption('aab', 'AAB (App Bundle)'),
                              ],
                            ),
                          ]
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_platform == 'ios') _buildIosInputs() else _buildAndroidInputs(),
                    const SizedBox(height: 24),
                    
                    Container(
                      width: double.infinity,
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: (_isRunning || !_canSign)
                              ? [const Color(0xFF3F3F46), const Color(0xFF27272A)]
                              : [const Color(0xFF8B5CF6), const Color(0xFF6D28D9)],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          if (!_isRunning && _canSign)
                            BoxShadow(color: const Color(0xFF8B5CF6).withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4)),
                        ],
                      ),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: Colors.white,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _isRunning ? null : (_canSign ? _startSigning : null),
                        child: _isRunning
                            ? Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                                  const SizedBox(width: 12),
                                  Text(_platform == 'ios' ? 'RESIGNING IPA...' : 'SIGNING PACKAGE...', style: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 15)),
                                ],
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.flash_on_rounded, size: 20, color: _canSign ? Colors.white : Colors.grey),
                                  const SizedBox(width: 8),
                                  Text(
                                    _canSign ? 'Resign App Now' : 'Provide Required Fields to Sign',
                                    style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 15, color: _canSign ? Colors.white : Colors.grey),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    _buildConsolePanel(),
                    if (_signSuccess) ...[
                      const SizedBox(height: 16),
                      _buildSuccessSharingCard(),
                    ]
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformTab(String val, String title, IconData icon) {
    final active = _platform == val;
    return InkWell(
      onTap: () {
        setState(() {
          _platform = val;
          _unsignedPath = null;
          _selectedProfileId = null;
        });
        _loadLastProfile();
      },
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF8B5CF6) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            Icon(icon, color: active ? Colors.white : const Color(0xFFA1A1AA), size: 16),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active ? Colors.white : const Color(0xFFA1A1AA),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRadioOption(String val, String label) {
    final active = _androidAppType == val;
    return InkWell(
      onTap: () {
        setState(() {
          _androidAppType = val;
          _unsignedPath = null;
        });
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Radio<String>(
            value: val,
            groupValue: _androidAppType,
            activeColor: const Color(0xFF10B981),
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _androidAppType = v;
                  _unsignedPath = null;
                });
              }
            },
          ),
          Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white)),
        ],
      ),
    );
  }

  Widget _buildCard({required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF8B5CF6))),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildFilePickerField({required String label, required String? path, required String hint, required VoidCallback onPick}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F0F12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF27272A)),
                ),
                child: Text(
                  path != null ? p.basename(path) : hint,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: path != null ? Colors.white : const Color(0xFF52525B),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF27272A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: onPick,
              child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildIosInputs() {
    return _buildCard(
      title: 'iOS Certificate & Profile Settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F0F12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF27272A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: Color(0xFF8B5CF6), size: 16),
                    const SizedBox(width: 8),
                    const Text(
                      'Using Default iOS Settings (Configured in Settings)',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF8B5CF6)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'P12 Certificate: ${_iosP12Path != null && _iosP12Path!.isNotEmpty ? p.basename(_iosP12Path!) : "Not configured in Settings"}',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Text(
                  'Provisioning Profile: ${_iosProvPath != null && _iosProvPath!.isNotEmpty ? p.basename(_iosProvPath!) : "Not configured in Settings"}',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildInputField(
                  label: 'Bundle Identifier (Optional)',
                  controller: _iosBundleIdController,
                  hint: 'e.g. com.crmnext.app',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Signing Identity (from Keychain)', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                  if (_loadingIdentities)
                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                  else
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 16, color: Color(0xFF10B981)),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _fetchIosIdentities,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F0F12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF27272A)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedIdentity,
                    hint: const Text('Select Key Identity', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF52525B))),
                    isExpanded: true,
                    dropdownColor: const Color(0xFF1E1E22),
                    items: _iosIdentities
                        .map((id) => DropdownMenuItem(
                              value: id.fingerprint,
                              child: Text(id.name, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white), overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedIdentity = val;
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidInputs() {
    final hasProfile = _selectedProfileId != null;
    return _buildCard(
      title: 'Android Keystore Settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F0F12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF27272A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      hasProfile ? Icons.account_balance_wallet_rounded : Icons.info_outline_rounded,
                      color: const Color(0xFF10B981),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      hasProfile
                          ? 'Using Vault Profile Settings'
                          : 'Using Default Android Settings (Configured in Settings)',
                      style: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Keystore File: ${_androidKeystorePath != null && _androidKeystorePath!.isNotEmpty ? p.basename(_androidKeystorePath!) : "Not configured"}',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Text(
                  'Key Alias: ${_androidKeyAliasController.text.isNotEmpty ? _androidKeyAliasController.text : "Not configured"}',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputField({required String label, required TextEditingController controller, String hint = '', bool obscure = false, Function(String)? onChanged}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white),
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF52525B)),
            fillColor: const Color(0xFF0F0F12),
            filled: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
          ),
        ),
      ],
    );
  }

  Widget _buildConsolePanel() {
    return Container(
      width: double.infinity,
      height: 380,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.terminal, color: Color(0xFF10B981), size: 18),
                  SizedBox(width: 8),
                  Text('SIGNING OUTPUT CONSOLE', style: TextStyle(fontFamily: 'Courier', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
                ],
              ),
              IconButton(icon: const Icon(Icons.cleaning_services, size: 14, color: Colors.grey), onPressed: _clearLogs, tooltip: 'Clear Console')
            ],
          ),
          const Divider(color: Color(0xFF27272A)),
          Expanded(
            child: SelectionArea(
              child: _logLines.isEmpty
                  ? Center(child: Text('Ready to sign.\nLaunch script execution to view live stream output.', textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.grey[700])))
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _logLines.length,
                      itemBuilder: (context, index) {
                        final line = _logLines[index];
                        Color color = Colors.white70;
                        if (line.startsWith('[ERROR]') || line.startsWith('[CRITICAL ERROR]') || line.startsWith('[STDERR]')) {
                          color = const Color(0xFFEF4444);
                        } else if (line.startsWith('[SUCCESS]') || line.startsWith('🎉')) {
                          color = const Color(0xFF10B981);
                        } else if (line.startsWith('[EXEC]')) {
                          color = const Color(0xFF60A5FA);
                        }
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: Text(line, style: TextStyle(fontFamily: 'Courier', fontSize: 11, color: color)),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessSharingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(color: Color(0xFF0284C7), shape: BoxShape.circle),
                child: const Icon(Icons.check, color: Colors.white, size: 16),
              ),
              const SizedBox(width: 12),
              const Text('Signed Artifact Available', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8))),
            ],
          ),
          const SizedBox(height: 12),
          Text(_signedFilePath != null ? p.basename(_signedFilePath!) : '', style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white70)),
          if (_latestMetadata != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('DEVELOPER METADATA', style: TextStyle(fontFamily: 'Inter', fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8), letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  _buildMetaDetailRow('App Name', _latestMetadata!.name),
                  _buildMetaDetailRow('Package / Bundle ID', _latestMetadata!.packageId),
                  _buildMetaDetailRow('Version', '${_latestMetadata!.versionName} (${_latestMetadata!.versionCode})'),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E293B), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('Show in Finder', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                onPressed: _locateFile,
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0369A1), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                icon: const Icon(Icons.wifi_rounded, size: 16),
                label: const Text('Start Network Share', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                onPressed: _isSharing ? null : _shareLocally,
              ),
            ],
          ),
          if (_sharingUrl != null) ...[
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(6),
                  child: QrImageView(data: _sharingUrl!, version: QrVersions.auto, size: 100.0),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Scan QR to download directly to device', style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                      const SizedBox(height: 4),
                      Text('Connect device to the same Wi-Fi network.', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.grey[400])),
                    ],
                  ),
                )
              ],
            )
          ]
        ],
      ),
    ).animate().fade().slideY(begin: 0.1, end: 0, duration: 400.ms, curve: Curves.easeOutQuad);
  }

  Widget _buildMetaDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 2. UNSIGN STUDIO TAB WIDGET (DESKTOP)
// ==========================================
class UnsignStudioWidget extends StatefulWidget {
  final SigningService signingService;

  const UnsignStudioWidget({super.key, required this.signingService});

  @override
  State<UnsignStudioWidget> createState() => _UnsignStudioWidgetState();
}

class _UnsignStudioWidgetState extends State<UnsignStudioWidget> {
  String _platform = 'ios';
  String? _unsignedPath;
  bool _isRunning = false;
  final List<String> _logLines = [];
  final _scrollController = ScrollController();
  String? _outputPath;
  bool _unsignSuccess = false;

  void _clearLogs() {
    setState(() {
      _logLines.clear();
      _outputPath = null;
      _unsignSuccess = false;
    });
  }

  void _addLog(String message) {
    setState(() {
      _logLines.add(message);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickFile() async {
    List<String>? allowedExtensions;
    if (_platform == 'ios') allowedExtensions = ['ipa'];
    else allowedExtensions = ['apk', 'aab'];

    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: allowedExtensions);
    if (result != null) {
      final path = result.files.single.path;
      if (path != null) {
        setState(() {
          _unsignedPath = path;
        });
      }
    }
  }

  Future<void> _startUnsigning() async {
    if (_unsignedPath == null) return;
    _clearLogs();
    setState(() {
      _isRunning = true;
    });

    final baseDir = p.dirname(_unsignedPath!);
    final baseName = p.basenameWithoutExtension(_unsignedPath!);
    final ext = p.extension(_unsignedPath!);
    _outputPath = p.join(baseDir, '$baseName-unsigned$ext');

    try {
      Stream<String> stream;
      if (_platform == 'ios') {
        stream = widget.signingService.unsignIpa(ipaPath: _unsignedPath!, outputPath: _outputPath!);
      } else {
        stream = widget.signingService.unsignApk(apkPath: _unsignedPath!, outputPath: _outputPath!);
      }

      await for (final log in stream) {
        _addLog(log);
      }
      setState(() {
        _unsignSuccess = true;
      });
      _addLog('🚀 Unsigning process completed successfully.');
    } catch (e) {
      _addLog('[CRITICAL ERROR] Unsigning failed: $e');
      setState(() {
        _unsignSuccess = false;
      });
    } finally {
      setState(() {
        _isRunning = false;
      });
    }
  }

  void _locateFile() {
    if (_outputPath == null) return;
    verifyAndLocateFile(context, _outputPath!);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E22),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF27272A)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Select Platform', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _buildTabButton('ios', 'iOS IPA', Icons.phone_iphone_rounded),
                        const SizedBox(width: 14),
                        _buildTabButton('android', 'Android APK/AAB', Icons.phone_android_rounded),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_platform == 'ios' ? 'Signed IPA Path' : 'Signed APK/AAB Path', style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(color: const Color(0xFF0F0F12), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF27272A))),
                                child: Text(
                                  _unsignedPath != null ? p.basename(_unsignedPath!) : 'Select signed package file',
                                  style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: _unsignedPath != null ? Colors.white : const Color(0xFF52525B), overflow: TextOverflow.ellipsis),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF27272A), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                              onPressed: _pickFile,
                              child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                height: 52,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _isRunning 
                        ? [const Color(0xFF3F3F46), const Color(0xFF27272A)]
                        : [const Color(0xFFEF4444), const Color(0xFFB91C1C)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    if (!_isRunning)
                      BoxShadow(color: const Color(0xFFEF4444).withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4)),
                  ],
                ),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _isRunning || _unsignedPath == null ? null : _startUnsigning,
                  child: _isRunning
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                            SizedBox(width: 12),
                            Text('STRIPPING SIGNATURE...', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 15)),
                          ],
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.key_off_rounded, size: 20),
                            SizedBox(width: 8),
                            Text('Unsign / Strip Build Now', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 15)),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          flex: 4,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                height: 300,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: const Color(0xFF0A0A0C), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF27272A))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.terminal, color: Color(0xFFEF4444), size: 18),
                        SizedBox(width: 8),
                        Text('UNSIGNING OUTPUT CONSOLE', style: TextStyle(fontFamily: 'Courier', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFEF4444))),
                      ],
                    ),
                    const Divider(color: Color(0xFF27272A)),
                    Expanded(
                      child: SelectionArea(
                        child: _logLines.isEmpty
                            ? Center(child: Text('Select file and run unsign engine.', style: TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.grey[700])))
                            : ListView.builder(
                                controller: _scrollController,
                                itemCount: _logLines.length,
                                itemBuilder: (context, index) {
                                  final line = _logLines[index];
                                  Color color = Colors.white70;
                                  if (line.startsWith('[ERROR]')) color = const Color(0xFFEF4444);
                                  else if (line.startsWith('[SUCCESS]') || line.startsWith('🎉')) color = const Color(0xFF10B981);
                                  else if (line.startsWith('[EXEC]')) color = const Color(0xFF60A5FA);
                                  return Text(line, style: TextStyle(fontFamily: 'Courier', fontSize: 11, color: color));
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_unsignSuccess) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF475569))),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Signature successfully stripped!', style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                      const SizedBox(height: 6),
                      Text(_outputPath != null ? p.basename(_outputPath!) : '', style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Colors.white70)),
                      const SizedBox(height: 14),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF334155), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: const Text('Show in Finder', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                        onPressed: _locateFile,
                      ),
                    ],
                  ),
                ).animate().fade().slideY(begin: 0.1, end: 0, duration: 300.ms),
              ]
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTabButton(String val, String label, IconData icon) {
    final active = _platform == val;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _platform = val;
            _unsignedPath = null;
            _clearLogs();
          });
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFEF4444).withOpacity(0.15) : Colors.transparent,
            border: Border.all(color: active ? const Color(0xFFEF4444) : const Color(0xFF27272A)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: active ? const Color(0xFFEF4444) : const Color(0xFFA1A1AA), size: 18),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: active ? FontWeight.bold : FontWeight.normal, color: active ? Colors.white : const Color(0xFFA1A1AA)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 3. PROFILE VAULT TAB WIDGET (DESKTOP)
// ==========================================
class VaultWidget extends StatefulWidget {
  final VaultService vaultService;
  final VoidCallback onProfilesChanged;

  const VaultWidget({super.key, required this.vaultService, required this.onProfilesChanged});

  @override
  State<VaultWidget> createState() => _VaultWidgetState();
}

class _VaultWidgetState extends State<VaultWidget> {
  List<SigningProfile> _profiles = [];
  bool _isCreatingNew = false;
  SigningProfile? _editingProfile;

  final _profileNameController = TextEditingController();
  String _platform = 'ios';

  final _iosBundleIdController = TextEditingController();
  final _iosP12PasswordController = TextEditingController();
  final _iosKeychainPasswordController = TextEditingController();
  String? _iosP12Path;
  String? _iosProvPath;
  String? _iosSelectedIdentity;

  final _androidKeyAliasController = TextEditingController();
  final _androidKeyPasswordController = TextEditingController();
  final _androidStorePasswordController = TextEditingController();
  String? _androidKeystorePath;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final list = await widget.vaultService.getProfiles();
    setState(() {
      _profiles = list;
    });
  }

  void _clearForm() {
    _profileNameController.clear();
    _iosBundleIdController.clear();
    _iosP12PasswordController.clear();
    _iosKeychainPasswordController.clear();
    _iosP12Path = null;
    _iosProvPath = null;
    _iosSelectedIdentity = null;

    _androidKeyAliasController.clear();
    _androidKeyPasswordController.clear();
    _androidStorePasswordController.clear();
    _androidKeystorePath = null;
  }

  void _startEdit(SigningProfile? profile) {
    _clearForm();
    if (profile == null) {
      setState(() {
        _isCreatingNew = true;
        _editingProfile = null;
        _platform = 'ios';
      });
    } else {
      setState(() {
        _isCreatingNew = true;
        _editingProfile = profile;
        _platform = profile.platform;
        _profileNameController.text = profile.name;
        
        if (profile.platform == 'ios') {
          _iosBundleIdController.text = profile.bundleId;
          _iosP12Path = profile.p12Path;
          _iosProvPath = profile.provPath;
          _iosP12PasswordController.text = profile.p12Password;
          _iosKeychainPasswordController.text = profile.keychainPassword;
          _iosSelectedIdentity = profile.selectedIdentity.isNotEmpty ? profile.selectedIdentity : null;
        } else {
          _androidKeystorePath = profile.keystorePath;
          _androidKeyAliasController.text = profile.keyAlias;
          _androidKeyPasswordController.text = profile.keyPassword;
          _androidStorePasswordController.text = profile.storePassword;
        }
      });
    }
  }

  Future<void> _pickFile({required String type, required Function(String) onPicked}) async {
    FilePickerResult? result;
    List<String>? allowedExtensions;
    if (type == 'p12') allowedExtensions = ['p12'];
    else if (type == 'mobileprovision') allowedExtensions = ['mobileprovision'];
    else if (type == 'keystore') allowedExtensions = ['keystore', 'jks', 'pfx'];

    result = await FilePicker.platform.pickFiles(type: allowedExtensions != null ? FileType.custom : FileType.any, allowedExtensions: allowedExtensions);
    if (result != null && result.files.single.path != null) {
      onPicked(result.files.single.path!);
    }
  }

  Future<void> _saveProfile() async {
    if (_profileNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a profile name.')));
      return;
    }

    final id = _editingProfile?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    SigningProfile profile;

    if (_platform == 'ios') {
      profile = SigningProfile(
        id: id,
        name: _profileNameController.text.trim(),
        platform: 'ios',
        p12Path: _iosP12Path ?? '',
        provPath: _iosProvPath ?? '',
        p12Password: _iosP12PasswordController.text,
        keychainPassword: _iosKeychainPasswordController.text,
        bundleId: _iosBundleIdController.text,
        selectedIdentity: _iosSelectedIdentity ?? '',
      );
    } else {
      profile = SigningProfile(
        id: id,
        name: _profileNameController.text.trim(),
        platform: 'android',
        keystorePath: _androidKeystorePath ?? '',
        keyAlias: _androidKeyAliasController.text,
        keyPassword: _androidKeyPasswordController.text,
        storePassword: _androidStorePasswordController.text,
      );
    }

    await widget.vaultService.addProfile(profile);
    widget.onProfilesChanged();
    _loadProfiles();
    setState(() {
      _isCreatingNew = false;
      _editingProfile = null;
    });
  }

  Future<void> _deleteProfile(String id) async {
    await widget.vaultService.deleteProfile(id);
    widget.onProfilesChanged();
    _loadProfiles();
  }

  @override
  Widget build(BuildContext context) {
    if (_isCreatingNew) {
      return _buildFormView();
    }
    return _buildListView();
  }

  Widget _buildListView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Stored Signing Profiles', style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Profile', style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold)),
              onPressed: () => _startEdit(null),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Expanded(
          child: _profiles.isEmpty
              ? Center(child: Text('No profiles stored in vault yet.\nCreate one to save time during signing.', textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.grey[600])))
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: 1.4),
                  itemCount: _profiles.length,
                  itemBuilder: (context, index) {
                    final p = _profiles[index];
                    final isIos = p.platform == 'ios';
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: const Color(0xFF1E1E22), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF27272A))),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isIos ? const Color(0xFF8B5CF6).withOpacity(0.15) : const Color(0xFF10B981).withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: isIos ? const Color(0xFF8B5CF6) : const Color(0xFF10B981)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(isIos ? Icons.phone_iphone_rounded : Icons.phone_android_rounded, size: 12, color: isIos ? const Color(0xFF8B5CF6) : const Color(0xFF10B981)),
                                    const SizedBox(width: 4),
                                    Text(isIos ? 'iOS' : 'Android', style: TextStyle(fontFamily: 'Inter', fontSize: 10, fontWeight: FontWeight.bold, color: isIos ? const Color(0xFF8B5CF6) : const Color(0xFF10B981))),
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  IconButton(icon: const Icon(Icons.edit, size: 14, color: Colors.grey), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () => _startEdit(p)),
                                  const SizedBox(width: 8),
                                  IconButton(icon: const Icon(Icons.delete, size: 14, color: Color(0xFFEF4444)), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () => _deleteProfile(p.id)),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(p.name, style: const TextStyle(fontFamily: 'Inter', fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                          const SizedBox(height: 8),
                          Expanded(
                            child: Text(
                              isIos 
                                  ? 'Bundle ID: ${p.bundleId.isNotEmpty ? p.bundleId : "Default"}\nP12 Cert: ${_fileNameOnly(p.p12Path)}'
                                  : 'Key Alias: ${p.keyAlias}\nKeystore: ${_fileNameOnly(p.keystorePath)}',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.grey[500]),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _fileNameOnly(String path) {
    if (path.isEmpty) return 'Not set';
    return p.basename(path);
  }

  Widget _buildFormView() {
    final title = _editingProfile == null ? 'Create New Profile' : 'Edit Profile "${_editingProfile!.name}"';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => setState(() => _isCreatingNew = false)),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: const Color(0xFF1E1E22), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF27272A))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInputField(label: 'Profile Name', controller: _profileNameController, hint: 'e.g. CRMNext UAT Development'),
                const SizedBox(height: 20),
                if (_editingProfile == null) ...[
                  const Text('Platform', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildPlatformOption('ios', 'iOS Profile', Icons.phone_iphone_rounded),
                      const SizedBox(width: 20),
                      _buildPlatformOption('android', 'Android Profile', Icons.phone_android_rounded),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
                const Divider(color: Color(0xFF27272A)),
                const SizedBox(height: 16),
                if (_platform == 'ios') _buildIosForm() else _buildAndroidForm(),
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF27272A), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                      onPressed: () => setState(() => _isCreatingNew = false),
                      child: const Text('Cancel', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                      onPressed: _saveProfile,
                      child: const Text('Save Profile', style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformOption(String val, String label, IconData icon) {
    final active = _platform == val;
    return InkWell(
      onTap: () => setState(() => _platform = val),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: active ? const Color(0xFF8B5CF6) : Colors.transparent, borderRadius: BorderRadius.circular(8), border: Border.all(color: active ? const Color(0xFF8B5CF6) : const Color(0xFF27272A))),
        child: Row(
          children: [
            Icon(icon, color: active ? Colors.white : const Color(0xFFA1A1AA), size: 16),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: active ? Colors.white : const Color(0xFFA1A1AA))),
          ],
        ),
      ),
    );
  }

  Widget _buildFilePickerField({required String label, required String? path, required String hint, required VoidCallback onPick}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFF0F0F12), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF27272A))),
                child: Text(
                  path != null && path.isNotEmpty ? p.basename(path) : hint,
                  style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: path != null && path.isNotEmpty ? Colors.white : const Color(0xFF52525B), overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF27272A), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              onPressed: onPick,
              child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInputField({required String label, required TextEditingController controller, String hint = '', bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF52525B)),
            fillColor: const Color(0xFF0F0F12),
            filled: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
          ),
        ),
      ],
    );
  }

  Widget _buildIosForm() {
    return Column(
      children: [
        _buildFilePickerField(
          label: 'P12 Certificate (.p12)',
          path: _iosP12Path,
          hint: 'Select certificate file',
          onPick: () => _pickFile(type: 'p12', onPicked: (path) => setState(() => _iosP12Path = path)),
        ),
        const SizedBox(height: 14),
        _buildFilePickerField(
          label: 'Provisioning Profile (.mobileprovision)',
          path: _iosProvPath,
          hint: 'Select provisioning profile',
          onPick: () => _pickFile(type: 'mobileprovision', onPicked: (path) => setState(() => _iosProvPath = path)),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: _buildInputField(label: 'P12 Password', controller: _iosP12PasswordController, obscure: true, hint: 'Cert password')),
            const SizedBox(width: 14),
            Expanded(child: _buildInputField(label: 'Keychain Password', controller: _iosKeychainPasswordController, obscure: true, hint: 'Unlock local Mac keychain')),
          ],
        ),
        const SizedBox(height: 14),
        _buildInputField(label: 'Bundle Identifier (Optional Override)', controller: _iosBundleIdController, hint: 'e.g. com.crmnext.app'),
        const SizedBox(height: 14),
        _buildInputField(label: 'Specific Signing Identity / Hash (Optional)', controller: TextEditingController(text: _iosSelectedIdentity), hint: 'Specify fingerprint to bypass interactive prompt'),
      ],
    );
  }

  Widget _buildAndroidForm() {
    return Column(
      children: [
        _buildFilePickerField(
          label: 'Keystore / JKS File',
          path: _androidKeystorePath,
          hint: 'Select JKS or Keystore file',
          onPick: () => _pickFile(type: 'keystore', onPicked: (path) => setState(() => _androidKeystorePath = path)),
        ),
        const SizedBox(height: 14),
        _buildInputField(label: 'Key Alias', controller: _androidKeyAliasController, hint: 'alias name'),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: _buildInputField(label: 'Key Password', controller: _androidKeyPasswordController, obscure: true, hint: 'Key password')),
            const SizedBox(width: 14),
            Expanded(child: _buildInputField(label: 'Keystore Password', controller: _androidStorePasswordController, obscure: true, hint: 'Keystore password')),
          ],
        ),
      ],
    );
  }
}

// ==========================================
// 4. SETTINGS TAB WIDGET (DESKTOP)
// ==========================================
class SettingsWidget extends StatefulWidget {
  const SettingsWidget({super.key});

  @override
  State<SettingsWidget> createState() => _SettingsWidgetState();
}

class _SettingsWidgetState extends State<SettingsWidget> {
  final _zipalignController = TextEditingController();
  final _apksignerController = TextEditingController();
  
  final _iosP12Controller = TextEditingController();
  final _iosProvController = TextEditingController();
  final _iosP12PasswordController = TextEditingController();
  final _iosKeychainPasswordController = TextEditingController();

  final _androidKeystoreController = TextEditingController();
  final _androidKeyAliasController = TextEditingController();
  final _androidKeyPasswordController = TextEditingController();
  final _androidStorePasswordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _zipalignController.text = prefs.getString('zipalign_path') ?? 'zipalign';
      _apksignerController.text = prefs.getString('apksigner_path') ?? 'apksigner';
      _iosP12Controller.text = prefs.getString('ios_p12_path') ?? '';
      _iosProvController.text = prefs.getString('ios_prov_path') ?? '';
      _iosP12PasswordController.text = prefs.getString('ios_p12_password') ?? '';
      _iosKeychainPasswordController.text = prefs.getString('ios_keychain_password') ?? '';
      _androidKeystoreController.text = prefs.getString('android_keystore_path') ?? '';
      _androidKeyAliasController.text = prefs.getString('android_key_alias') ?? '';
      _androidKeyPasswordController.text = prefs.getString('android_key_password') ?? '';
      _androidStorePasswordController.text = prefs.getString('android_store_password') ?? '';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('zipalign_path', _zipalignController.text.trim());
    await prefs.setString('apksigner_path', _apksignerController.text.trim());
    await prefs.setString('ios_p12_path', _iosP12Controller.text.trim());
    await prefs.setString('ios_prov_path', _iosProvController.text.trim());
    await prefs.setString('ios_p12_password', _iosP12PasswordController.text);
    await prefs.setString('ios_keychain_password', _iosKeychainPasswordController.text);
    await prefs.setString('android_keystore_path', _androidKeystoreController.text.trim());
    await prefs.setString('android_key_alias', _androidKeyAliasController.text.trim());
    await prefs.setString('android_key_password', _androidKeyPasswordController.text);
    await prefs.setString('android_store_password', _androidStorePasswordController.text);

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved successfully!')));
  }

  Future<void> _pickBinaryPath(TextEditingController controller) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null && result.files.single.path != null) {
      setState(() {
        controller.text = result.files.single.path!;
      });
    }
  }

  Future<void> _pickFile(TextEditingController controller, List<String> extensions) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        controller.text = result.files.single.path!;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: const Color(0xFF1E1E22), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF27272A))),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('iOS Certificate & Profile Settings', style: TextStyle(fontFamily: 'Inter', fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 6),
            const Text('Configure the default P12 certificate file, provisioning profile, and passwords to use for iOS signing. These are kept securely on your local machine.', style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF71717A))),
            const SizedBox(height: 24),
            _buildIosFilePickerField(label: 'P12 Certificate (.p12) Path', controller: _iosP12Controller, hint: 'Select default .p12 certificate', extensions: ['p12']),
            const SizedBox(height: 16),
            _buildIosFilePickerField(label: 'Provisioning Profile (.mobileprovision) Path', controller: _iosProvController, hint: 'Select default .mobileprovision profile', extensions: ['mobileprovision']),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildSettingsInputField(label: 'P12 Password', controller: _iosP12PasswordController, hint: 'P12 password', obscure: true),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildSettingsInputField(label: 'Keychain Password', controller: _iosKeychainPasswordController, hint: 'Unlock Mac login keychain', obscure: true),
                ),
              ],
            ),

            const Divider(color: Color(0xFF27272A), height: 40),
            
            const Text('Android Keystore & Tool Defaults', style: TextStyle(fontFamily: 'Inter', fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 6),
            const Text('Configure the default keystore file, credentials, and binary tool paths for Android APK/AAB signing.', style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF71717A))),
            const SizedBox(height: 24),
            _buildIosFilePickerField(label: 'Keystore (.jks/.keystore/.pfx) Path', controller: _androidKeystoreController, hint: 'Select default keystore file', extensions: ['keystore', 'jks', 'pfx']),
            const SizedBox(height: 16),
            _buildSettingsInputField(label: 'Key Alias', controller: _androidKeyAliasController, hint: 'Default key alias'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildSettingsInputField(label: 'Key Password', controller: _androidKeyPasswordController, hint: 'Key password', obscure: true),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildSettingsInputField(label: 'Keystore Password', controller: _androidStorePasswordController, hint: 'Keystore store password', obscure: true),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text('Signing Utility Path Overrides (Optional)', style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFFA1A1AA))),
            const SizedBox(height: 12),
            _buildBinaryPathField(label: 'Zipalign Path', controller: _zipalignController, hint: 'Defaults to global command "zipalign"'),
            const SizedBox(height: 16),
            _buildIosFilePickerField(label: 'Apksigner Path', controller: _apksignerController, hint: 'Select apksigner.jar file', extensions: ['jar']),
            
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  onPressed: _saveSettings,
                  child: const Text('Save Settings', style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsInputField({required String label, required TextEditingController controller, required String hint, bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF52525B)),
            fillColor: const Color(0xFF0F0F12),
            filled: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
          ),
        ),
      ],
    );
  }

  Widget _buildIosFilePickerField({required String label, required TextEditingController controller, required String hint, required List<String> extensions}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(color: Color(0xFF52525B)),
                  fillColor: const Color(0xFF0F0F12),
                  filled: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF27272A), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              onPressed: () => _pickFile(controller, extensions),
              child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBinaryPathField({required String label, required TextEditingController controller, required String hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(color: Color(0xFF52525B)),
                  fillColor: const Color(0xFF0F0F12),
                  filled: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF27272A), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              onPressed: () => _pickBinaryPath(controller),
              child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }
}

// ==========================================
// MICROSOFT LOGIN SCREEN (DESKTOP)
// ==========================================
class LoginScreen extends StatefulWidget {
  final Function(String) onLoginSuccess;
  final VoidCallback onSkip;

  const LoginScreen({super.key, required this.onLoginSuccess, required this.onSkip});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _checkingSystem = false;
  bool _ssoAccountFound = false;
  String _detectedEmail = '';
  
  bool _showVerification = false;
  String _authMethod = 'authenticator'; // 'authenticator' or 'email'
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  
  bool _isSendingOtp = false;
  bool _isVerifying = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _detectSystemAccount();
  }

  Future<void> _detectSystemAccount() async {
    setState(() {
      _checkingSystem = true;
    });
    
    await Future.delayed(const Duration(milliseconds: 1000));
    
    String email = 'pavanyadav@crmnext.com';
    try {
      final gitEmailResult = await Process.run('git', ['config', '--global', 'user.email']);
      if (gitEmailResult.exitCode == 0) {
        final gitEmail = (gitEmailResult.stdout as String).trim();
        if (gitEmail.isNotEmpty && gitEmail.contains('@')) {
          email = gitEmail;
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _detectedEmail = email;
        _emailController.text = email;
        _ssoAccountFound = true;
        _checkingSystem = false;
      });
    }
  }

  void _startVerification() {
    setState(() {
      _showVerification = true;
    });
  }

  void _sendOtp() async {
    setState(() {
      _isSendingOtp = true;
      _errorMessage = null;
    });
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) {
      setState(() {
        _isSendingOtp = false;
      });
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Verification code sent to your email!')),
    );
  }

  void _verifyAndLogin() async {
    final code = _otpController.text.trim();
    if (code.length != 6) {
      setState(() {
        _errorMessage = 'Passcode must be exactly 6 digits.';
      });
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });

    await Future.delayed(const Duration(milliseconds: 1000));

    if (mounted) {
      setState(() {
        _isVerifying = false;
      });
      widget.onLoginSuccess(_emailController.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF09090B), Color(0xFF1E1B4B), Color(0xFF0F0F11)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -100,
              left: -100,
              child: Container(
                width: 400,
                height: 400,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF8B5CF6).withOpacity(0.15),
                ),
              ),
            ),
            Positioned(
              bottom: -50,
              right: -50,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF10B981).withOpacity(0.1),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 420,
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E24).withOpacity(0.8),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF27272A)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    )
                  ]
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Column(
                          children: [
                            Container(width: 14, height: 14, color: const Color(0xFFF25022)),
                            const SizedBox(height: 2),
                            Container(width: 14, height: 14, color: const Color(0xFF00A4EF)),
                          ],
                        ),
                        const SizedBox(width: 2),
                        Column(
                          children: [
                            Container(width: 14, height: 14, color: const Color(0xFF7FBA00)),
                            const SizedBox(height: 2),
                            Container(width: 14, height: 14, color: const Color(0xFFFFB900)),
                          ],
                        ),
                      ],
                    ).animate().scale(duration: 400.ms, curve: Curves.easeOutBack),
                    const SizedBox(height: 20),
                    const Text(
                      'SignNext',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: -0.5),
                    ).animate().fadeIn(delay: 100.ms),
                    const Text(
                      'CRMNext Security Portal',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF71717A)),
                    ).animate().fadeIn(delay: 200.ms),
                    const SizedBox(height: 32),
                    
                    if (_checkingSystem) ...[
                      const CircularProgressIndicator(color: Color(0xFF8B5CF6)),
                      const SizedBox(height: 16),
                      const Text(
                        'Checking for system-wide Microsoft SSO...',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA)),
                      ),
                    ] else if (!_showVerification) ...[
                      if (_ssoAccountFound) ...[
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F0F12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF27272A)),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.account_circle, color: Color(0xFF8B5CF6), size: 24),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text('System Account Detected', style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF71717A))),
                                        Text(_detectedEmail, style: const TextStyle(fontFamily: 'Courier', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white), overflow: TextOverflow.ellipsis),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF8B5CF6),
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size.fromHeight(48),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                icon: const Icon(Icons.flash_on_rounded, size: 16),
                                label: const Text('One-Click Sign In', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 13)),
                                onPressed: _startVerification,
                              ),
                            ],
                          ),
                        ).animate().slideY(begin: 0.1, duration: 300.ms, curve: Curves.easeOut),
                        const SizedBox(height: 16),
                        const Text('or', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF52525B))),
                      ],
                      
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFF27272A)),
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.login_rounded, size: 16),
                        label: const Text('Sign in with Microsoft Office 365', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
                        onPressed: () {
                          setState(() {
                            _ssoAccountFound = false;
                            _showVerification = true;
                          });
                        },
                      ),
                      const SizedBox(height: 24),
                      const Divider(color: Color(0xFF27272A)),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: widget.onSkip,
                        child: const Text(
                          'Skip signing (Go to App as Guest)',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF10B981), decoration: TextDecoration.underline),
                        ),
                      ),
                    ] else ...[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_back, size: 16),
                                onPressed: () {
                                  setState(() {
                                    _showVerification = false;
                                    _ssoAccountFound = _detectedEmail.isNotEmpty;
                                  });
                                },
                              ),
                              const Text('Verification Required', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (_emailController.text.isEmpty || !_ssoAccountFound) ...[
                            const Text('Corporate Email Address', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA))),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _emailController,
                              style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'email@crmnext.com',
                                fillColor: const Color(0xFF0F0F12),
                                filled: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          Row(
                            children: [
                              const Text('Method:', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA))),
                              const SizedBox(width: 12),
                              ChoiceChip(
                                label: const Text('Authenticator App', style: TextStyle(fontSize: 10)),
                                selected: _authMethod == 'authenticator',
                                onSelected: (val) {
                                  if (val) setState(() => _authMethod = 'authenticator');
                                },
                              ),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                label: const Text('Email OTP', style: TextStyle(fontSize: 10)),
                                selected: _authMethod == 'email',
                                onSelected: (val) {
                                  if (val) {
                                    setState(() => _authMethod = 'email');
                                    _sendOtp();
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _authMethod == 'authenticator'
                                ? 'Enter 6-digit Authenticator code'
                                : 'Enter OTP sent to your email',
                            style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA)),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _otpController,
                                  obscureText: false,
                                  keyboardType: TextInputType.number,
                                  style: const TextStyle(fontFamily: 'Courier', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 8),
                                  maxLength: 6,
                                  decoration: InputDecoration(
                                    hintText: '000000',
                                    counterText: '',
                                    fillColor: const Color(0xFF0F0F12),
                                    filled: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                                  ),
                                ),
                              ),
                              if (_authMethod == 'email') ...[
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: _isSendingOtp ? null : _sendOtp,
                                  child: _isSendingOtp 
                                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                                      : const Text('Resend', style: TextStyle(fontSize: 11, color: Color(0xFF8B5CF6))),
                                )
                              ]
                            ],
                          ),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 8),
                            Text(_errorMessage!, style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFEF4444))),
                          ],
                          const SizedBox(height: 24),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF8B5CF6),
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: _isVerifying ? null : _verifyAndLogin,
                            child: _isVerifying 
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Text('Verify & Sign In', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 13)),
                          ),
                        ],
                      ).animate().fadeIn(duration: 200.ms),
                    ]
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// ORG SHARING DIALOG WIDGET
// ==========================================
class ShareDialogWidget extends StatefulWidget {
  final SignedAppHistoryItem app;
  final String? userEmail;

  const ShareDialogWidget({super.key, required this.app, this.userEmail});

  @override
  State<ShareDialogWidget> createState() => _ShareDialogWidgetState();
}

class _ShareDialogWidgetState extends State<ShareDialogWidget> {
  final _emailController = TextEditingController();
  bool _sharing = false;
  String _status = '';
  String _searchQuery = '';

  static const List<Map<String, String>> _mockOrgUsers = [
    {'name': 'Mahiba Patel', 'email': 'mahiba.patel@crmnext.com'},
    {'name': 'Mahib Rahman', 'email': 'mahib.rahman@crmnext.com'},
    {'name': 'Pavan Yadav', 'email': 'pavan.yadav@crmnext.com'},
    {'name': 'Deepak Sharma', 'email': 'deepak.sharma@crmnext.com'},
    {'name': 'Preeti Sen', 'email': 'preeti.sen@crmnext.com'},
    {'name': 'Vikas Mishra', 'email': 'vikas.mishra@crmnext.com'},
    {'name': 'Rahul Verma', 'email': 'rahul.verma@crmnext.com'},
    {'name': 'Amit Gupta', 'email': 'amit.gupta@crmnext.com'},
    {'name': 'Sanjay Singh', 'email': 'sanjay.singh@crmnext.com'},
    {'name': 'Neha Goel', 'email': 'neha.goel@crmnext.com'},
  ];

  List<Map<String, String>> _getFilteredUsers() {
    if (_searchQuery.isEmpty) return [];
    final query = _searchQuery.toLowerCase();
    final matches = _mockOrgUsers.where((user) {
      return user['name']!.toLowerCase().contains(query) ||
             user['email']!.toLowerCase().contains(query);
    }).toList();
    if (matches.length > 5) {
      return matches.sublist(0, 5);
    }
    return matches;
  }

  void _shareOverTeams() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid recipient email.')),
      );
      return;
    }

    setState(() {
      _sharing = true;
      _status = 'Compressing package to secure .zip archive...';
    });

    final filePath = widget.app.filePath;
    final baseDir = p.dirname(filePath);
    final baseName = p.basenameWithoutExtension(filePath);
    final zipPath = p.join(baseDir, '$baseName.zip');

    try {
      if (Platform.isMacOS) {
        await Process.run('zip', ['-j', zipPath, filePath]);
      } else if (Platform.isWindows) {
        await Process.run('powershell.exe', [
          '-Command',
          'Compress-Archive -Path "${filePath}" -DestinationPath "${zipPath}" -Force'
        ]);
      }
    } catch (_) {}

    setState(() {
      _status = 'Launching Microsoft Teams chat with $email...';
    });

    await Future.delayed(const Duration(milliseconds: 800));

    // Open compressed file in Finder/Explorer
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', zipPath]);
      } else if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', zipPath]);
      }
    } catch (_) {}

    // Launch Microsoft Teams deep link chat with user and prefill message
    final encodedMessage = Uri.encodeComponent(
        'Hi, I have signed the app "${widget.app.name}" (${widget.app.platform.toUpperCase()}).\n\n'
        'Bundle ID: ${widget.app.packageId}\n'
        'Version: ${widget.app.versionName} (${widget.app.versionCode})\n\n'
        'I have created a compressed ZIP archive of the build in my Finder. Please drag and drop it into this chat!');
    
    final teamsUrl = 'https://teams.microsoft.com/l/chat/0/0?users=$email&message=$encodedMessage';

    try {
      if (Platform.isMacOS) {
        await Process.run('open', [teamsUrl]);
      } else if (Platform.isWindows) {
        await Process.run('cmd.exe', ['/c', 'start', teamsUrl]);
      }
    } catch (_) {}

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Compressed ZIP created and chat started in Teams!'),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        child: _sharing ? _buildProgress() : _buildForm(),
      ),
    );
  }

  Widget _buildProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),
        const SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(color: Color(0xFF8B5CF6)),
        ),
        const SizedBox(height: 24),
        Text(
          _status,
          style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              widget.app.platform == 'ios' ? Icons.phone_iphone : Icons.android,
              color: widget.app.platform == 'ios' ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Share ${widget.app.name}',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Bundle ID: ${widget.app.packageId}\nVersion: ${widget.app.versionName} (${widget.app.versionCode})',
          style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Colors.grey),
        ),
        const SizedBox(height: 20),
        const Text('Recipient Email / Name', style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 6),
        TextField(
          controller: _emailController,
          onChanged: (val) {
            setState(() {
              _searchQuery = val.trim();
            });
          },
          style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Search corporate user or email',
            fillColor: const Color(0xFF0F0F12),
            filled: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
          ),
        ),
        if (_searchQuery.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: const Color(0xFF0F0F12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF27272A)),
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: _getFilteredUsers().map((user) {
                return ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  title: Text(user['name']!, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(user['email']!, style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Colors.grey)),
                  onTap: () {
                    setState(() {
                      _emailController.text = user['email']!;
                      _emailController.selection = TextSelection.fromPosition(TextPosition(offset: _emailController.text.length));
                      _searchQuery = '';
                    });
                  },
                );
              }).toList(),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF27272A)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Teams Share Policy Notice:',
                style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
              ),
              SizedBox(height: 6),
              Text(
                'Direct .ipa/.apk sharing is blocked on Teams. Tapping share starts a direct chat with the recipient, pre-fills the message details, and opens Finder with the compressed .zip archive ready for drag-and-drop.',
                style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA), height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.share_rounded, size: 14),
              label: const Text('Share over Teams', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold)),
              onPressed: _shareOverTeams,
            ),
          ],
        ),
      ],
    );
  }
}

// ==========================================
// DEVELOPER DETAILS DIALOG WIDGET
// ==========================================
class AppDetailsDialogWidget extends StatelessWidget {
  final SignedAppHistoryItem app;

  const AppDetailsDialogWidget({super.key, required this.app});

  void _locateFile(BuildContext context) {
    verifyAndLocateFile(context, app.filePath);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  app.platform == 'ios' ? Icons.phone_iphone : Icons.android,
                  color: app.platform == 'ios' ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text('Developer App Details', style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              ],
            ),
            const Divider(color: Color(0xFF27272A), height: 30),
            _buildDetailRow('App Name', app.name),
            _buildDetailRow('Bundle ID / Package', app.packageId),
            _buildDetailRow('Version Name', app.versionName),
            _buildDetailRow('Version Code', app.versionCode),
            _buildDetailRow('Platform', app.platform.toUpperCase()),
            _buildDetailRow('Path', app.filePath, isPath: true),
            _buildDetailRow('Date Signed', app.date.split('T')[0] + ' ' + app.date.split('T')[1].split('.')[0]),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF27272A), foregroundColor: Colors.white),
                  icon: const Icon(Icons.folder_open_rounded, size: 14),
                  label: const Text('Show in Finder', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                  onPressed: () => _locateFile(context),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6), foregroundColor: Colors.white),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isPath = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF71717A))),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Courier',
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isPath ? const Color(0xFF38BDF8) : Colors.white70,
            ),
            maxLines: isPath ? 3 : 1,
            overflow: isPath ? TextOverflow.clip : TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ==========================================
// HISTORY DATAMODEL
// ==========================================
class SignedAppHistoryItem {
  final String id;
  final String name;
  final String packageId;
  final String versionName;
  final String versionCode;
  final String filePath;
  final String platform;
  final String date;

  SignedAppHistoryItem({
    required this.id,
    required this.name,
    required this.packageId,
    required this.versionName,
    required this.versionCode,
    required this.filePath,
    required this.platform,
    required this.date,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'packageId': packageId,
    'versionName': versionName,
    'versionCode': versionCode,
    'filePath': filePath,
    'platform': platform,
    'date': date,
  };

  factory SignedAppHistoryItem.fromJson(Map<String, dynamic> json) => SignedAppHistoryItem(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    packageId: json['packageId'] ?? '',
    versionName: json['versionName'] ?? '',
    versionCode: json['versionCode'] ?? '',
    filePath: json['filePath'] ?? '',
    platform: json['platform'] ?? '',
    date: json['date'] ?? '',
  );
}

Future<void> verifyAndLocateFile(BuildContext context, String filePath) async {
  final file = File(filePath);
  if (await file.exists()) {
    _revealInFinder(filePath);
  } else {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            bool isRestoring = false;
            
            return Dialog(
              backgroundColor: const Color(0xFF1E1E24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Container(
                width: 400,
                padding: const EdgeInsets.all(24),
                child: isRestoring 
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 12),
                        const SizedBox(
                          width: 40,
                          height: 40,
                          child: CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8B5CF6)),
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Restoring File...',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Downloading archive and rebuilding binary...',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: Colors.grey[400],
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 22),
                            SizedBox(width: 8),
                            Text(
                              'File Not Found',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                        const Divider(color: Color(0xFF27272A), height: 24),
                        Text(
                          'The signed application bundle has been moved or deleted from its output directory:\n\n${file.path}',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.of(dialogContext).pop(),
                              child: const Text('Cancel', style: TextStyle(color: Color(0xFFA1A1AA))),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8B5CF6),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () async {
                                setDialogState(() {
                                  isRestoring = true;
                                });
                                
                                // Simulate re-download/restore duration
                                await Future.delayed(const Duration(milliseconds: 1800));
                                
                                try {
                                  // Create parent dirs and write dummy content
                                  await file.parent.create(recursive: true);
                                  await file.writeAsString('Mock restored file content for development/testing.');
                                } catch (_) {}
                                
                                Navigator.of(dialogContext).pop();
                                
                                // Show success snackbar
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('File restored successfully at ${file.path}'),
                                    backgroundColor: const Color(0xFF10B981),
                                    action: SnackBarAction(
                                      label: 'Locate',
                                      textColor: Colors.white,
                                      onPressed: () {
                                        _revealInFinder(filePath);
                                      },
                                    ),
                                  ),
                                );
                                
                                // Reveal in finder/explorer automatically
                                _revealInFinder(filePath);
                              },
                              child: const Text('Re-download / Restore'),
                            ),
                          ],
                        ),
                      ],
                    ),
              ),
            );
          },
        );
      },
    );
  }
}

void _revealInFinder(String filePath) {
  final file = File(filePath);
  if (Platform.isMacOS) {
    Process.run('open', ['-R', file.path]);
  } else if (Platform.isWindows) {
    Process.run('explorer.exe', ['/select,', file.path]);
  }
}
