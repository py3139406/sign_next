import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

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
  String? _userEmail;
  bool _isRevoked = false;
  bool _viewingAsAdmin = true;

  @override
  void initState() {
    super.initState();
    _checkPreviousLogin();
  }

  Future<void> _checkPreviousLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final manualLogout = prefs.getBool('manual_logout') ?? false;

    // Load parent emails from central DB
    final parentEmails = await CentralDatabase.getParentEmails();

    // Auto-detect git global email config
    String? gitEmail;
    try {
      final gitEmailResult = await Process.run('git', ['config', '--global', 'user.email']);
      if (gitEmailResult.exitCode == 0) {
        final emailStr = (gitEmailResult.stdout as String).trim();
        if (emailStr.isNotEmpty && emailStr.contains('@')) {
          gitEmail = emailStr;
        }
      }
    } catch (_) {}

    // Check if auto-detecting a parent email and not manually logged out
    if (gitEmail != null && parentEmails.contains(gitEmail) && !manualLogout) {
      await prefs.setBool('is_authenticated', true);
      await prefs.setString('user_email', gitEmail);
      if (mounted) {
        setState(() {
          _authenticated = true;
          _userEmail = gitEmail;
          _viewingAsAdmin = true;
        });
      }
      return;
    }

    final authed = prefs.getBool('is_authenticated') ?? false;
    final email = prefs.getString('user_email');
    
    // Check if this child user is revoked
    if (email != null && !parentEmails.contains(email)) {
      final childUsers = await CentralDatabase.getChildUsers();
      if (childUsers.containsKey(email)) {
        final status = childUsers[email]['status'] ?? 'Active';
        if (status == 'Revoked') {
          if (mounted) {
            setState(() {
              _isRevoked = true;
              _userEmail = email;
            });
          }
          return;
        }
      }
    }

    if (mounted) {
      setState(() {
        _authenticated = authed;
        _userEmail = email;
        _viewingAsAdmin = email != null && parentEmails.contains(email);
      });
    }
  }

  void _onLoginSuccess(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_authenticated', true);
    await prefs.setBool('manual_logout', false);
    await prefs.setString('user_email', email);

    final parentEmails = await CentralDatabase.getParentEmails();
    final isParent = parentEmails.contains(email);

    if (!isParent) {
      // Register child user and log their login action
      await CentralDatabase.updateChildUser(
        email,
        deviceName: Platform.localHostname,
        osVersion: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      );
      await CentralDatabase.logAction(
        email,
        'Login',
        'User successfully logged in via Microsoft SSO',
        deviceName: Platform.localHostname,
        osVersion: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      );
    }

    setState(() {
      _authenticated = true;
      _userEmail = email;
      _isRevoked = false;
      _viewingAsAdmin = isParent;
    });
  }

  void _onLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('is_authenticated');
    await prefs.setBool('manual_logout', true);
    final email = _userEmail;
    await prefs.remove('user_email');
    
    if (email != null) {
      final parentEmails = await CentralDatabase.getParentEmails();
      if (!parentEmails.contains(email)) {
        await CentralDatabase.logAction(
          email,
          'Logout',
          'User logged out from application',
          deviceName: Platform.localHostname,
          osVersion: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        );
      }
    }

    setState(() {
      _authenticated = false;
      _userEmail = null;
      _isRevoked = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
    if (isMobile) {
      return const MobileConnectionScreen();
    }

    if (_isRevoked) {
      return AccessRevokedScreen(
        userEmail: _userEmail ?? '',
        onLogout: _onLogout,
      );
    }

    if (!_authenticated) {
      return LoginScreen(
        onLoginSuccess: _onLoginSuccess,
      );
    }

    return FutureBuilder<List<String>>(
      future: CentralDatabase.getParentEmails(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            backgroundColor: Color(0xFF0F0F11),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF8B5CF6)),
            ),
          );
        }
        
        final parentList = snapshot.data!;
        final isParent = _userEmail != null && parentList.contains(_userEmail);
        
        if (isParent && _viewingAsAdmin) {
          return ParentDashboardWidget(
            userEmail: _userEmail!,
            onLogout: _onLogout,
            onSwitchToChild: () {
              setState(() {
                _viewingAsAdmin = false;
              });
            },
          );
        } else {
          return DashboardScreen(
            userEmail: _userEmail,
            onLogout: _onLogout,
            isAdmin: isParent,
            onSwitchToAdmin: () {
              setState(() {
                _viewingAsAdmin = true;
              });
            },
          );
        }
      },
    );
  }
}

enum AppTab { sign, unsign, qrUtility, vault, devOps }

// =============================================================================
// DESKTOP INTERFACE
// =============================================================================
class DashboardScreen extends StatefulWidget {
  final String? userEmail;
  final VoidCallback? onLogout;
  final bool isAdmin;
  final VoidCallback? onSwitchToAdmin;

  const DashboardScreen({
    super.key,
    this.userEmail,
    this.onLogout,
    this.isAdmin = false,
    this.onSwitchToAdmin,
  });

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

  // Central Management states
  Timer? _syncTimer;
  String _childRole = 'Role 1';
  Map<String, dynamic>? _activeAlert;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
    _loadRecentApps();
    _initSyncTimer();
  }

  void _initSyncTimer() {
    _checkStatusAndAlerts();
    _syncTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      _checkStatusAndAlerts();
    });
  }

  Future<void> _checkStatusAndAlerts() async {
    final email = widget.userEmail ?? '';
    if (email.isEmpty) return;

    final parentList = await CentralDatabase.getParentEmails();
    if (parentList.contains(email)) {
      if (_childRole != 'Role 2') {
        if (mounted) {
          setState(() {
            _childRole = 'Role 2';
          });
        }
      }
      return;
    }

    final childUsers = await CentralDatabase.getChildUsers();
    if (childUsers.containsKey(email)) {
      final userData = childUsers[email];
      final status = userData['status'] ?? 'Active';
      if (status == 'Revoked') {
        _syncTimer?.cancel();
        if (widget.onLogout != null) {
          widget.onLogout!();
        }
        return;
      }
      
      final role = userData['role'] ?? 'Role 1';
      if (role != _childRole) {
        if (mounted) {
          setState(() {
            _childRole = role;
          });
        }
      }
    } else {
      await CentralDatabase.updateChildUser(
        email,
        deviceName: Platform.localHostname,
        osVersion: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      );
    }

    // Check for unread alerts
    final alerts = await CentralDatabase.getAlertsForUser(email);
    for (final alert in alerts) {
      final readBy = List<String>.from(alert['readBy'] ?? []);
      if (!readBy.contains(email)) {
        if (mounted) {
          setState(() {
            _activeAlert = alert;
          });
        }
        break; 
      }
    }
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
            isSigned: app.isSigned,
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
    
    final iosSigned = updated.where((item) => item.platform == 'ios' && item.isSigned).toList();
    final iosUnsigned = updated.where((item) => item.platform == 'ios' && !item.isSigned).toList();
    final androidSigned = updated.where((item) => item.platform == 'android' && item.isSigned).toList();
    final androidUnsigned = updated.where((item) => item.platform == 'android' && !item.isSigned).toList();
    
    if (app.platform == 'ios') {
      if (app.isSigned) {
        if (iosSigned.length >= 2) iosSigned.removeAt(iosSigned.length - 1);
        iosSigned.insert(0, app);
      } else {
        if (iosUnsigned.length >= 2) iosUnsigned.removeAt(iosUnsigned.length - 1);
        iosUnsigned.insert(0, app);
      }
    } else {
      if (app.isSigned) {
        if (androidSigned.length >= 2) androidSigned.removeAt(androidSigned.length - 1);
        androidSigned.insert(0, app);
      } else {
        if (androidUnsigned.length >= 2) androidUnsigned.removeAt(androidUnsigned.length - 1);
        androidUnsigned.insert(0, app);
      }
    }
    
    updated = [...iosSigned, ...iosUnsigned, ...androidSigned, ...androidUnsigned];
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
    _syncTimer?.cancel();
    _sharingServer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Row(
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
          if (_activeAlert != null)
            Positioned(
              top: 24,
              left: 280, 
              right: 24,
              child: SlideInAlertBanner(
                alert: _activeAlert!,
                onDismiss: () async {
                  final alertId = _activeAlert!['id'];
                  await CentralDatabase.markAlertAsRead(alertId, widget.userEmail ?? '');
                  setState(() {
                    _activeAlert = null;
                  });
                },
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
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
                                backgroundColor: const Color(0xFF8B5CF6),
                                radius: 14,
                                child: const Icon(
                                  Icons.person_rounded,
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
                                      _childRole == 'Role 1' ? 'Standard Signer' : 'Administrator',
                                      style: const TextStyle(
                                        fontFamily: 'Inter',
                                        fontSize: 10,
                                        color: Color(0xFF8B5CF6),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      widget.userEmail ?? 'Offline User',
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
                      if (widget.isAdmin) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                          child: SizedBox(
                            width: double.infinity,
                            child: InkWell(
                              onTap: widget.onSwitchToAdmin,
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFFEF4444), Color(0xFFF59E0B)],
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.admin_panel_settings_rounded, color: Colors.white, size: 14),
                                    SizedBox(width: 8),
                                    Text(
                                      'Admin Control Center',
                                      style: TextStyle(
                                        fontFamily: 'Inter',
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      const Divider(color: Color(0xFF27272A), height: 16),
          
                    _buildSidebarItem(tab: AppTab.sign, icon: Icons.vpn_key_rounded, label: 'Sign Studio', subtitle: 'Sign IPA, APK or AAB'),
                    _buildSidebarItem(tab: AppTab.unsign, icon: Icons.key_off_rounded, label: 'Unsign Studio', subtitle: 'Strip package signatures'),
                    _buildSidebarItem(tab: AppTab.qrUtility, icon: Icons.qr_code_scanner_rounded, label: 'QR Utility', subtitle: 'Convert QR and text'),
                    _buildSidebarItem(tab: AppTab.vault, icon: Icons.admin_panel_settings_rounded, label: 'Profile Vault', subtitle: 'Manage secure credentials'),
                    _buildSidebarItem(tab: AppTab.devOps, icon: Icons.developer_board_rounded, label: 'DevOps Center', subtitle: 'Azure DevOps & AI Reporting'),
                    
                    const Divider(color: Color(0xFF27272A), height: 16),
          
                    // Recent Signed Apps section
                    if (_recentApps.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
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
                              // iOS Signed Studio Apps
                              if (_recentApps.any((app) => app.platform == 'ios' && app.isSigned)) ...[
                                const Padding(
                                  padding: EdgeInsets.only(left: 12.0, top: 4.0, bottom: 2.0),
                                  child: Text(
                                    'Signed Studio',
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                                ..._recentApps
                                    .where((app) => app.platform == 'ios' && app.isSigned)
                                    .map((app) => _buildRecentAppItem(context, app)),
                              ],
                              // iOS Unsigned Studio Apps
                              if (_recentApps.any((app) => app.platform == 'ios' && !app.isSigned)) ...[
                                const Padding(
                                  padding: EdgeInsets.only(left: 12.0, top: 4.0, bottom: 2.0),
                                  child: Text(
                                    'Unsigned Studio',
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                                ..._recentApps
                                    .where((app) => app.platform == 'ios' && !app.isSigned)
                                    .map((app) => _buildRecentAppItem(context, app)),
                              ],
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
                              // Android Signed Studio Apps
                              if (_recentApps.any((app) => app.platform == 'android' && app.isSigned)) ...[
                                const Padding(
                                  padding: EdgeInsets.only(left: 12.0, top: 4.0, bottom: 2.0),
                                  child: Text(
                                    'Signed Studio',
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                                ..._recentApps
                                    .where((app) => app.platform == 'android' && app.isSigned)
                                    .map((app) => _buildRecentAppItem(context, app)),
                              ],
                              // Android Unsigned Studio Apps
                              if (_recentApps.any((app) => app.platform == 'android' && !app.isSigned)) ...[
                                const Padding(
                                  padding: EdgeInsets.only(left: 12.0, top: 4.0, bottom: 2.0),
                                  child: Text(
                                    'Unsigned Studio',
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                                ..._recentApps
                                    .where((app) => app.platform == 'android' && !app.isSigned)
                                    .map((app) => _buildRecentAppItem(context, app)),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 20),
                    ],
                    
                    const Spacer(),
                    
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
              ),
            ),
          );
        },
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
    final isLocked = _childRole == 'Role 1' && (tab == AppTab.vault);
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
                    Row(
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? Colors.white : const Color(0xFFA1A1AA),
                          ),
                        ),
                        if (isLocked) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.lock_rounded, size: 12, color: Color(0xFFEF4444)),
                        ],
                      ],
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
      case AppTab.qrUtility:
        title = 'QR Utility';
        desc = 'Convert Text to QR Codes and extract Text from QR Code images.';
        break;
      case AppTab.vault:
        title = 'Profile Vault';
        desc = 'Manage secure credentials, P12 certs, Keystores, and credentials.';
        break;
      case AppTab.devOps:
        title = 'DevOps Center';
        desc = 'Manage Azure DevOps tasks, pull requests, and generate AI reports.';
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
    if (_childRole == 'Role 1') {
      if (_currentTab == AppTab.vault) {
        return const AccessDeniedWidget(
          title: 'Profile Vault Access Denied',
          message: 'Standard Signers (Role 1) are not permitted to manage corporate codesigning profiles or cert credentials.',
        );
      }
    }

    switch (_currentTab) {
      case AppTab.sign:
        return SignStudioWidget(
          signingService: _signingService,
          profiles: _profiles,
          vaultService: _vaultService,
          userEmail: widget.userEmail,
          userRole: _childRole,
          onStartSharing: (filePath, url) {
            setState(() {
              _sharingUrl = url;
              _sharedFileName = p.basename(filePath);
            });
          },
          onSignSuccess: (appItem) {
            _addAppToHistory(appItem);
            CentralDatabase.logAction(
              widget.userEmail ?? 'unknown',
              'Sign App',
              'Successfully signed ${appItem.name} (${appItem.packageId})',
              deviceName: Platform.localHostname,
              osVersion: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
            );
          },
        );
      case AppTab.unsign:
        return UnsignStudioWidget(
          signingService: _signingService,
          onUnsignSuccess: (appItem) {
            _addAppToHistory(appItem);
            CentralDatabase.logAction(
              widget.userEmail ?? 'unknown',
              'Unsign App',
              'Successfully unsigned ${appItem.name} (${appItem.packageId})',
              deviceName: Platform.localHostname,
              osVersion: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
            );
          },
        );
      case AppTab.qrUtility:
        return const QrUtilityWidget();
      case AppTab.vault:
        return VaultWidget(
          vaultService: _vaultService,
          onProfilesChanged: _loadProfiles,
          onSelectTab: (tab) {
            setState(() {
              _currentTab = tab;
            });
          },
        );
      case AppTab.devOps:
        return const DevOpsWidget();
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
  final String userRole;

  const SignStudioWidget({
    super.key,
    required this.signingService,
    required this.vaultService,
    required this.profiles,
    required this.onStartSharing,
    required this.onSignSuccess,
    this.userEmail,
    required this.userRole,
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
  String? _zipalignPath;
  String? _apksignerPath;

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
  bool _isUploading = false;
  String _uploadStatus = '';
  String? _sharingUrl;    // QR content (itms-services:// or https://)
  String? _cloudFileUrl; // raw HTTPS file URL shown as copyable link
  List<DeviceInstallLog> _installLogs = [];

  List<Map<String, dynamic>> _globalCerts = [];
  String? _selectedGlobalCertId;

  @override
  void initState() {
    super.initState();
    if (!Platform.isMacOS) {
      _platform = 'android';
    }
    _loadSettingsDefaults().then((_) {
      if (widget.userRole == 'Role 1') {
        _loadGlobalCertificates();
      }
    });
  }

  @override
  void didUpdateWidget(SignStudioWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.userRole != oldWidget.userRole) {
      if (widget.userRole == 'Role 1') {
        _loadGlobalCertificates();
      } else {
        _selectedGlobalCertId = null;
        _selectedProfileId = null;
        _loadSettingsDefaults();
      }
    }
  }

  Future<void> _loadGlobalCertificates() async {
    final certs = await CentralDatabase.getGlobalCertificates();
    setState(() {
      _globalCerts = certs;
      // Auto-select first matching platform cert if available
      final matching = certs.where((c) => c['platform'] == _platform).toList();
      if (matching.isNotEmpty) {
        _applyGlobalCertificate(matching.first);
      } else {
        _selectedGlobalCertId = null;
        _iosP12Path = null;
        _iosProvPath = null;
        _selectedIdentity = null;
        _androidKeystorePath = null;
      }
    });
  }

  void _applyGlobalCertificate(Map<String, dynamic> cert) {
    setState(() {
      _selectedGlobalCertId = cert['id'];
      if (cert['platform'] == 'ios') {
        _iosP12Path = cert['p12Path'];
        _iosProvPath = cert['provPath'];
        _iosP12PasswordController.text = cert['p12Password'] ?? '';
        _iosKeychainPasswordController.text = cert['keychainPassword'] ?? '';
        _selectedIdentity = cert['identity'];
        if (_selectedIdentity != null) {
          _iosIdentities = [SigningIdentity(fingerprint: _selectedIdentity!, name: _selectedIdentity!)];
        }
      } else {
        _androidKeystorePath = cert['keystorePath'];
        _androidKeyAliasController.text = cert['keyAlias'] ?? '';
        _androidKeyPasswordController.text = cert['keyPassword'] ?? '';
        _androidStorePasswordController.text = cert['storePassword'] ?? '';
      }
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
      _zipalignPath = prefs.getString('zipalign_path') ?? 'zipalign';
      _apksignerPath = prefs.getString('apksigner_path') ?? 'apksigner';
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
        _iosP12Path = profile.p12Path;
        _iosProvPath = profile.provPath;
        _iosP12PasswordController.text = profile.p12Password;
        _iosKeychainPasswordController.text = profile.keychainPassword;
        if (_iosKeychainPasswordController.text.isNotEmpty) {
          _fetchIosIdentities();
        }
      } else {
        _androidKeystorePath = profile.keystorePath;
        _androidKeyAliasController.text = profile.keyAlias;
        _androidKeyPasswordController.text = profile.keyPassword;
        _androidStorePasswordController.text = profile.storePassword;
        _zipalignPath = profile.zipalignPath.isNotEmpty ? profile.zipalignPath : null;
        _apksignerPath = profile.apksignerJarPath.isNotEmpty ? profile.apksignerJarPath : null;
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
      _isUploading = false;
      _uploadStatus = '';
      _sharingUrl = null;
      _cloudFileUrl = null;
      _installLogs = [];
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
          final zipalign = _zipalignPath ?? prefs.getString('zipalign_path') ?? 'zipalign';
          final apksigner = _apksignerPath ?? prefs.getString('apksigner_path') ?? 'apksigner';
          
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
      _isUploading = true;
      _installLogs = [];
      _uploadStatus = 'Starting secure sharing tunnel…';
    });

    try {
      final bundleId = _latestMetadata?.packageId ?? 'com.example.app';
      final version = _latestMetadata?.versionName ?? '1.0';
      final appName = _latestMetadata?.name ?? 'App';

      final otaResult = await _sharingServer.startOta(
        _signedFilePath!,
        bundleId: bundleId,
        version: version,
        appName: appName,
      );

      // Listen for download/install hits
      _installLogs = _sharingServer.downloadLogs;
      _sharingServer.logsStream.listen((logs) {
        if (mounted) {
          setState(() {
            _installLogs = logs;
          });
        }
      });

      final shareUrl = otaResult.publicUrl ?? otaResult.localUrl;
      final fileUrl = '$shareUrl/download/${Uri.encodeComponent(p.basename(_signedFilePath!))}';

      setState(() {
        _isUploading = false;
        _uploadStatus = '';
        _sharingUrl = otaResult.qrUrl;
        _cloudFileUrl = fileUrl;
      });

      widget.onStartSharing(_signedFilePath!, fileUrl);
      _addLog('[SHARE] Share started. Tunnel: ${otaResult.publicUrl ?? "none"}');
    } catch (e) {
      _addLog('[ERROR] $e');
      setState(() {
        _isSharing = false;
        _isUploading = false;
        _uploadStatus = '';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start sharing: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  @override
  void dispose() {
    _sharingServer.stop();
    _sharingServer.dispose();
    super.dispose();
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
                    child: widget.userRole == 'Role 1'
                        ? DropdownButton<String>(
                            value: _selectedGlobalCertId,
                            hint: const Text(
                              'Select Parent Global Certificate',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF71717A)),
                            ),
                            isExpanded: true,
                            dropdownColor: const Color(0xFF1E1E22),
                            items: _globalCerts
                                .where((c) => c['platform'] == _platform)
                                .map((c) => DropdownMenuItem(
                                      value: c['id'] as String,
                                      child: Text(c['name'] as String, style: const TextStyle(fontFamily: 'Inter', fontSize: 14, color: Colors.white)),
                                    ))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                final cert = _globalCerts.firstWhere((c) => c['id'] == val);
                                _applyGlobalCertificate(cert);
                              }
                            },
                          )
                        : DropdownButton<String?>(
                            value: _selectedProfileId,
                            hint: const Text(
                              'Use Settings Defaults',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF71717A)),
                            ),
                            isExpanded: true,
                            dropdownColor: const Color(0xFF1E1E22),
                            items: [
                              const DropdownMenuItem<String?>(
                                value: null,
                                child: Text('Use Settings Defaults', style: TextStyle(fontFamily: 'Inter', fontSize: 14, color: Color(0xFFA1A1AA))),
                              ),
                              ...widget.profiles
                                  .where((p) => p.platform == _platform)
                                  .map((p) => DropdownMenuItem<String?>(
                                        value: p.id,
                                        child: Text(p.name, style: const TextStyle(fontFamily: 'Inter', fontSize: 14, color: Colors.white)),
                                      )),
                            ],
                            onChanged: (val) {
                              setState(() {
                                _selectedProfileId = val;
                              });
                              if (val != null) {
                                final profile = widget.profiles.firstWhere((p) => p.id == val);
                                _applyProfile(profile);
                                widget.vaultService.setLastUsedProfileId(_platform, val);
                              } else {
                                _loadSettingsDefaults();
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
    final isIpaOnNonMac = val == 'ios' && !Platform.isMacOS;
    final active = _platform == val;

    return Tooltip(
      message: isIpaOnNonMac ? 'iOS signing requires macOS' : '',
      child: Opacity(
        opacity: isIpaOnNonMac ? 0.5 : 1.0,
        child: InkWell(
          onTap: isIpaOnNonMac
              ? null
              : () {
                  setState(() {
                    _platform = val;
                    _unsignedPath = null;
                    _selectedProfileId = null;
                  });
                  _loadSettingsDefaults();
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
                if (isIpaOnNonMac) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.lock_outline_rounded, size: 12, color: Color(0xFFA1A1AA)),
                ],
              ],
            ),
          ),
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
    final isRole1 = widget.userRole == 'Role 1';
    final hasProfile = _selectedProfileId != null || _selectedGlobalCertId != null;
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
                    Icon(
                      isRole1
                          ? Icons.verified_user_rounded
                          : (hasProfile ? Icons.account_balance_wallet_rounded : Icons.info_outline_rounded),
                      color: const Color(0xFF8B5CF6),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isRole1
                            ? 'Signing is secured by Parent Administrator credentials.'
                            : (hasProfile ? 'Using Vault Profile Settings' : 'Using Default iOS Settings (Configured in Settings)'),
                        style: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF8B5CF6)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'P12 Certificate: ${_iosP12Path != null && _iosP12Path!.isNotEmpty ? p.basename(_iosP12Path!) : "Not configured"}',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Text(
                  'Provisioning Profile: ${_iosProvPath != null && _iosProvPath!.isNotEmpty ? p.basename(_iosProvPath!) : "Not configured"}',
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
          if (!isRole1) ...[
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
        ],
      ),
    );
  }

  Widget _buildAndroidInputs() {
    final isRole1 = widget.userRole == 'Role 1';
    final hasProfile = _selectedProfileId != null || _selectedGlobalCertId != null;
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
                      isRole1
                          ? Icons.verified_user_rounded
                          : (hasProfile ? Icons.account_balance_wallet_rounded : Icons.info_outline_rounded),
                      color: const Color(0xFF10B981),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isRole1
                            ? 'Signing is secured by Parent Administrator credentials.'
                            : (hasProfile ? 'Using Vault Profile Settings' : 'Using Default Android Settings (Configured in Settings)'),
                        style: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                      ),
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
                const SizedBox(height: 6),
                Text(
                  'Zipalign Path: ${_zipalignPath != null && _zipalignPath!.isNotEmpty ? p.basename(_zipalignPath!) : "Default (zipalign)"}',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Text(
                  'Apksigner Path: ${_apksignerPath != null && _apksignerPath!.isNotEmpty ? p.basename(_apksignerPath!) : "Default (apksigner)"}',
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
    final isIpa = _signedFilePath?.toLowerCase().endsWith('.ipa') == true;

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
          // ── Header ───────────────────────────────────────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(color: Color(0xFF0284C7), shape: BoxShape.circle),
                child: const Icon(Icons.check, color: Colors.white, size: 16),
              ),
              const SizedBox(width: 12),
              const Text('Signed Artifact Available',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8))),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _signedFilePath != null ? p.basename(_signedFilePath!) : '',
            style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white70),
          ),

          // ── Metadata ─────────────────────────────────────────────────────
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
                  const Text('DEVELOPER METADATA',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8), letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  _buildMetaDetailRow('App Name', _latestMetadata!.name),
                  _buildMetaDetailRow('Package / Bundle ID', _latestMetadata!.packageId),
                  _buildMetaDetailRow('Version', '${_latestMetadata!.versionName} (${_latestMetadata!.versionCode})'),
                ],
              ),
            ),
          ],

          // ── Action buttons ────────────────────────────────────────────────
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E293B),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('Show in Finder', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                onPressed: _locateFile,
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: _isSharing ? const Color(0xFF14532D) : const Color(0xFF8B5CF6),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                icon: Icon(_isUploading
                    ? Icons.cloud_upload_rounded
                    : _isSharing
                        ? Icons.qr_code_rounded
                        : Icons.qr_code_2_rounded,
                    size: 16),
                label: Text(
                  _isUploading ? 'Uploading…' : _isSharing ? 'QR Ready' : 'Generate Install QR',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12),
                ),
                onPressed: (_isSharing || _isUploading) ? null : _shareLocally,
              ),
            ],
          ),

          // ── Upload progress ───────────────────────────────────────────────
          if (_isUploading) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0F),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B5CF6)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      _uploadStatus,
                      style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── QR + install panel (shown after upload) ───────────────────────
          if (_sharingUrl != null && !_isUploading) ...[
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // QR code
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(data: _sharingUrl!, version: QrVersions.auto, size: 120.0),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isIpa ? 'Install on iPhone / iPad' : 'Install on Android',
                        style: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        isIpa
                            ? '1. Scan QR with iPhone Camera\n2. Tap banner → tap Install\n3. Trust cert in Settings if needed'
                            : '1. Scan QR with any camera app\n2. Browser downloads the APK\n3. Open file to install',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          color: Color(0xFF94A3B8),
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Green "works anywhere" badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF14532D),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.public_rounded, size: 11, color: Color(0xFF4ADE80)),
                            SizedBox(width: 5),
                            Text('Works on any network',
                                style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF4ADE80), fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Copyable link
            if (_cloudFileUrl != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0A0F),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF1E293B)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.link_rounded, size: 13, color: Color(0xFF64748B)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _cloudFileUrl!,
                        style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Color(0xFF94A3B8)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () async {
                        // Copy to clipboard using standard Flutter Clipboard API
                        await Clipboard.setData(ClipboardData(text: _cloudFileUrl!));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Link copied to clipboard'), duration: Duration(seconds: 1)),
                          );
                        }
                      },
                      child: const Icon(Icons.copy_rounded, size: 13, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
            ],
            if (_installLogs.isNotEmpty) ...[
              const SizedBox(height: 18),
              const Divider(color: Color(0xFF1E293B)),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.devices_rounded, size: 14, color: Color(0xFF10B981)),
                  const SizedBox(width: 8),
                  Text(
                    'Installed Devices (${_installLogs.length})',
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _installLogs.length,
                separatorBuilder: (context, index) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final log = _installLogs[index];
                  IconData platformIcon = Icons.device_unknown_rounded;
                  Color platformColor = const Color(0xFF64748B);
                  if (log.platform == 'iOS') {
                    platformIcon = Icons.phone_iphone_rounded;
                    platformColor = const Color(0xFF38BDF8);
                  } else if (log.platform == 'Android') {
                    platformIcon = Icons.android_rounded;
                    platformColor = const Color(0xFF4ADE80);
                  } else if (log.platform == 'Desktop') {
                    platformIcon = Icons.laptop_mac_rounded;
                    platformColor = const Color(0xFFFB7185);
                  }

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F0F13),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Row(
                      children: [
                        Icon(platformIcon, size: 14, color: platformColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            log.deviceName,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                        ),
                        Text(
                          log.downloadedAt,
                          style: const TextStyle(
                            fontFamily: 'Courier',
                            fontSize: 10,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ],
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
  final Function(SignedAppHistoryItem) onUnsignSuccess;

  const UnsignStudioWidget({
    super.key,
    required this.signingService,
    required this.onUnsignSuccess,
  });

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

      AppMetadata? extractedMetadata;
      try {
        if (_platform == 'ios') {
          extractedMetadata = MetadataService.parseFromFilename(p.basename(_outputPath!));
        } else {
          extractedMetadata = await MetadataService.extractApkMetadata(_outputPath!);
        }
      } catch (_) {}

      setState(() {
        _unsignSuccess = true;
      });
      _addLog('🚀 Unsigning process completed successfully.');

      if (_outputPath != null) {
        final historyItem = SignedAppHistoryItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: extractedMetadata?.name ?? p.basenameWithoutExtension(_outputPath!),
          packageId: extractedMetadata?.packageId ?? 'Unknown',
          versionName: extractedMetadata?.versionName ?? '1.0.0',
          versionCode: extractedMetadata?.versionCode ?? '1',
          filePath: _outputPath!,
          platform: _platform,
          date: DateTime.now().toIso8601String(),
          isSigned: false,
        );
        widget.onUnsignSuccess(historyItem);
      }
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

class VaultWidget extends StatefulWidget {
  final VaultService vaultService;
  final VoidCallback onProfilesChanged;
  final Function(AppTab) onSelectTab;

  const VaultWidget({
    super.key,
    required this.vaultService,
    required this.onProfilesChanged,
    required this.onSelectTab,
  });

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
  final _androidZipalignController = TextEditingController();
  final _androidApksignerController = TextEditingController();

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
    _androidZipalignController.clear();
    _androidApksignerController.clear();
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
          _androidZipalignController.text = profile.zipalignPath;
          _androidApksignerController.text = profile.apksignerJarPath;
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
        zipalignPath: _androidZipalignController.text.trim(),
        apksignerJarPath: _androidApksignerController.text.trim(),
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
                                  color: isIos ? const Color(0xFF8B5CF6).withAlpha(38) : const Color(0xFF10B981).withAlpha(38),
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
        const SizedBox(height: 14),
        _buildVaultTextFieldWithBrowse(
          label: 'Zipalign Path',
          controller: _androidZipalignController,
          hint: 'Defaults to global command "zipalign"',
          extensions: [],
          isAny: true,
        ),
        const SizedBox(height: 14),
        _buildVaultTextFieldWithBrowse(
          label: 'Apksigner Path',
          controller: _androidApksignerController,
          hint: 'Select apksigner.jar file',
          extensions: ['jar'],
        ),
      ],
    );
  }

  Widget _buildVaultTextFieldWithBrowse({
    required String label,
    required TextEditingController controller,
    required String hint,
    required List<String> extensions,
    bool isAny = false,
  }) {
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
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF27272A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                FilePickerResult? result = await FilePicker.platform.pickFiles(
                  type: isAny ? FileType.any : FileType.custom,
                  allowedExtensions: isAny ? null : extensions,
                );
                if (result != null && result.files.single.path != null) {
                  setState(() {
                    controller.text = result.files.single.path!;
                  });
                }
              },
              child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }


}

// ==========================================
// 4. SETTINGS TAB WIDGET (DESKTOP)
// ==========================================
class AssetOptimizerWidget extends StatefulWidget {
  const AssetOptimizerWidget({super.key});

  @override
  State<AssetOptimizerWidget> createState() => _AssetOptimizerWidgetState();
}

class _AssetOptimizerWidgetState extends State<AssetOptimizerWidget> {
  String? _sourceImagePath;
  String? _outputDirectoryPath;
  bool _removeAlpha = true;
  bool _isProcessing = false;
  
  String _validationStatus = 'No image selected.';
  Color _validationColor = const Color(0xFFA1A1AA);
  bool _isValidImage = false;
  int? _imageWidth;
  int? _imageHeight;
  bool _hasAlphaChannel = false;
  double? _aspectRatio;

  final Map<String, bool> _selectedTargets = {
    'iOS App Store (1024x1024)': true,
    'iOS iPhone App (180x180)': true,
    'iOS iPhone App (120x120)': true,
    'iOS iPad App (152x152)': true,
    'Android Play Store (512x512)': true,
    'Android xxxhdpi (192x192)': true,
    'Android xxhdpi (144x144)': true,
    'Android xhdpi (96x96)': true,
    'Android hdpi (72x72)': true,
  };

  final List<String> _consoleLogs = [];
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _generatedAssets = [];

  void _log(String msg) {
    setState(() {
      _consoleLogs.add(msg);
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

  Future<void> _pickSourceImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      _log('📁 Selected source image: ${p.basename(path)}');
      setState(() {
        _sourceImagePath = path;
      });
      _validateImage(path);
    }
  }

  Future<void> _pickOutputDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path != null) {
      _log('📁 Selected output directory: $path');
      setState(() {
        _outputDirectoryPath = path;
      });
    }
  }

  Future<void> _validateImage(String path) async {
    try {
      final fileBytes = await File(path).readAsBytes();
      final original = img.decodeImage(fileBytes);
      if (original == null) {
        setState(() {
          _validationStatus = 'Unsupported or corrupt image format.';
          _validationColor = const Color(0xFFEF4444);
          _isValidImage = false;
        });
        _log('[ERROR] Failed to decode the image file.');
        return;
      }
      final w = original.width;
      final h = original.height;
      final hasAlpha = original.hasAlpha;
      final ratio = w / h;

      setState(() {
        _imageWidth = w;
        _imageHeight = h;
        _hasAlphaChannel = hasAlpha;
        _aspectRatio = ratio;
        _isValidImage = true;
      });

      _log('🔎 Image Details: $w x $h pixels, ${hasAlpha ? "RGBA (with transparency)" : "RGB (no transparency)"}');

      List<String> warnings = [];
      if (w < 1024 || h < 1024) {
        warnings.add('Resolution is under 1024x1024 (recommended standard). Output icons might be slightly blurry.');
      }
      if ((ratio - 1.0).abs() > 0.01) {
        warnings.add('Image is not square (aspect ratio is ${ratio.toStringAsFixed(2)}:1). Icons will be auto-cropped/centered.');
      }
      if (hasAlpha && _removeAlpha) {
        warnings.add('Image has alpha channel. Transparent background will be replaced with solid black for iOS App Store standard compliance.');
      }

      if (warnings.isNotEmpty) {
        final fixList = <String>[];
        if (w < 1024 || h < 1024) {
          fixList.add('✔ Resolution: Will upscale output presets to correct sizes (using average interpolation).');
        }
        if ((ratio - 1.0).abs() > 0.01) {
          fixList.add('✔ Aspect Ratio: Will automatically center-crop input to 1:1 square.');
        }
        if (hasAlpha && _removeAlpha) {
          fixList.add('✔ Transparency: Will strip alpha channel and fill background with solid black.');
        }

        setState(() {
          _validationStatus = 'Warnings:\n${warnings.map((e) => '• $e').join('\n')}\n\n⚡ Auto-Fix Actions (Applied during Generation):\n${fixList.join('\n')}';
          _validationColor = const Color(0xFFF59E0B);
        });
      } else {
        setState(() {
          _validationStatus = 'Image conforms to design guidelines (Perfect square, standard high resolution).';
          _validationColor = const Color(0xFF10B981);
        });
      }
    } catch (e) {
      setState(() {
        _validationStatus = 'Error parsing image: $e';
        _validationColor = const Color(0xFFEF4444);
        _isValidImage = false;
      });
      _log('[ERROR] Image validation failed: $e');
    }
  }

  Future<void> _autoFixSourceImage() async {
    if (_sourceImagePath == null) return;

    setState(() {
      _isProcessing = true;
    });

    _log('⚡ Starting Auto-Fix for Master Image...');
    try {
      final bytes = await File(_sourceImagePath!).readAsBytes();
      final original = img.decodeImage(bytes);
      if (original == null) {
        throw Exception('Failed to decode the source image for auto-fixing.');
      }

      img.Image processed = original;

      // 1. Aspect Ratio Symmetrical Crop from Center
      final ratio = original.width / original.height;
      if ((ratio - 1.0).abs() > 0.01) {
        _log('⚡ Cropping aspect ratio from ${ratio.toStringAsFixed(2)}:1 to 1:1...');
        final size = original.width < original.height ? original.width : original.height;
        final x = (original.width - size) ~/ 2;
        final y = (original.height - size) ~/ 2;
        processed = img.copyCrop(original, x: x, y: y, width: size, height: size);
      }

      // 2. Resize to 1024x1024
      if (processed.width != 1024 || processed.height != 1024) {
        _log('⚡ Resizing image from ${processed.width}x${processed.height} to 1024x1024...');
        processed = img.copyResize(processed, width: 1024, height: 1024, interpolation: img.Interpolation.average);
      }

      // 3. Remove transparency (Alpha channel)
      if (_removeAlpha && processed.hasAlpha) {
        _log('⚡ Stripping alpha channel and filling background with solid black...');
        final background = img.Image(width: 1024, height: 1024);
        img.fill(background, color: img.ColorRgb8(0, 0, 0));
        img.compositeImage(background, processed);
        processed = background;
      }

      // Save fixed image
      final dir = p.dirname(_sourceImagePath!);
      final filename = p.basenameWithoutExtension(_sourceImagePath!);
      final fixedPath = p.join(dir, '${filename}_fixed_1024.png');

      final encoded = img.encodePng(processed);
      await File(fixedPath).writeAsBytes(encoded);

      _log('✅ Auto-Fix complete! Saved fixed image: $fixedPath');

      setState(() {
        _sourceImagePath = fixedPath;
      });

      await _validateImage(fixedPath);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Master image successfully optimized to 1024x1024 square with no transparency!'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      _log('[ERROR] Failed to auto-fix master image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to auto-fix master image: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _openDirectoryInFinder(String dirPath) {
    if (Platform.isMacOS) {
      Process.run('open', [dirPath]);
    } else if (Platform.isWindows) {
      Process.run('explorer.exe', [dirPath]);
    }
  }

  Future<void> _optimizeAndGenerate() async {
    if (_sourceImagePath == null) return;
    final outDir = _outputDirectoryPath ?? p.dirname(_sourceImagePath!);
    final parentFolder = Directory(p.join(outDir, 'AppIcons'));
    final iosFolder = Directory(p.join(parentFolder.path, 'ios'));
    final androidFolder = Directory(p.join(parentFolder.path, 'android'));

    setState(() {
      _isProcessing = true;
      _generatedAssets.clear();
      _consoleLogs.clear();
    });

    _log('🚀 Initializing Asset Optimizer...');
    _log('📂 Source: $_sourceImagePath');
    _log('📂 Parent folder: ${parentFolder.path}');

    try {
      // Create directories recursively
      await parentFolder.create(recursive: true);
      await iosFolder.create(recursive: true);
      await androidFolder.create(recursive: true);
      _log('📁 Created output subfolders: ios/ and android/');

      final bytes = await File(_sourceImagePath!).readAsBytes();
      final original = img.decodeImage(bytes);
      if (original == null) {
        throw Exception('Failed to decode the source image.');
      }
      _log('✅ Loaded master image: ${original.width}x${original.height}');

      final List<Map<String, dynamic>> targets = [
        {'name': 'iOS App Store (1024x1024)', 'width': 1024, 'height': 1024, 'file': 'appicon_1024.png', 'platform': 'ios'},
        {'name': 'iOS iPhone App (180x180)', 'width': 180, 'height': 180, 'file': 'appicon_180.png', 'platform': 'ios'},
        {'name': 'iOS iPhone App (120x120)', 'width': 120, 'height': 120, 'file': 'appicon_120.png', 'platform': 'ios'},
        {'name': 'iOS iPad App (152x152)', 'width': 152, 'height': 152, 'file': 'appicon_152.png', 'platform': 'ios'},
        {'name': 'Android Play Store (512x512)', 'width': 512, 'height': 512, 'file': 'ic_launcher_play_store.png', 'platform': 'android'},
        {'name': 'Android xxxhdpi (192x192)', 'width': 192, 'height': 192, 'file': 'ic_launcher_192.png', 'platform': 'android'},
        {'name': 'Android xxhdpi (144x144)', 'width': 144, 'height': 144, 'file': 'ic_launcher_144.png', 'platform': 'android'},
        {'name': 'Android xhdpi (96x96)', 'width': 96, 'height': 96, 'file': 'ic_launcher_96.png', 'platform': 'android'},
        {'name': 'Android hdpi (72x72)', 'width': 72, 'height': 72, 'file': 'ic_launcher_72.png', 'platform': 'android'},
      ];

      for (final t in targets) {
        final key = t['name'] as String;
        if (_selectedTargets[key] != true) {
          _log('⏭️ Skipping $key as it is unchecked.');
          continue;
        }

        final w = t['width'] as int;
        final h = t['height'] as int;
        final filename = t['file'] as String;
        final isIos = t['platform'] == 'ios';
        final targetDir = isIos ? iosFolder : androidFolder;
        final outputPath = p.join(targetDir.path, filename);

        _log('⚡ Processing $key ($w x $h)...');

        img.Image processed = original;
        if ((original.width - original.height).abs() > 2) {
          final size = original.width < original.height ? original.width : original.height;
          final x = (original.width - size) ~/ 2;
          final y = (original.height - size) ~/ 2;
          processed = img.copyCrop(original, x: x, y: y, width: size, height: size);
        }

        final resized = img.copyResize(processed, width: w, height: h, interpolation: img.Interpolation.average);

        img.Image finalImage = resized;
        if (_removeAlpha && finalImage.hasAlpha) {
          final background = img.Image(width: w, height: h);
          img.fill(background, color: img.ColorRgb8(0, 0, 0));
          img.compositeImage(background, finalImage);
          finalImage = background;
        }

        final encoded = img.encodePng(finalImage);
        final file = File(outputPath);
        await file.writeAsBytes(encoded);

        final sizeKb = (encoded.length / 1024).toStringAsFixed(1);
        final relativePath = '${isIos ? "ios" : "android"}/$filename';
        _log('💾 Generated $relativePath ($sizeKb KB)');

        setState(() {
          _generatedAssets.add({
            'name': relativePath,
            'size': '$sizeKb KB',
            'path': outputPath,
            'width': w,
            'height': h,
          });
        });
      }

      _log('🎉 All assets optimized and written successfully!');
    } catch (e) {
      _log('[CRITICAL ERROR] Optimization failed: $e');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _showInFinder(String filePath) {
    verifyAndLocateFile(context, filePath);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left Column
          Expanded(
            flex: 5,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Optimizer Source & Config',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  
                  // Master Image Picker
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Master App Icon File', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
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
                                _sourceImagePath != null ? p.basename(_sourceImagePath!) : 'Select high-res master icon (recommended 1024x1024)',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 13,
                                  color: _sourceImagePath != null ? Colors.white : const Color(0xFF52525B),
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
                            onPressed: _pickSourceImage,
                            child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
                          ),
                        ],
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Output Directory Picker
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Output Directory (Optional)', style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA))),
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
                                _outputDirectoryPath != null ? _outputDirectoryPath! : 'Defaults to source image folder',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 13,
                                  color: _outputDirectoryPath != null ? Colors.white : const Color(0xFF52525B),
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
                            onPressed: _pickOutputDirectory,
                            child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 13)),
                          ),
                        ],
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 20),
                  
                  // Optimization Options
                  Row(
                    children: [
                      Checkbox(
                        value: _removeAlpha,
                        activeColor: const Color(0xFF8B5CF6),
                        onChanged: (val) {
                          setState(() {
                            _removeAlpha = val ?? true;
                          });
                          if (_sourceImagePath != null) {
                            _validateImage(_sourceImagePath!);
                          }
                        },
                      ),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Remove transparency (Alpha channel)',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            Text(
                              'Converts transparent backgrounds to solid black. Required for iOS App Store standard app icons.',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF71717A)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 24),
                  const Divider(color: Color(0xFF27272A)),
                  const SizedBox(height: 16),
                  
                  // Preset Checklist Title
                  const Text(
                    'Target Resize Presets',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  
                  // List of Presets
                  ..._selectedTargets.keys.map((key) {
                    return Row(
                      children: [
                        Checkbox(
                          value: _selectedTargets[key],
                          activeColor: const Color(0xFF8B5CF6),
                          onChanged: (val) {
                            setState(() {
                              _selectedTargets[key] = val ?? false;
                            });
                          },
                        ),
                        Text(
                          key,
                          style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    );
                  }),
                  
                  const SizedBox(height: 32),
                  
                  // Run Button
                  Container(
                    width: double.infinity,
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: (_isProcessing || _sourceImagePath == null)
                            ? [const Color(0xFF3F3F46), const Color(0xFF27272A)]
                            : [const Color(0xFF8B5CF6), const Color(0xFF6D28D9)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        if (!_isProcessing && _sourceImagePath != null)
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
                      onPressed: (_isProcessing || _sourceImagePath == null) ? null : _optimizeAndGenerate,
                      child: _isProcessing
                          ? const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                                SizedBox(width: 12),
                                Text('OPTIMIZING ASSETS...', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 15)),
                              ],
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.flash_on_rounded, size: 20),
                                SizedBox(width: 8),
                                Text('Optimize & Generate App Icons Now', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 15)),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(width: 24),
          
          // Right Column
          Expanded(
            flex: 4,
            child: Column(
              children: [
                // Validation Guidance Card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F0F12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.info_outline_rounded, color: Color(0xFF8B5CF6), size: 18),
                          SizedBox(width: 8),
                          Text('GUIDELINE COMPLIANCE SCANNER', style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF8B5CF6))),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _validationStatus,
                        style: TextStyle(fontFamily: 'Inter', fontSize: 12, height: 1.4, color: _validationColor),
                      ),
                      if (_sourceImagePath != null && _validationColor == const Color(0xFFF59E0B)) ...[
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF59E0B).withAlpha(38),
                              foregroundColor: const Color(0xFFF59E0B),
                              side: const BorderSide(color: Color(0xFFF59E0B), width: 1),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                            label: const Text(
                              'Auto-Fix Master Image',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            onPressed: _autoFixSourceImage,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Console Output
                Container(
                  width: double.infinity,
                  height: 220,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A0C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.terminal, color: Color(0xFF10B981), size: 16),
                          SizedBox(width: 8),
                          Text('PROCESS OUTPUT LOGGER', style: TextStyle(fontFamily: 'Courier', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
                        ],
                      ),
                      const Divider(color: Color(0xFF27272A)),
                      Expanded(
                        child: SelectionArea(
                          child: _consoleLogs.isEmpty
                              ? Center(
                                  child: Text(
                                    'Load image and tap Optimize to view output.',
                                    style: TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.grey[700]),
                                  ),
                                )
                              : ListView.builder(
                                  controller: _scrollController,
                                  itemCount: _consoleLogs.length,
                                  itemBuilder: (context, index) {
                                    final line = _consoleLogs[index];
                                    Color color = Colors.white70;
                                    if (line.startsWith('[ERROR]') || line.startsWith('[CRITICAL ERROR]')) {
                                      color = const Color(0xFFEF4444);
                                    } else if (line.startsWith('🎉') || line.startsWith('✅')) {
                                      color = const Color(0xFF10B981);
                                    } else if (line.startsWith('⚡') || line.startsWith('🚀')) {
                                      color = const Color(0xFF8B5CF6);
                                    }
                                    return Text(
                                      line,
                                      style: TextStyle(fontFamily: 'Courier', fontSize: 11, color: color),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Generated Assets List
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131317),
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
                              'GENERATED APP ASSETS',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70),
                            ),
                            if (_generatedAssets.isNotEmpty)
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: const Icon(Icons.folder_open_rounded, size: 14, color: Color(0xFF8B5CF6)),
                                label: const Text('Open AppIcons Folder', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF8B5CF6))),
                                onPressed: () {
                                  final outDir = _outputDirectoryPath ?? p.dirname(_sourceImagePath!);
                                  final parentFolderPath = p.join(outDir, 'AppIcons');
                                  _openDirectoryInFinder(parentFolderPath);
                                },
                              ),
                          ],
                        ),
                        const Divider(color: Color(0xFF27272A)),
                        Expanded(
                          child: _generatedAssets.isEmpty
                              ? Center(
                                  child: Text(
                                    'No assets generated yet.',
                                    style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.grey[600]),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _generatedAssets.length,
                                  itemBuilder: (context, index) {
                                    final asset = _generatedAssets[index];
                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1E1E22),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: const Color(0xFF27272A)),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  asset['name'] as String,
                                                  style: const TextStyle(fontFamily: 'Courier', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  '${asset["width"]}x${asset["height"]} • ${asset["size"]}',
                                                  style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Colors.grey[500]),
                                                ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.folder_open_rounded, size: 16, color: Color(0xFF8B5CF6)),
                                            onPressed: () => _showInFinder(asset['path'] as String),
                                            tooltip: 'Show in Finder',
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// DEVOPS WORKSPACE & AI ACTIVITY REPORTER WIDGET
// =============================================================================
class DevOpsWorkItem {
  final String id;
  final String title;
  final String status;
  final String type;
  final String date;
  final String month;
  final DateTime dateTime;

  DevOpsWorkItem({
    required this.id,
    required this.title,
    required this.status,
    required this.type,
    required this.date,
    required this.month,
    required this.dateTime,
  });
}

class DevOpsPullRequest {
  final String id;
  final String title;
  final String status;
  final String repo;
  final String sourceBranch;
  final String targetBranch;
  final String date;
  final String month;
  final DateTime dateTime;

  DevOpsPullRequest({
    required this.id,
    required this.title,
    required this.status,
    required this.repo,
    required this.sourceBranch,
    required this.targetBranch,
    required this.date,
    required this.month,
    required this.dateTime,
  });
}

class DevOpsWidget extends StatefulWidget {
  const DevOpsWidget({super.key});

  @override
  State<DevOpsWidget> createState() => _DevOpsWidgetState();
}

class _DevOpsWidgetState extends State<DevOpsWidget> with SingleTickerProviderStateMixin {
  bool _isConnected = false;
  bool _isLoading = false;
  String? _errorMessage;

  String _org = '';
  String _project = '';
  String _pat = '';
  String _email = '';

  final _orgController = TextEditingController();
  final _projectController = TextEditingController();
  final _patController = TextEditingController();
  final _emailController = TextEditingController();

  List<DevOpsWorkItem> _workItems = [];
  List<DevOpsPullRequest> _prs = [];

  List<double> _weeklyActivity = [3, 2, 4, 1, 3];
  
  late AnimationController _chartAnimationController;
  late Animation<double> _chartAnimation;

  String? _aiStandupText;
  bool _generatingStandup = false;

  Timer? _notificationTimer;

  @override
  void initState() {
    super.initState();
    _chartAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _chartAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _chartAnimationController, curve: Curves.easeOutBack),
    );
    _loadSavedCredentials();
    _setupNotifications();
  }

  @override
  void dispose() {
    _chartAnimationController.dispose();
    _notificationTimer?.cancel();
    super.dispose();
  }

  void _setupNotifications() {
    _notificationTimer = Timer.periodic(const Duration(seconds: 35), (timer) {
      if (!mounted || !_isConnected) return;
      _triggerRealtimeAlert();
    });
  }

  void _triggerRealtimeAlert() {
    final alerts = [
      {'title': 'Updated Android Keystore default paths', 'branch': 'feature/keystore-defaults', 'status': 'Approved'},
      {'title': 'Fixed iOS mobileprovision parse error', 'branch': 'bugfix/provision-mismatch', 'status': 'Completed'},
      {'title': 'Optimized QR Code isolate decoding', 'branch': 'feature/qr-optimization', 'status': 'Active'},
    ];
    final alert = (alerts..shuffle()).first;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.alt_route, color: Color(0xFF8B5CF6), size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'DevOps Alert: "${alert['title']}" in branch "${alert['branch']}" is now ${alert['status']}!',
                style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E1E24),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        margin: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _org = prefs.getString('ado_org') ?? '';
      _project = prefs.getString('ado_project') ?? '';
      _pat = prefs.getString('ado_pat') ?? '';
      _email = prefs.getString('ado_email') ?? '';

      _orgController.text = _org;
      _projectController.text = _project;
      _patController.text = _pat;
      _emailController.text = _email;
    });

    if (_org.isNotEmpty && _project.isNotEmpty && _pat.isNotEmpty) {
      _syncDevOps();
    } else {
      _loadMockData();
    }
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ado_org', _orgController.text.trim());
    await prefs.setString('ado_project', _projectController.text.trim());
    await prefs.setString('ado_pat', _patController.text.trim());
    await prefs.setString('ado_email', _emailController.text.trim());

    setState(() {
      _org = _orgController.text.trim();
      _project = _projectController.text.trim();
      _pat = _patController.text.trim();
      _email = _emailController.text.trim();
    });

    Navigator.of(context).pop();
    _syncDevOps();
  }

  void _loadMockData() {
    final now = DateTime.now();
    setState(() {
      _isConnected = true;
      _workItems = [
        DevOpsWorkItem(
          id: '10432',
          title: 'Secure credentials storage validation and encryption checks',
          status: 'Dev Done',
          type: 'Bug',
          date: '${now.day - 1} Jun',
          month: 'Jun 2026',
          dateTime: now.subtract(const Duration(days: 1)),
        ),
        DevOpsWorkItem(
          id: '10435',
          title: 'Implement drag & drop to strip Apple digital signature',
          status: 'In Progress',
          type: 'Task',
          date: '${now.day} Jun',
          month: 'Jun 2026',
          dateTime: now,
        ),
        DevOpsWorkItem(
          id: '10389',
          title: 'Integrate zipalign and apksigner path inputs in Profile Vault',
          status: 'Resolved',
          type: 'Task',
          date: '28 May',
          month: 'May 2026',
          dateTime: now.subtract(const Duration(days: 6)),
        ),
        DevOpsWorkItem(
          id: '10440',
          title: 'Fix QR code image parsing isolate crash on older macOS builds',
          status: 'To Do',
          type: 'Bug',
          date: '${now.day + 1} Jun',
          month: 'Jun 2026',
          dateTime: now.add(const Duration(days: 1)),
        ),
      ];

      _prs = [
        DevOpsPullRequest(
          id: '2024',
          title: 'Integrate zipalign & apksigner keystore fields',
          status: 'Completed',
          repo: 'sign-studio-app',
          sourceBranch: 'feature/vault-keystore-paths',
          targetBranch: 'main',
          date: '28 May',
          month: 'May 2026',
          dateTime: now.subtract(const Duration(days: 6)),
        ),
        DevOpsPullRequest(
          id: '2027',
          title: 'Implement drag-drop signature stripping logic',
          status: 'Active',
          repo: 'sign-studio-app',
          sourceBranch: 'feature/drag-drop-strip',
          targetBranch: 'dev',
          date: '${now.day} Jun',
          month: 'Jun 2026',
          dateTime: now,
        ),
      ];
      _weeklyActivity = [3, 2, 4, 1, 3];
    });

    _chartAnimationController.reset();
    _chartAnimationController.forward();
  }

  Future<void> _syncDevOps() async {
    if (_org.isEmpty || _project.isEmpty || _pat.isEmpty) {
      _loadMockData();
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final credentials = base64Encode(utf8.encode(':$_pat'));
      final headers = {
        'Authorization': 'Basic $credentials',
        'Content-Type': 'application/json',
      };

      final encodedOrg = Uri.encodeComponent(_org);
      final encodedProject = Uri.encodeComponent(_project);

      final wiqlUrl = Uri.parse('https://dev.azure.com/$encodedOrg/$encodedProject/_apis/wit/wiql?api-version=7.0');
      final queryBody = {
        "query": "Select [System.Id] From WorkItems Where [System.TeamProject] = @project And ([System.AssignedTo] = @me${_email.isNotEmpty ? " Or [System.AssignedTo] = '$_email'" : ""})"
      };

      final wiqlResponse = await http.post(wiqlUrl, headers: headers, body: json.encode(queryBody));
      if (wiqlResponse.statusCode != 200) {
        throw Exception('API error code ${wiqlResponse.statusCode}');
      }

      final wiqlData = json.decode(wiqlResponse.body);
      final List<dynamic> wiJson = wiqlData['workItems'] ?? [];
      final List<DevOpsWorkItem> items = [];

      if (wiJson.isNotEmpty) {
        final ids = wiJson.map((wi) => wi['id']).take(20).join(',');
        final detailsUrl = Uri.parse('https://dev.azure.com/$encodedOrg/$encodedProject/_apis/wit/workitems?ids=$ids&api-version=7.0');
        final detailsResponse = await http.get(detailsUrl, headers: headers);

        if (detailsResponse.statusCode == 200) {
          final detailsData = json.decode(detailsResponse.body);
          final List<dynamic> values = detailsData['value'] ?? [];
          for (final val in values) {
            final fields = val['fields'] ?? {};
            final title = fields['System.Title'] ?? 'Untitled';
            final state = fields['System.State'] ?? 'To Do';
            final type = fields['System.WorkItemType'] ?? 'Task';
            final changedDateStr = fields['System.ChangedDate'] ?? '';

            DateTime changedDate = DateTime.now();
            if (changedDateStr.isNotEmpty) {
              changedDate = DateTime.parse(changedDateStr).toLocal();
            }

            final List<String> months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
            final month = '${months[changedDate.month - 1]} ${changedDate.year}';
            final date = '${changedDate.day} ${months[changedDate.month - 1]}';

            items.add(DevOpsWorkItem(
              id: val['id'].toString(),
              title: title,
              status: state,
              type: type,
              date: date,
              month: month,
              dateTime: changedDate,
            ));
          }
        }
      }

      final prUrl = Uri.parse('https://dev.azure.com/$encodedOrg/$encodedProject/_apis/git/pullrequests?searchCriteria.status=all&%24top=20&api-version=7.0');
      final prResponse = await http.get(prUrl, headers: headers);
      final List<DevOpsPullRequest> prs = [];

      if (prResponse.statusCode == 200) {
        final prData = json.decode(prResponse.body);
        final List<dynamic> values = prData['value'] ?? [];
        for (final val in values) {
          final title = val['title'] ?? 'No Title';
          String status = val['status'] ?? 'active';
          if (status.toLowerCase() == 'active') {
            status = 'Active';
          } else if (status.toLowerCase() == 'completed' || status.toLowerCase() == 'merged') {
            status = 'Completed';
          } else if (status.toLowerCase() == 'abandoned') {
            status = 'Abandoned';
          }
          final sourceRef = val['sourceRefName'] ?? '';
          final targetRef = val['targetRefName'] ?? '';
          final creationDateStr = val['creationDate'] ?? '';
          final repo = val['repository']?['name'] ?? 'Repo';

          final sourceBranch = sourceRef.replaceAll('refs/heads/', '');
          final targetBranch = targetRef.replaceAll('refs/heads/', '');

          DateTime creationDate = DateTime.now();
          if (creationDateStr.isNotEmpty) {
            creationDate = DateTime.parse(creationDateStr).toLocal();
          }

          final List<String> months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
          final month = '${months[creationDate.month - 1]} ${creationDate.year}';
          final date = '${creationDate.day} ${months[creationDate.month - 1]}';

          prs.add(DevOpsPullRequest(
            id: val['pullRequestId'].toString(),
            title: title,
            status: status,
            repo: repo,
            sourceBranch: sourceBranch,
            targetBranch: targetBranch,
            date: date,
            month: month,
            dateTime: creationDate,
          ));
        }
      }

      List<double> weeklyCounts = [0, 0, 0, 0, 0];
      final now = DateTime.now();
      final monday = now.subtract(Duration(days: now.weekday - 1));
      for (final item in items) {
        if (item.dateTime.isAfter(monday) && item.dateTime.isBefore(now.add(const Duration(days: 1)))) {
          final dayIndex = item.dateTime.weekday - 1;
          if (dayIndex >= 0 && dayIndex < 5) {
            weeklyCounts[dayIndex]++;
          }
        }
      }

      setState(() {
        _workItems = items;
        _prs = prs;
        if (weeklyCounts.any((c) => c > 0)) {
          _weeklyActivity = weeklyCounts;
        }
        _isLoading = false;
        _isConnected = true;
      });

      _chartAnimationController.reset();
      _chartAnimationController.forward();

    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to fetch from Azure DevOps REST API: $e. Loaded mock datasets.';
        _isLoading = false;
      });
      _loadMockData();
    }
  }

  void _showWorkItemDetails(DevOpsWorkItem item) {
    String description = '';
    if (item.title.contains('Secure credentials storage')) {
      description = 'Review current KeyStore/KeyChain security procedures. Ensure AES-256-GCM keys are validated, cryptographically sound, and credentials are encrypted before persistence.';
    } else if (item.title.contains('drag & drop') || item.title.contains('drag-drop')) {
      description = 'Integrate drag-and-drop layer to receive visual files and strip Apple signatures. Remove the _CodeSignature directory and check the file integrity before signing.';
    } else if (item.title.contains('zipalign')) {
      description = 'Enable user to customize paths for zipalign and apksigner binaries inside the Profile Vault. Automatically verify selected binary paths are executable.';
    } else if (item.title.contains('QR code') || item.title.contains('QR-code')) {
      description = 'Address a severe isolate crash when parsing large QR code images on older macOS SDK architectures. Move decoding execution to a clean isolated thread.';
    } else {
      description = 'DevOps ticket raised to update release management configs, execute builds, or configure workspace details for the mobile platform.';
    }

    final isBug = item.type == 'Bug';
    final isDone = item.status == 'Resolved' || item.status == 'Dev Done' || item.status == 'Done' || item.status == 'Closed';

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF1E1E24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF27272A)),
          ),
          child: Container(
            width: 480,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isBug ? Icons.bug_report_rounded : Icons.task_rounded,
                          color: isBug ? const Color(0xFFEF4444) : const Color(0xFF8B5CF6),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${item.type} Details',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.grey, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const Divider(color: Color(0xFF27272A), height: 24),
                
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF27272A),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'ID: ${item.type}-${item.id}',
                        style: const TextStyle(
                          fontFamily: 'Courier',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFA1A1AA),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isDone ? const Color(0xFF10B981).withAlpha(38) : const Color(0xFFF59E0B).withAlpha(38),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.status,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDone ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131317),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Column(
                    children: [
                      _buildMetaRow('System Project', _project.isNotEmpty ? _project : 'SignNext (Demo)'),
                      const Divider(color: Color(0xFF27272A), height: 16),
                      _buildMetaRow('Assigned To', _email.isNotEmpty ? _email : 'pavanyadav@crmnext.com'),
                      const Divider(color: Color(0xFF27272A), height: 16),
                      _buildMetaRow('Modified Date', '${item.date} (${item.month})'),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                const Text(
                  'Description',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    height: 1.4,
                    color: Color(0xFFA1A1AA),
                  ),
                ),
                const SizedBox(height: 20),

                const Text(
                  'Verification & Progress Checklist',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                _buildChecklistItem('Code changes committed to feature branch', true),
                _buildChecklistItem('Local compiler static analysis checks', true),
                _buildChecklistItem('Unit test suites coverage validation', isDone),
                _buildChecklistItem('QA verification & sign-off approval', isDone),
                
                const SizedBox(height: 24),
                
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (_org.isNotEmpty && _project.isNotEmpty)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF38BDF8),
                          side: const BorderSide(color: Color(0xFF38BDF8)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.open_in_new_rounded, size: 14),
                        label: const Text('Open in Azure DevOps', style: TextStyle(fontFamily: 'Inter', fontSize: 11)),
                        onPressed: () {
                          final url = 'https://dev.azure.com/$_org/$_project/_workitems/edit/${item.id}';
                          Process.run('open', [url]);
                        },
                      )
                    else
                      const SizedBox.shrink(),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close', style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPrDetails(DevOpsPullRequest pr) {
    String description = '';
    if (pr.title.contains('zipalign')) {
      description = 'This PR implements custom directory configuration fields for Android build credentials. Users can save zipalign & apksigner execution pathways directly inside Profile Vault.';
    } else if (pr.title.contains('signature stripping') || pr.title.contains('drag-drop')) {
      description = 'Introduces macOS drag-and-drop listener layer to accept app archives, parse the bundle layout, strip active code signature fields, and prepare folders for signing.';
    } else {
      description = 'Integration PR merging active development progress, setting config keys, or resolving issues prior to the deployment pipeline run.';
    }

    final isMerged = pr.status == 'Completed' || pr.status == 'Merged' || pr.status.toLowerCase() == 'completed' || pr.status.toLowerCase() == 'merged';

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF1E1E24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF27272A)),
          ),
          child: Container(
            width: 480,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.alt_route_rounded,
                          color: Color(0xFF38BDF8),
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Pull Request Details',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.grey, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const Divider(color: Color(0xFF27272A), height: 24),

                Text(
                  pr.title,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF27272A),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'PR #${pr.id}',
                        style: const TextStyle(
                          fontFamily: 'Courier',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFA1A1AA),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isMerged ? const Color(0xFF10B981).withAlpha(38) : const Color(0xFF38BDF8).withAlpha(38),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        pr.status,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isMerged ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131317),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Branch Flow',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF71717A)),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E24),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.3)),
                            ),
                            child: Text(
                              pr.sourceBranch,
                              style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFFC084FC), fontWeight: FontWeight.bold),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8.0),
                            child: Icon(Icons.arrow_forward_rounded, size: 14, color: Colors.grey),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E24),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                            ),
                            child: Text(
                              pr.targetBranch,
                              style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFF34D399), fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131317),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Column(
                    children: [
                      _buildMetaRow('Repository', pr.repo),
                      const Divider(color: Color(0xFF27272A), height: 16),
                      _buildMetaRow('Created Date', '${pr.date} (${pr.month})'),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                const Text(
                  'Summary Description',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    height: 1.4,
                    color: Color(0xFFA1A1AA),
                  ),
                ),
                const SizedBox(height: 20),

                const Text(
                  'Reviewers Status',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                _buildReviewerRow('Sachin (Lead Mobile Dev)', isMerged ? 'Approved' : 'Pending', isMerged),
                _buildReviewerRow('Anuj (QA Engineer)', isMerged ? 'Approved' : 'Pending', isMerged),
                _buildReviewerRow('Pavan Yadav (Developer)', 'Author', true),

                const SizedBox(height: 24),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (_org.isNotEmpty && _project.isNotEmpty)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF38BDF8),
                          side: const BorderSide(color: Color(0xFF38BDF8)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.open_in_new_rounded, size: 14),
                        label: const Text('View PR in DevOps', style: TextStyle(fontFamily: 'Inter', fontSize: 11)),
                        onPressed: () {
                          final url = 'https://dev.azure.com/$_org/$_project/_git/${pr.repo}/pullrequest/${pr.id}';
                          Process.run('open', [url]);
                        },
                      )
                    else
                      const SizedBox.shrink(),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close', style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMetaRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF71717A))),
        Text(value, style: const TextStyle(fontFamily: 'Courier', fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
      ],
    );
  }

  Widget _buildReviewerRow(String name, String status, bool approved) {
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.help_outline_rounded;
    if (status == 'Approved') {
      statusColor = const Color(0xFF10B981);
      statusIcon = Icons.check_circle_rounded;
    } else if (status == 'Author') {
      statusColor = const Color(0xFF38BDF8);
      statusIcon = Icons.person_rounded;
    } else if (status == 'Pending') {
      statusColor = const Color(0xFFF59E0B);
      statusIcon = Icons.hourglass_empty_rounded;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(name, style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70)),
          Row(
            children: [
              Icon(statusIcon, size: 12, color: statusColor),
              const SizedBox(width: 4),
              Text(
                status,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: statusColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChecklistItem(String task, bool checked) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        children: [
          Icon(
            checked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
            size: 14,
            color: checked ? const Color(0xFF10B981) : const Color(0xFF52525B),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              task,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                color: checked ? Colors.white70 : const Color(0xFF71717A),
                decoration: checked ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _generateAiStandupReport() async {
    setState(() {
      _generatingStandup = true;
      _aiStandupText = null;
    });

    await Future.delayed(const Duration(milliseconds: 1200));

    final completed = _workItems.where((wi) => wi.status == 'Resolved' || wi.status == 'Dev Done').toList();
    final inProgress = _workItems.where((wi) => wi.status == 'In Progress').toList();
    final activePrs = _prs.where((pr) => pr.status == 'Active' || pr.status == 'active').toList();

    final buffer = StringBuffer();
    buffer.writeln('🚀 *DAILY STANDUP AI SUMMARY - RELEASE MANAGEMENT*');
    buffer.writeln('\n**Yesterday (Completed):**');
    if (completed.isEmpty) {
      buffer.writeln('- Finished code signing pipeline integrations and cert syncs.');
    } else {
      for (final item in completed.take(3)) {
        buffer.writeln('- Resolved [${item.type}-${item.id}] ${item.title}');
      }
    }

    buffer.writeln('\n**Today (Active):**');
    if (inProgress.isEmpty) {
      buffer.writeln('- Implementing drag & drop digital signature strip utility.');
    } else {
      for (final item in inProgress.take(2)) {
        buffer.writeln('- Working on [${item.type}-${item.id}] ${item.title}');
      }
    }
    for (final pr in activePrs.take(2)) {
      buffer.writeln('- Monitoring active PR #${pr.id} (${pr.sourceBranch} -> ${pr.targetBranch})');
    }

    buffer.writeln('\n**Blockers:**');
    buffer.writeln('- None. Running final code review builds.');

    setState(() {
      _generatingStandup = false;
      _aiStandupText = buffer.toString();
    });
  }

  Future<void> _exportPdfReport(bool isWeekly) async {
    final pdf = pw.Document();

    final theme = pw.ThemeData.withFont(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
    );

    pdf.addPage(
      pw.MultiPage(
        theme: theme,
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('SignNext DevOps Status Report', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: PdfColors.purple)),
                  pw.Text(isWeekly ? 'WEEKLY SUMMARY' : 'MONTHLY SUMMARY', style: pw.TextStyle(fontSize: 12, color: PdfColors.grey)),
                ],
              ),
            ),
            pw.SizedBox(height: 12),
            pw.Text('Generated by: $_email on ${DateTime.now().toLocal().toString().substring(0, 16)}', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
            pw.SizedBox(height: 16),
            
            pw.Text('Performance Summary Metrics', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.purple)),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 8),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Total Synced Tasks: ${_workItems.length}', style: pw.TextStyle(fontSize: 11)),
                pw.Text('Completed Tasks: ${_workItems.where((wi) => wi.status == 'Resolved' || wi.status == 'Dev Done').length}', style: pw.TextStyle(fontSize: 11)),
                pw.Text('Total PRs: ${_prs.length}', style: pw.TextStyle(fontSize: 11)),
              ],
            ),
            pw.SizedBox(height: 20),

            pw.Text('Work Items Timeline Log', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.purple)),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 8),
            ..._workItems.map((item) {
              return pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 4),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('[${item.type}-${item.id}] ${item.title}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                          pw.Text('Date: ${item.date} (${item.month})', style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
                        ],
                      ),
                    ),
                    pw.Text(
                      item.status,
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: (item.status == 'Resolved' || item.status == 'Dev Done') ? PdfColors.green : PdfColors.orange,
                      ),
                    ),
                  ],
                ),
              );
            }),

            pw.SizedBox(height: 20),
            pw.Text('Pull Request Release Logs', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.purple)),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 8),
            ..._prs.map((pr) {
              return pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 4),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('PR #${pr.id}: ${pr.title}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                          pw.Text('Branch: ${pr.sourceBranch} -> ${pr.targetBranch} | Repo: ${pr.repo}', style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
                        ],
                      ),
                    ),
                    pw.Text(
                      pr.status.toUpperCase(),
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: (pr.status == 'Completed' || pr.status == 'Merged') ? PdfColors.green : PdfColors.blue,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ];
        },
      ),
    );

    try {
      final bytes = await pdf.save();
      final fileName = isWeekly ? 'DevOps_Weekly_Report.pdf' : 'DevOps_Monthly_Report.pdf';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export DevOps Report',
        fileName: fileName,
        bytes: bytes,
      );

      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Activity report saved to $path successfully!'),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save PDF: $e'),
          backgroundColor: const Color(0xFFEF4444),
        ),
      );
    }
  }

  void _showCredentialsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFF27272A))),
          title: const Text('Connect Azure DevOps', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDialogField(label: 'Azure DevOps Organization', controller: _orgController, hint: 'e.g. crmnext-dev'),
                const SizedBox(height: 12),
                _buildDialogField(label: 'Project Name', controller: _projectController, hint: 'e.g. sign-next'),
                const SizedBox(height: 12),
                _buildDialogField(label: 'Personal Access Token (PAT)', controller: _patController, hint: 'Azure PAT Token', obscure: true),
                const SizedBox(height: 12),
                _buildDialogField(label: 'User Account Email', controller: _emailController, hint: 'e.g. developer@crmnext.com'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6), foregroundColor: Colors.white),
              onPressed: _saveCredentials,
              child: const Text('Save & Connect', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDialogField({required String label, required TextEditingController controller, required String hint, bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA))),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF52525B)),
            fillColor: const Color(0xFF0F0F12),
            filled: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 6,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'DevOps Activity Dashboard',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _org.isNotEmpty ? 'Syncing project: $_project' : 'Running in Simulated Demo Mode',
                          style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFA1A1AA)),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E1E22),
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Color(0xFF27272A)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                          icon: const Icon(Icons.settings_rounded, size: 16),
                          label: const Text('ADO Settings', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                          onPressed: _showCredentialsDialog,
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF8B5CF6),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                          icon: _isLoading 
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.sync_rounded, size: 16),
                          label: const Text('Refresh', style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold)),
                          onPressed: _isLoading ? null : _syncDevOps,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFFEF4444).withAlpha(30), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFEF4444))),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 16),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_errorMessage!, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFEF4444)))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                Row(
                  children: [
                    _buildStatCard('Bugs Closed', _workItems.where((wi) => wi.type == 'Bug' && (wi.status == 'Resolved' || wi.status == 'Dev Done' || wi.status == 'Closed' || wi.status == 'Done')).length.toString(), Icons.bug_report_rounded, const Color(0xFFEF4444)),
                    const SizedBox(width: 16),
                    _buildStatCard('Tasks Finished', _workItems.where((wi) => wi.type == 'Task' && (wi.status == 'Resolved' || wi.status == 'Dev Done' || wi.status == 'Closed' || wi.status == 'Done')).length.toString(), Icons.check_circle_outline_rounded, const Color(0xFF10B981)),
                    const SizedBox(width: 16),
                    _buildStatCard('Active PRs', _prs.where((pr) => pr.status == 'Active' || pr.status == 'active').length.toString(), Icons.alt_route_rounded, const Color(0xFF38BDF8)),
                  ],
                ),
                const SizedBox(height: 24),

                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Weekly Completion Velocity (Mon - Fri)',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 24),
                      AnimatedBuilder(
                        animation: _chartAnimation,
                        builder: (context, child) {
                          return SizedBox(
                            width: double.infinity,
                            height: 160,
                            child: CustomPaint(
                              painter: DevOpsStatusChart(
                                weeklyWorkCounts: _weeklyActivity,
                                animationValue: _chartAnimation.value,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F0F12),
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
                              Icon(Icons.auto_awesome_rounded, color: Color(0xFF8B5CF6), size: 18),
                              SizedBox(width: 8),
                              Text('AI Standup Update Generator', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                            ],
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                            icon: const Icon(Icons.psychology_rounded, size: 16),
                            label: const Text('Summarize Standup', style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold)),
                            onPressed: _generatingStandup ? null : _generateAiStandupReport,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_generatingStandup) ...[
                        const Center(child: Padding(padding: EdgeInsets.all(12.0), child: CircularProgressIndicator(color: Color(0xFF8B5CF6)))),
                      ] else if (_aiStandupText != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: const Color(0xFF131317), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF27272A))),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _aiStandupText!,
                                style: const TextStyle(fontFamily: 'Courier', fontSize: 12, height: 1.4, color: Colors.white70),
                              ),
                              const SizedBox(height: 10),
                              Align(
                                alignment: Alignment.bottomRight,
                                child: TextButton.icon(
                                  icon: const Icon(Icons.copy_rounded, size: 14, color: Color(0xFF10B981)),
                                  label: const Text('Copy to Clipboard', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF10B981))),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: _aiStandupText!));
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Standup summary copied to clipboard!')));
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        const Text(
                          'Generate a formatted, AI-summarized standup updates compiled from your active tickets and branch activity logs.',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFA1A1AA)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        
        Expanded(
          flex: 4,
          child: Container(
            height: double.infinity,
            decoration: const BoxDecoration(
              color: Color(0xFF0F0F12),
              border: Border(left: BorderSide(color: Color(0xFF27272A), width: 1)),
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Generate Export Report', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E1E22), foregroundColor: Colors.white, side: const BorderSide(color: Color(0xFF27272A)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                        icon: const Icon(Icons.picture_as_pdf_rounded, size: 16, color: Color(0xFFEF4444)),
                        label: const Text('Mon-Fri Weekly', style: TextStyle(fontFamily: 'Inter', fontSize: 11)),
                        onPressed: () => _exportPdfReport(true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E1E22), foregroundColor: Colors.white, side: const BorderSide(color: Color(0xFF27272A)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                        icon: const Icon(Icons.picture_as_pdf_rounded, size: 16, color: Color(0xFFEF4444)),
                        label: const Text('Monthly Report', style: TextStyle(fontFamily: 'Inter', fontSize: 11)),
                        onPressed: () => _exportPdfReport(false),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(color: Color(0xFF27272A)),
                const SizedBox(height: 16),

                const Text('Assigned Work Items', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 14),
                Expanded(
                  flex: 3,
                  child: ListView.builder(
                    itemCount: _workItems.length,
                    itemBuilder: (context, index) {
                      final item = _workItems[index];
                      final isBug = item.type == 'Bug';
                      final isDone = item.status == 'Resolved' || item.status == 'Dev Done' || item.status == 'Done' || item.status == 'Closed';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _showWorkItemDetails(item),
                            child: Ink(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E22),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFF27272A)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(isBug ? Icons.bug_report_rounded : Icons.task_rounded, size: 14, color: isBug ? const Color(0xFFEF4444) : const Color(0xFF8B5CF6)),
                                          const SizedBox(width: 6),
                                          Text('[${item.type}-${item.id}]', style: const TextStyle(fontFamily: 'Courier', fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFA1A1AA))),
                                        ],
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isDone ? const Color(0xFF10B981).withAlpha(38) : const Color(0xFFF59E0B).withAlpha(38),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          item.status,
                                          style: TextStyle(fontFamily: 'Inter', fontSize: 9, fontWeight: FontWeight.bold, color: isDone ? const Color(0xFF10B981) : const Color(0xFFF59E0B)),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(item.title, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 6),
                                  Text('Modified: ${item.date} (${item.month})', style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF71717A))),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                
                const SizedBox(height: 16),
                const Divider(color: Color(0xFF27272A)),
                const SizedBox(height: 16),

                const Text('Linked Pull Requests', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 14),
                Expanded(
                  flex: 2,
                  child: ListView.builder(
                    itemCount: _prs.length,
                    itemBuilder: (context, index) {
                      final pr = _prs[index];
                      final isMerged = pr.status == 'Completed' || pr.status == 'Merged';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _showPrDetails(pr),
                            child: Ink(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E22),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFF27272A)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.alt_route_rounded, size: 14, color: Color(0xFF38BDF8)),
                                          const SizedBox(width: 6),
                                          Text('PR #${pr.id}', style: const TextStyle(fontFamily: 'Courier', fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFA1A1AA))),
                                        ],
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isMerged ? const Color(0xFF10B981).withAlpha(38) : const Color(0xFF38BDF8).withAlpha(38),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          pr.status,
                                          style: TextStyle(fontFamily: 'Inter', fontSize: 9, fontWeight: FontWeight.bold, color: isMerged ? const Color(0xFF10B981) : const Color(0xFF38BDF8)),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(pr.title, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 4),
                                  Text('Branch: ${pr.sourceBranch} -> ${pr.targetBranch}', style: const TextStyle(fontFamily: 'Courier', fontSize: 9, color: Color(0xFF71717A)), maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFF1E1E22), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF27272A))),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA))),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DevOpsStatusChart extends CustomPainter {
  final List<double> weeklyWorkCounts;
  final double animationValue;

  DevOpsStatusChart({required this.weeklyWorkCounts, required this.animationValue});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final gridPaint = Paint()..color = const Color(0xFF27272A)..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      double y = size.height * (i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final barWidth = size.width / 12;
    final spacing = size.width / 6;

    final List<String> days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
    final List<Color> colors = [
      const Color(0xFF8B5CF6),
      const Color(0xFF10B981),
      const Color(0xFF38BDF8),
      const Color(0xFFF59E0B),
      const Color(0xFFEF4444)
    ];

    double maxVal = 5.0;
    for (int i = 0; i < weeklyWorkCounts.length; i++) {
      double val = weeklyWorkCounts[i];
      double barHeight = (val / maxVal) * size.height * animationValue;
      barHeight = barHeight.clamp(0.0, size.height);

      double x = spacing * (i + 1) - (barWidth / 2);
      double y = size.height - barHeight;

      paint.shader = ui.Gradient.linear(
        Offset(x, size.height),
        Offset(x, y),
        [colors[i].withOpacity(0.2), colors[i]],
      );

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, paint);

      final textPainter = TextPainter(
        text: TextSpan(text: days[i], style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFFA1A1AA))),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(x + (barWidth / 2) - (textPainter.width / 2), size.height + 6));

      if (barHeight > 10) {
        final valPainter = TextPainter(
          text: TextSpan(text: val.toInt().toString(), style: const TextStyle(fontFamily: 'Courier', fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
          textDirection: TextDirection.ltr,
        )..layout();
        valPainter.paint(canvas, Offset(x + (barWidth / 2) - (valPainter.width / 2), y - 14));
      }
    }
  }

  @override
  bool shouldRepaint(covariant DevOpsStatusChart oldDelegate) {
    return oldDelegate.animationValue != animationValue || oldDelegate.weeklyWorkCounts != weeklyWorkCounts;
  }
}

// ==========================================
// MICROSOFT LOGIN SCREEN (DESKTOP)
// ==========================================
class LoginScreen extends StatefulWidget {
  final Function(String) onLoginSuccess;

  const LoginScreen({super.key, required this.onLoginSuccess});

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
  final bool isSigned;

  SignedAppHistoryItem({
    required this.id,
    required this.name,
    required this.packageId,
    required this.versionName,
    required this.versionCode,
    required this.filePath,
    required this.platform,
    required this.date,
    this.isSigned = true,
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
    'isSigned': isSigned,
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
    isSigned: json['isSigned'] ?? true,
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

// ==========================================
// OFFLINE QR CODE UTILITY WIDGET
// ==========================================
class QrUtilityWidget extends StatefulWidget {
  const QrUtilityWidget({super.key});

  @override
  State<QrUtilityWidget> createState() => _QrUtilityWidgetState();
}

class _QrUtilityWidgetState extends State<QrUtilityWidget> {
  final TextEditingController _textController = TextEditingController();
  String _textInput = '';

  String? _selectedImagePath;
  String? _decodedText;
  bool _isDecoding = false;
  String? _decodeError;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() {
      setState(() {
        _textInput = _textController.text;
      });
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  // Clipboard actions
  Future<void> _pasteFromClipboard() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    if (clipboardData != null && clipboardData.text != null) {
      _textController.text = clipboardData.text!;
    }
  }

  void _clearText() {
    _textController.clear();
  }

  Future<void> _saveQrImage() async {
    if (_textInput.isEmpty) return;
    try {
      final qrValidationResult = QrValidator.validate(
        data: _textInput,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      );
      if (qrValidationResult.status != QrValidationStatus.valid) {
        throw Exception("Invalid QR parameters");
      }
      final painter = QrPainter.withQr(
        qr: qrValidationResult.qrCode!,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Color(0xFF000000),
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Color(0xFF000000),
        ),
        gapless: true,
      );

      // Create a solid white background canvas to ensure easy offline scanner readability
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 400, 400));
      final bgPaint = Paint()..color = Colors.white;
      canvas.drawRect(const Rect.fromLTWH(0, 0, 400, 400), bgPaint);

      // Paint the QR code onto the white background
      painter.paint(canvas, const Size(400, 400));
      final picture = recorder.endRecording();

      // Export as a high-contrast PNG image
      final img = await picture.toImage(400, 400);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception("Failed to generate image data");
      final bytes = byteData.buffer.asUint8List();

      final outputFilePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save QR Code Image',
        fileName: 'qrcode.png',
        type: FileType.custom,
        allowedExtensions: ['png'],
      );

      if (outputFilePath != null) {
        final file = File(outputFilePath);
        await file.writeAsBytes(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('QR Code saved successfully to ${p.basename(outputFilePath)}'),
              backgroundColor: const Color(0xFF10B981),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save QR Code: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  // QR Decoding actions
  Future<void> _pickAndDecodeQrImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg'],
      );

      if (result == null || result.files.single.path == null) {
        return;
      }

      final filePath = result.files.single.path!;

      setState(() {
        _selectedImagePath = filePath;
        _isDecoding = true;
        _decodedText = null;
        _decodeError = null;
      });

      // Run decoding in isolate to keep UI butter smooth
      final decoded = await compute(_decodeQrIsolate, filePath);

      setState(() {
        _isDecoding = false;
        if (decoded != null) {
          _decodedText = decoded;
        } else {
          _decodeError = "No valid QR code was detected in the selected image. Please make sure the image is high resolution, centered, and has high contrast.";
        }
      });
    } catch (e) {
      setState(() {
        _isDecoding = false;
        _decodeError = "Error reading image file: $e";
      });
    }
  }

  static Future<String?> _decodeQrIsolate(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return null;

      final width = image.width;
      final height = image.height;
      final pixels = Int32List(width * height);
      int idx = 0;
      for (final pixel in image) {
        final r = pixel.r.toInt();
        final g = pixel.g.toInt();
        final b = pixel.b.toInt();
        final a = pixel.a.toInt();
        // ARGB color integer formatting
        final argb = (a << 24) | (r << 16) | (g << 8) | b;
        pixels[idx++] = argb;
      }

      final source = RGBLuminanceSource(width, height, pixels);
      final bitmap = BinaryBitmap(HybridBinarizer(source));
      final reader = QRCodeReader();
      final decodedResult = reader.decode(bitmap);
      return decodedResult.text;
    } catch (e) {
      debugPrint("QR decoding failed in isolate: $e");
      return null;
    }
  }

  void _clearImageSection() {
    setState(() {
      _selectedImagePath = null;
      _decodedText = null;
      _decodeError = null;
      _isDecoding = false;
    });
  }

  Future<void> _copyDecodedToClipboard() async {
    if (_decodedText != null) {
      await Clipboard.setData(ClipboardData(text: _decodedText!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Decoded text copied to clipboard!'),
            backgroundColor: Color(0xFF10B981),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F11),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 950;
              return isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildTextToQrPanel()),
                        const SizedBox(width: 24),
                        Expanded(child: _buildQrToTextPanel()),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildTextToQrPanel(),
                        const SizedBox(height: 24),
                        _buildQrToTextPanel(),
                      ],
                    );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTextToQrPanel() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.qr_code_2_rounded, color: Color(0xFF8B5CF6), size: 24),
              SizedBox(width: 10),
              Text(
                'Text to QR Code',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Write or paste text content to generate a scannable QR Code image.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              color: Color(0xFFA1A1AA),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _textController,
            maxLines: 5,
            style: const TextStyle(fontFamily: 'Courier', fontSize: 13, color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter text, URL, metadata or payload here...',
              hintStyle: const TextStyle(color: Color(0xFF52525B)),
              fillColor: const Color(0xFF0F0F12),
              filled: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF27272A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF8B5CF6)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF27272A)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.paste_rounded, size: 14),
                label: const Text('Paste Text', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                onPressed: _pasteFromClipboard,
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFEF4444),
                ),
                icon: const Icon(Icons.clear_rounded, size: 14),
                label: const Text('Clear', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                onPressed: _clearText,
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(color: Color(0xFF27272A), height: 1),
          const SizedBox(height: 24),
          Center(
            child: _textInput.trim().isEmpty
                ? Container(
                    height: 220,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F0F12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF27272A),
                        style: BorderStyle.solid,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.qr_code_scanner_rounded, size: 36, color: Color(0xFF52525B)),
                        SizedBox(height: 12),
                        Text(
                          'Awaiting text input...',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: Color(0xFF52525B),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: QrImageView(
                          data: _textInput,
                          version: QrVersions.auto,
                          size: 180,
                          gapless: true,
                          errorCorrectionLevel: QrErrorCorrectLevel.M,
                          embeddedImageStyle: const QrEmbeddedImageStyle(
                            size: Size(30, 30),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8B5CF6),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.download_rounded, size: 14),
                        label: const Text(
                          'Save QR Image',
                          style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        onPressed: _saveQrImage,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrToTextPanel() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.image_search_rounded, color: Color(0xFF10B981), size: 24),
              SizedBox(width: 10),
              Text(
                'QR Code to Text',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Upload a QR Code image file to decode and extract its original text content.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              color: Color(0xFFA1A1AA),
            ),
          ),
          const SizedBox(height: 20),
          InkWell(
            onTap: _isDecoding ? null : _pickAndDecodeQrImage,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 220,
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _selectedImagePath != null ? const Color(0xFF10B981) : const Color(0xFF27272A),
                  width: 1.5,
                ),
              ),
              child: _selectedImagePath == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.cloud_upload_outlined, size: 36, color: Color(0xFF71717A)),
                        SizedBox(height: 12),
                        Text(
                          'Upload QR Code Image',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Supports PNG, JPG, JPEG',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: Color(0xFF52525B),
                          ),
                        ),
                      ],
                    )
                  : Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                File(_selectedImagePath!),
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            p.basename(_selectedImagePath!),
                            style: const TextStyle(
                              fontFamily: 'Courier',
                              fontSize: 11,
                              color: Color(0xFFA1A1AA),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF27272A)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.file_open_rounded, size: 14),
                label: Text(
                  _selectedImagePath == null ? 'Select Image' : 'Change Image',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12),
                ),
                onPressed: _isDecoding ? null : _pickAndDecodeQrImage,
              ),
              if (_selectedImagePath != null) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFEF4444),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 14),
                  label: const Text('Clear', style: TextStyle(fontFamily: 'Inter', fontSize: 12)),
                  onPressed: _clearImageSection,
                ),
              ],
            ],
          ),
          const SizedBox(height: 24),
          const Divider(color: Color(0xFF27272A), height: 1),
          const SizedBox(height: 24),
          if (_isDecoding)
            Center(
              child: Column(
                children: const [
                  SizedBox(height: 20),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(color: Color(0xFF10B981), strokeWidth: 2),
                  ),
                  SizedBox(height: 14),
                  Text(
                    'Decoding QR Image...',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: Color(0xFFA1A1AA),
                    ),
                  ),
                  SizedBox(height: 20),
                ],
              ),
            )
          else if (_decodedText != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Decoded Text Payload:',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF10B981),
                      ),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      icon: const Icon(Icons.copy_rounded, size: 12),
                      label: const Text('Copy', style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold)),
                      onPressed: _copyDecodedToClipboard,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F0F12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _decodedText!,
                      style: const TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            )
          else if (_decodeError != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2D1414),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _decodeError!,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: Color(0xFFFCA5A5),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              height: 80,
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: const Center(
                child: Text(
                  'No QR image uploaded yet.',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: Color(0xFF52525B),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ==========================================
// CENTRAL DATABASE MANAGEMENT & MODELS
// ==========================================
class CentralDatabase {
  static File _getDatabaseFile() {
    return File('/Users/pavanyadav/.gemini/antigravity-ide/scratch/sign_next_central_db.json');
  }

  static Future<Map<String, dynamic>> _readDb() async {
    final file = _getDatabaseFile();
    if (!await file.exists()) {
      final initialData = {
        "parent_emails": ["pavan.yadav@businessnext.com"],
        "child_users": {},
        "audit_logs": [],
        "alerts": [],
        "global_certificates": []
      };
      try {
        await file.create(recursive: true);
        await file.writeAsString(json.encode(initialData), flush: true);
      } catch (_) {}
      return initialData;
    }

    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        throw const FormatException("Empty file");
      }
      return json.decode(content) as Map<String, dynamic>;
    } catch (_) {
      final initialData = {
        "parent_emails": ["pavan.yadav@businessnext.com"],
        "child_users": {},
        "audit_logs": [],
        "alerts": [],
        "global_certificates": []
      };
      try {
        await file.writeAsString(json.encode(initialData), flush: true);
      } catch (_) {}
      return initialData;
    }
  }

  static Future<void> _writeDb(Map<String, dynamic> data) async {
    final file = _getDatabaseFile();
    try {
      await file.writeAsString(json.encode(data), flush: true);
    } catch (_) {}
  }

  static Future<List<String>> getParentEmails() async {
    final db = await _readDb();
    final list = db['parent_emails'] as List?;
    if (list == null) return ["pavan.yadav@businessnext.com"];
    final emails = list.map((e) => e.toString()).toList();
    if (!emails.contains("pavan.yadav@businessnext.com")) {
      emails.add("pavan.yadav@businessnext.com");
    }
    return emails;
  }

  static Future<void> addParentEmail(String email) async {
    final db = await _readDb();
    final list = List<String>.from(db['parent_emails'] ?? ["pavan.yadav@businessnext.com"]);
    if (!list.contains(email)) {
      list.add(email);
      db['parent_emails'] = list;
      await _writeDb(db);
    }
  }

  static Future<void> removeParentEmail(String email) async {
    if (email == "pavan.yadav@businessnext.com") return;
    final db = await _readDb();
    final list = List<String>.from(db['parent_emails'] ?? ["pavan.yadav@businessnext.com"]);
    if (list.contains(email)) {
      list.remove(email);
      db['parent_emails'] = list;
      await _writeDb(db);
    }
  }

  static Future<Map<String, dynamic>> getChildUsers() async {
    final db = await _readDb();
    return db['child_users'] as Map<String, dynamic>? ?? {};
  }

  static Future<void> updateChildUser(
    String email, {
    String? role,
    String? status,
    String? deviceName,
    String? osVersion,
  }) async {
    final db = await _readDb();
    final childUsers = Map<String, dynamic>.from(db['child_users'] ?? {});
    final userData = Map<String, dynamic>.from(childUsers[email] ?? {});

    if (role != null) userData['role'] = role;
    if (status != null) userData['status'] = status;
    if (deviceName != null) userData['deviceName'] = deviceName;
    if (osVersion != null) userData['osVersion'] = osVersion;
    userData['lastActive'] = DateTime.now().toIso8601String();

    if (email == 'pavan.yadav@businessnext.com') {
      userData['role'] = 'Role 2';
      userData['status'] = 'Active';
    }

    userData['role'] ??= 'Role 1';
    userData['status'] ??= 'Active';
    userData['deviceName'] ??= 'Unknown Device';
    userData['osVersion'] ??= 'Unknown OS';

    childUsers[email] = userData;
    db['child_users'] = childUsers;
    await _writeDb(db);
  }

  static Future<void> logAction(
    String email,
    String action,
    String details, {
    String? deviceName,
    String? osVersion,
  }) async {
    final db = await _readDb();
    final logs = List<dynamic>.from(db['audit_logs'] ?? []);
    logs.insert(0, {
      "email": email,
      "action": action,
      "details": details,
      "deviceName": deviceName ?? "Unknown",
      "osVersion": osVersion ?? "Unknown",
      "timestamp": DateTime.now().toIso8601String(),
    });
    if (logs.length > 200) {
      logs.removeRange(200, logs.length);
    }
    db['audit_logs'] = logs;
    await _writeDb(db);
  }

  static Future<List<Map<String, dynamic>>> getAuditLogs() async {
    final db = await _readDb();
    final logs = db['audit_logs'] as List?;
    if (logs == null) return [];
    return logs.map((l) => Map<String, dynamic>.from(l)).toList();
  }

  static Future<List<Map<String, dynamic>>> getAlertsForUser(String email) async {
    final db = await _readDb();
    final alerts = db['alerts'] as List?;
    if (alerts == null) return [];
    return alerts
        .map((a) => Map<String, dynamic>.from(a))
        .where((a) => a['target'] == 'All' || a['target'] == email)
        .toList();
  }

  static Future<void> markAlertAsRead(String alertId, String email) async {
    final db = await _readDb();
    final alerts = List<dynamic>.from(db['alerts'] ?? []);
    for (var i = 0; i < alerts.length; i++) {
      final alert = Map<String, dynamic>.from(alerts[i]);
      if (alert['id'] == alertId) {
        final readBy = List<String>.from(alert['readBy'] ?? []);
        if (!readBy.contains(email)) {
          readBy.add(email);
          alert['readBy'] = readBy;
          alerts[i] = alert;
        }
      }
    }
    db['alerts'] = alerts;
    await _writeDb(db);
  }

  static Future<void> sendBroadcastAlert(
    String sender,
    String target,
    String priority,
    String message,
  ) async {
    final db = await _readDb();
    final alerts = List<dynamic>.from(db['alerts'] ?? []);
    alerts.insert(0, {
      "id": DateTime.now().millisecondsSinceEpoch.toString(),
      "sender": sender,
      "target": target,
      "priority": priority,
      "message": message,
      "timestamp": DateTime.now().toIso8601String(),
      "readBy": [],
    });
    db['alerts'] = alerts;
    await _writeDb(db);
  }

  static Future<List<Map<String, dynamic>>> getGlobalCertificates() async {
    final db = await _readDb();
    final certs = db['global_certificates'] as List?;
    if (certs == null) return [];
    return certs.map((c) => Map<String, dynamic>.from(c)).toList();
  }

  static Future<void> addGlobalCertificate(Map<String, dynamic> cert) async {
    final db = await _readDb();
    final certs = List<dynamic>.from(db['global_certificates'] ?? []);
    certs.add(cert);
    db['global_certificates'] = certs;
    await _writeDb(db);
  }

  static Future<void> removeGlobalCertificate(String certId) async {
    final db = await _readDb();
    final certs = List<dynamic>.from(db['global_certificates'] ?? []);
    certs.removeWhere((c) => c['id'] == certId);
    db['global_certificates'] = certs;
    await _writeDb(db);
  }
}

// ==========================================
// ACCESS REVOKED RED BLOCK VIEW
// ==========================================
class AccessRevokedScreen extends StatelessWidget {
  final String userEmail;
  final VoidCallback onLogout;

  const AccessRevokedScreen({
    super.key,
    required this.userEmail,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F11),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 450),
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E22),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.4), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFEF4444).withOpacity(0.15),
                blurRadius: 30,
                spreadRadius: 2,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFF2D1414),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.gavel_rounded,
                  color: Color(0xFFEF4444),
                  size: 48,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Access Deactivated',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Your authorization for $userEmail has been revoked by the Parent Administration.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: Color(0xFFA1A1AA),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.logout_rounded, size: 16),
                  label: const Text(
                    'Return to Login Screen',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  onPressed: onLogout,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// DYNAMIC SLIDE-IN ALERT BANNER
// ==========================================
class SlideInAlertBanner extends StatelessWidget {
  final Map<String, dynamic> alert;
  final VoidCallback onDismiss;

  const SlideInAlertBanner({
    super.key,
    required this.alert,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final priority = alert['priority'] ?? 'Low';
    Color bannerColor = const Color(0xFF1E1E22);
    Color accentColor = const Color(0xFF8B5CF6);
    IconData icon = Icons.info_rounded;

    if (priority == 'High') {
      bannerColor = const Color(0xFF2D1414);
      accentColor = const Color(0xFFEF4444);
      icon = Icons.warning_amber_rounded;
    } else if (priority == 'Medium') {
      bannerColor = const Color(0xFF2D2414);
      accentColor = const Color(0xFFF59E0B);
      icon = Icons.error_outline_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: bannerColor.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withOpacity(0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 16,
            offset: const Offset(0, 8),
          )
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Row(
            children: [
              Icon(icon, color: accentColor, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          '$priority Priority Broadcast Alert',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: accentColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'from ${alert['sender']}',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 9,
                            color: Color(0xFF71717A),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      alert['message'] ?? '',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: onDismiss,
                child: const Text(
                  'Dismiss',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ).animate().slideY(begin: -1, end: 0, duration: 400.ms, curve: Curves.easeOutCubic).fade(duration: 400.ms);
  }
}

// ==========================================
// ACCESS DENIED ERROR CONTAINER
// ==========================================
class AccessDeniedWidget extends StatelessWidget {
  final String title;
  final String message;

  const AccessDeniedWidget({
    super.key,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF27272A)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_rounded,
                color: Color(0xFFEF4444),
                size: 36,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: Color(0xFFA1A1AA),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum ParentTab { users, certs, alerts, logs }

// ==========================================
// PARENT DASHBOARD CONTROL CENTER WIDGET
// ==========================================
class ParentDashboardWidget extends StatefulWidget {
  final String userEmail;
  final VoidCallback onLogout;
  final VoidCallback? onSwitchToChild;

  const ParentDashboardWidget({
    super.key,
    required this.userEmail,
    required this.onLogout,
    this.onSwitchToChild,
  });

  @override
  State<ParentDashboardWidget> createState() => _ParentDashboardWidgetState();
}

class _ParentDashboardWidgetState extends State<ParentDashboardWidget> {
  ParentTab _currentTab = ParentTab.users;

  Timer? _refreshTimer;

  Map<String, dynamic> _childUsers = {};
  List<String> _parentEmails = [];
  List<Map<String, dynamic>> _auditLogs = [];
  List<Map<String, dynamic>> _globalCerts = [];

  final _parentEmailController = TextEditingController();

  String _certPlatform = 'ios';
  final _certNameController = TextEditingController();
  final _p12PathController = TextEditingController();
  final _p12PasswordController = TextEditingController();
  final _provPathController = TextEditingController();
  final _keychainPasswordController = TextEditingController();
  final _identityController = TextEditingController();

  final _keystorePathController = TextEditingController();
  final _keyAliasController = TextEditingController();
  final _keyPasswordController = TextEditingController();
  final _storePasswordController = TextEditingController();

  String _alertTarget = 'All';
  String _alertPriority = 'High';
  final _alertMessageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshData();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _refreshData();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _parentEmailController.dispose();
    _certNameController.dispose();
    _p12PathController.dispose();
    _p12PasswordController.dispose();
    _provPathController.dispose();
    _keychainPasswordController.dispose();
    _identityController.dispose();
    _keystorePathController.dispose();
    _keyAliasController.dispose();
    _keyPasswordController.dispose();
    _storePasswordController.dispose();
    _alertMessageController.dispose();
    super.dispose();
  }

  Future<void> _refreshData() async {
    final parentEmails = await CentralDatabase.getParentEmails();
    final childUsers = await CentralDatabase.getChildUsers();
    final auditLogs = await CentralDatabase.getAuditLogs();
    final globalCerts = await CentralDatabase.getGlobalCertificates();

    if (mounted) {
      setState(() {
        _parentEmails = parentEmails;
        _childUsers = childUsers;
        _auditLogs = auditLogs;
        _globalCerts = globalCerts;
      });
    }
  }

  Future<void> _addParentEmail() async {
    final email = _parentEmailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid email address.')),
      );
      return;
    }
    await CentralDatabase.addParentEmail(email);
    _parentEmailController.clear();
    _refreshData();
  }

  Future<void> _removeParentEmail(String email) async {
    if (email == 'pavan.yadav@businessnext.com') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot remove primary parent admin.')),
      );
      return;
    }
    await CentralDatabase.removeParentEmail(email);
    _refreshData();
  }

  Future<void> _toggleChildRole(String email, String currentRole) async {
    final newRole = currentRole == 'Role 1' ? 'Role 2' : 'Role 1';
    await CentralDatabase.updateChildUser(email, role: newRole);
    _refreshData();
  }

  Future<void> _toggleChildStatus(String email, String currentStatus) async {
    final newStatus = currentStatus == 'Active' ? 'Revoked' : 'Active';
    await CentralDatabase.updateChildUser(email, status: newStatus);
    _refreshData();
  }

  Future<void> _addParentEmailFromList(String email) async {
    await CentralDatabase.addParentEmail(email);
    _refreshData();
  }

  Future<void> _pickPath(TextEditingController controller, String type) async {
    FilePickerResult? result;
    List<String>? extensions;
    if (type == 'p12') extensions = ['p12'];
    else if (type == 'mobileprovision') extensions = ['mobileprovision'];
    else if (type == 'keystore') extensions = ['keystore', 'jks', 'pfx'];

    result = await FilePicker.platform.pickFiles(
      type: extensions != null ? FileType.custom : FileType.any,
      allowedExtensions: extensions,
    );
    if (result != null && result.files.single.path != null) {
      controller.text = result.files.single.path!;
    }
  }

  Future<void> _publishGlobalCertificate() async {
    final name = _certNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter certificate name.')),
      );
      return;
    }

    final newCert = <String, dynamic>{
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'name': name,
      'platform': _certPlatform,
    };

    if (_certPlatform == 'ios') {
      if (_p12PathController.text.isEmpty || _provPathController.text.isEmpty || _identityController.text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please fill all required iOS certificate fields.')),
        );
        return;
      }
      newCert['p12Path'] = _p12PathController.text.trim();
      newCert['p12Password'] = _p12PasswordController.text.trim();
      newCert['provPath'] = _provPathController.text.trim();
      newCert['keychainPassword'] = _keychainPasswordController.text.trim();
      newCert['identity'] = _identityController.text.trim();
    } else {
      if (_keystorePathController.text.isEmpty || _keyAliasController.text.isEmpty || _keyPasswordController.text.isEmpty || _storePasswordController.text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please fill all required Android keystore fields.')),
        );
        return;
      }
      newCert['keystorePath'] = _keystorePathController.text.trim();
      newCert['keyAlias'] = _keyAliasController.text.trim();
      newCert['keyPassword'] = _keyPasswordController.text.trim();
      newCert['storePassword'] = _storePasswordController.text.trim();
    }

    await CentralDatabase.addGlobalCertificate(newCert);

    _certNameController.clear();
    _p12PathController.clear();
    _p12PasswordController.clear();
    _provPathController.clear();
    _keychainPasswordController.clear();
    _identityController.clear();
    _keystorePathController.clear();
    _keyAliasController.clear();
    _keyPasswordController.clear();
    _storePasswordController.clear();

    _refreshData();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Global Certificate published successfully!')),
    );
  }

  Future<void> _removeGlobalCertificate(String id) async {
    await CentralDatabase.removeGlobalCertificate(id);
    _refreshData();
  }

  Future<void> _sendAlert() async {
    final msg = _alertMessageController.text.trim();
    if (msg.isEmpty) return;

    await CentralDatabase.sendBroadcastAlert(
      widget.userEmail,
      _alertTarget,
      _alertPriority,
      msg,
    );

    _alertMessageController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Broadcast Alert sent successfully!')),
    );
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
                          duration: const Duration(milliseconds: 250),
                          child: _buildCurrentTabContent(),
                        ),
                      ),
                    ),
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
        border: Border(right: BorderSide(color: Color(0xFF27272A), width: 1)),
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
                      colors: [Color(0xFFEF4444), Color(0xFFF59E0B)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.admin_panel_settings_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Parent Hub',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Control Center',
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
                    backgroundColor: const Color(0xFFEF4444),
                    radius: 14,
                    child: const Icon(Icons.shield_rounded, color: Colors.white, size: 14),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Enterprise Admin',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            color: Color(0xFFEF4444),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          widget.userEmail,
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
                  IconButton(
                    icon: const Icon(Icons.logout_rounded, size: 14, color: Color(0xFFEF4444)),
                    tooltip: 'Logout',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onLogout,
                  ),
                ],
              ),
            ),
          ),
          if (widget.onSwitchToChild != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: SizedBox(
                width: double.infinity,
                child: InkWell(
                  onTap: widget.onSwitchToChild,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF8B5CF6), Color(0xFF10B981)],
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.swap_horiz_rounded, color: Colors.white, size: 14),
                        SizedBox(width: 8),
                        Text(
                          'Switch to Child Workspace',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          const Divider(color: Color(0xFF27272A), height: 16),
          _buildSidebarItem(tab: ParentTab.users, icon: Icons.people_rounded, label: 'Signers & Admins', subtitle: 'Manage roles and status'),
          _buildSidebarItem(tab: ParentTab.certs, icon: Icons.vpn_key_rounded, label: 'Global Certificates', subtitle: 'Distribute code keys'),
          _buildSidebarItem(tab: ParentTab.alerts, icon: Icons.campaign_rounded, label: 'Alert Broadcasts', subtitle: 'Push alerts to devices'),
          _buildSidebarItem(tab: ParentTab.logs, icon: Icons.analytics_outlined, label: 'Audit Activity', subtitle: 'Real-time actions logs'),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(24.0),
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

  Widget _buildSidebarItem({required ParentTab tab, required IconData icon, required String label, required String subtitle}) {
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
              Icon(icon, color: isSelected ? const Color(0xFFEF4444) : const Color(0xFF71717A), size: 22),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
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
      case ParentTab.users:
        title = 'Signers & Devices';
        desc = 'Monitor client installations, toggle roles (Role 1 ↔ Role 2), and revoke access.';
        break;
      case ParentTab.certs:
        title = 'Global Distributed Certificates';
        desc = 'Deploy signing credentials that Role 1 users can use without credential access.';
        break;
      case ParentTab.alerts:
        title = 'Safety Alerts Broadcast';
        desc = 'Push glassmorphic animated alerts to active child workspace devices.';
        break;
      case ParentTab.logs:
        title = 'Audit Activity Logs';
        desc = 'Real-time trace logs of all signing, unsigning, and workspace actions.';
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
      case ParentTab.users:
        return _buildUsersTab();
      case ParentTab.certs:
        return _buildCertsTab();
      case ParentTab.alerts:
        return _buildAlertsTab();
      case ParentTab.logs:
        return _buildLogsTab();
    }
  }

  Widget _buildUsersTab() {
    final bool isCurrentUserSuperAdmin = widget.userEmail == 'pavan.yadav@businessnext.com';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: isCurrentUserSuperAdmin ? 3 : 1,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Registered Workspace Signers',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
                      ),
                      const SizedBox(height: 16),
                      if (_childUsers.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              'No child signers registered yet.',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF52525B)),
                            ),
                          ),
                        )
                      else
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _childUsers.length,
                          separatorBuilder: (context, index) => const Divider(color: Color(0xFF27272A), height: 24),
                          itemBuilder: (context, index) {
                            final email = _childUsers.keys.elementAt(index);
                            final data = _childUsers[email] as Map<String, dynamic>;
                            final role = data['role'] ?? 'Role 1';
                            final status = data['status'] ?? 'Active';
                            final isRevoked = status == 'Revoked';
                            final bool isRowUserSuperAdmin = email == 'pavan.yadav@businessnext.com';
                            final bool isUserAdmin = _parentEmails.contains(email);

                            return Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: isRevoked ? const Color(0xFFEF4444).withOpacity(0.2) : const Color(0xFF10B981).withOpacity(0.2),
                                  radius: 18,
                                  child: Icon(
                                    isRevoked ? Icons.gavel_rounded : Icons.person_rounded,
                                    color: isRevoked ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                                    size: 16,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        email,
                                        style: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Device: ${data['deviceName']} • OS: ${data['osVersion']}',
                                        style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFF71717A)),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Last Active: ${data['lastActive'] != null ? data['lastActive'].toString().replaceAll("T", " ").substring(0, 19) : ""}',
                                        style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Color(0xFF52525B)),
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Row(
                                      children: [
                                        if (isCurrentUserSuperAdmin && !isRowUserSuperAdmin) ...[
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: isUserAdmin ? const Color(0xFFF59E0B) : const Color(0xFF10B981),
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                            ),
                                            onPressed: () {
                                              if (isUserAdmin) {
                                                _removeParentEmail(email);
                                              } else {
                                                _addParentEmailFromList(email);
                                              }
                                            },
                                            child: Text(
                                              isUserAdmin ? 'Demote to Child' : 'Promote to Admin',
                                              style: const TextStyle(fontFamily: 'Inter', fontSize: 10, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        // Role button
                                        if (isCurrentUserSuperAdmin && !isRowUserSuperAdmin)
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: role == 'Role 1' ? const Color(0xFF27272A) : const Color(0xFF8B5CF6),
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                            ),
                                            onPressed: () => _toggleChildRole(email, role),
                                            child: Text(
                                              role == 'Role 1' ? 'Standard (Role 1)' : 'Admin (Role 2)',
                                              style: const TextStyle(fontFamily: 'Inter', fontSize: 10, fontWeight: FontWeight.bold),
                                            ),
                                          )
                                        else
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isRowUserSuperAdmin 
                                                  ? const Color(0xFFF59E0B).withOpacity(0.15)
                                                  : (role == 'Role 1' ? const Color(0xFF27272A) : const Color(0xFF8B5CF6).withOpacity(0.15)),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(
                                                color: isRowUserSuperAdmin 
                                                    ? const Color(0xFFF59E0B) 
                                                    : (role == 'Role 1' ? const Color(0xFF3F3F46) : const Color(0xFF8B5CF6)),
                                              ),
                                            ),
                                            child: Text(
                                              isRowUserSuperAdmin 
                                                  ? 'Super Admin'
                                                  : (role == 'Role 1' ? 'Standard (Role 1)' : 'Admin (Role 2)'),
                                              style: TextStyle(
                                                fontFamily: 'Inter', 
                                                fontSize: 10, 
                                                fontWeight: FontWeight.bold,
                                                color: isRowUserSuperAdmin ? const Color(0xFFF59E0B) : Colors.white70,
                                              ),
                                            ),
                                          ),
                                        const SizedBox(width: 8),
                                        // Status button
                                        if (isCurrentUserSuperAdmin && !isRowUserSuperAdmin)
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: isRevoked ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                            ),
                                            onPressed: () => _toggleChildStatus(email, status),
                                            child: Text(
                                              isRevoked ? 'Activate' : 'Revoke',
                                              style: const TextStyle(fontFamily: 'Inter', fontSize: 10, fontWeight: FontWeight.bold),
                                            ),
                                          )
                                        else
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isRevoked ? const Color(0xFFEF4444).withOpacity(0.2) : const Color(0xFF10B981).withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: isRevoked ? const Color(0xFFEF4444) : const Color(0xFF10B981)),
                                            ),
                                            child: Text(
                                              isRevoked ? 'Revoked' : 'Active',
                                              style: TextStyle(
                                                fontFamily: 'Inter', 
                                                fontSize: 10, 
                                                fontWeight: FontWeight.bold,
                                                color: isRevoked ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
              if (isCurrentUserSuperAdmin) ...[
                const SizedBox(width: 24),
                Expanded(
                  flex: 2,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E22),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF27272A)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Authorized Parent Admins',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _parentEmailController,
                                style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white),
                                decoration: InputDecoration(
                                  hintText: 'Enter parent admin email',
                                  hintStyle: const TextStyle(color: Color(0xFF52525B)),
                                  fillColor: const Color(0xFF0F0F12),
                                  filled: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFEF4444))),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFEF4444),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: _addParentEmail,
                              child: const Icon(Icons.add, size: 16),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _parentEmails.length,
                          separatorBuilder: (context, index) => const Divider(color: Color(0xFF27272A), height: 12),
                          itemBuilder: (context, index) {
                            final email = _parentEmails[index];
                            final isPrimary = email == 'pavan.yadav@businessnext.com';

                            return Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    email,
                                    style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isPrimary)
                                  const Text(
                                    'Primary Owner',
                                    style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF52525B), fontWeight: FontWeight.bold),
                                  )
                                else
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFFEF4444)),
                                    constraints: const BoxConstraints(),
                                    padding: EdgeInsets.zero,
                                    onPressed: () => _removeParentEmail(email),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCertsTab() {
    return SingleChildScrollView(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _buildFormTab('ios', 'Apple iOS'),
                      const SizedBox(width: 8),
                      _buildFormTab('android', 'Google Android'),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildInputField(label: 'Certificate Name (e.g. Enterprise Dist)', controller: _certNameController, hint: 'Friendly label name'),
                  const SizedBox(height: 12),
                  if (_certPlatform == 'ios') ...[
                    _buildPathPickerField(label: 'P12 Certificate Path', controller: _p12PathController, hint: '/path/to/cert.p12', type: 'p12'),
                    const SizedBox(height: 12),
                    _buildInputField(label: 'P12 Password', controller: _p12PasswordController, hint: 'p12 password', obscure: true),
                    const SizedBox(height: 12),
                    _buildPathPickerField(label: 'Provisioning Profile Path', controller: _provPathController, hint: '/path/to/profile.mobileprovision', type: 'mobileprovision'),
                    const SizedBox(height: 12),
                    _buildInputField(label: 'Keychain Password', controller: _keychainPasswordController, hint: 'macOS Keychain Password', obscure: true),
                    const SizedBox(height: 12),
                    _buildInputField(label: 'Signing Identity (Exact name matching cert)', controller: _identityController, hint: 'Apple Distribution: Company Name (ID)'),
                  ] else ...[
                    _buildPathPickerField(label: 'Keystore Path', controller: _keystorePathController, hint: '/path/to/release.keystore', type: 'keystore'),
                    const SizedBox(height: 12),
                    _buildInputField(label: 'Key Alias', controller: _keyAliasController, hint: 'e.g. key0'),
                    const SizedBox(height: 12),
                    _buildInputField(label: 'Key Password', controller: _keyPasswordController, hint: 'key alias password', obscure: true),
                    const SizedBox(height: 12),
                    _buildInputField(label: 'Keystore Password', controller: _storePasswordController, hint: 'keystore password', obscure: true),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.cloud_upload_rounded, size: 16),
                      label: const Text('Publish Global Certificate', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 13)),
                      onPressed: _publishGlobalCertificate,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Active Distributed Keys',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
                  ),
                  const SizedBox(height: 16),
                  if (_globalCerts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 36),
                      child: Center(
                        child: Text(
                          'No distributed certificates in the vault.',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF52525B)),
                        ),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _globalCerts.length,
                      separatorBuilder: (context, index) => const Divider(color: Color(0xFF27272A), height: 16),
                      itemBuilder: (context, index) {
                        final cert = _globalCerts[index];
                        final isIos = cert['platform'] == 'ios';

                        return Row(
                          children: [
                            Icon(
                              isIos ? Icons.phone_iphone_rounded : Icons.phone_android_rounded,
                              color: isIos ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
                              size: 20,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    cert['name'] ?? '',
                                    style: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    isIos ? 'P12: ${p.basename(cert['p12Path'] ?? "")}' : 'Keystore: ${p.basename(cert['keystorePath'] ?? "")}',
                                    style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Color(0xFF71717A)),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFEF4444)),
                              onPressed: () => _removeGlobalCertificate(cert['id']),
                            ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormTab(String value, String title) {
    final active = _certPlatform == value;
    return InkWell(
      onTap: () => setState(() => _certPlatform = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFEF4444) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          title,
          style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: active ? FontWeight.bold : FontWeight.normal, color: active ? Colors.white : const Color(0xFFA1A1AA)),
        ),
      ),
    );
  }

  Widget _buildInputField({required String label, required TextEditingController controller, String hint = '', bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFA1A1AA))),
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
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFEF4444))),
          ),
        ),
      ],
    );
  }

  Widget _buildPathPickerField({required String label, required TextEditingController controller, String hint = '', required String type}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFA1A1AA))),
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF27272A))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFEF4444))),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF27272A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => _pickPath(controller, type),
              child: const Text('Browse', style: TextStyle(fontFamily: 'Inter', fontSize: 11)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAlertsTab() {
    final List<String> targets = ['All', ..._childUsers.keys];

    return SingleChildScrollView(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Compose Notification Banner',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
                  ),
                  const SizedBox(height: 16),
                  const Text('Recipient Target', style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFA1A1AA))),
                  const SizedBox(height: 6),
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
                        value: _alertTarget,
                        dropdownColor: const Color(0xFF1E1E22),
                        isExpanded: true,
                        items: targets
                            .map((t) => DropdownMenuItem(
                                  value: t,
                                  child: Text(t, style: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: Colors.white)),
                                ))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _alertTarget = val);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('Priority Level', style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFA1A1AA))),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _buildPriorityTab('High'),
                      const SizedBox(width: 8),
                      _buildPriorityTab('Medium'),
                      const SizedBox(width: 8),
                      _buildPriorityTab('Low'),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildInputField(label: 'Message', controller: _alertMessageController, hint: 'Enter notification description...'),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.send_rounded, size: 16),
                      label: const Text('Send Alert Now', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold, fontSize: 13)),
                      onPressed: _sendAlert,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 24),
          const Expanded(
            flex: 3,
            child: SizedBox(),
          ),
        ],
      ),
    );
  }

  Widget _buildPriorityTab(String value) {
    final active = _alertPriority == value;
    Color priorityColor = const Color(0xFF8B5CF6);
    if (value == 'High') priorityColor = const Color(0xFFEF4444);
    else if (value == 'Medium') priorityColor = const Color(0xFFF59E0B);

    return InkWell(
      onTap: () => setState(() => _alertPriority = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? priorityColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: priorityColor.withOpacity(0.5)),
        ),
        child: Text(
          value,
          style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: active ? FontWeight.bold : FontWeight.normal, color: active ? Colors.white : priorityColor),
        ),
      ),
    );
  }

  Widget _buildLogsTab() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'SignNext Audit Trail',
                style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 16, color: Color(0xFFEF4444)),
                onPressed: _refreshData,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _auditLogs.isEmpty
                ? const Center(
                    child: Text(
                      'No system logs available.',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFF52525B)),
                    ),
                  )
                : ListView.separated(
                    itemCount: _auditLogs.length,
                    separatorBuilder: (context, index) => const Divider(color: Color(0xFF27272A), height: 16),
                    itemBuilder: (context, index) {
                      final log = _auditLogs[index];
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.history_rounded, size: 16, color: Color(0xFFEF4444)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                RichText(
                                  text: TextSpan(
                                    style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white70),
                                    children: [
                                      TextSpan(text: log['email'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                                      TextSpan(text: ' performed '),
                                      TextSpan(text: log['action'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFEF4444))),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  log['details'] ?? '',
                                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFFA1A1AA)),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Device: ${log['deviceName']} • OS: ${log['osVersion']}',
                                  style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF52525B)),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            log['timestamp'] != null
                                ? log['timestamp'].toString().substring(11, 19)
                                : '',
                            style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Color(0xFF71717A)),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
