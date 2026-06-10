import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/push_service.dart';
import 'services/vault_service.dart';

class PushNotificationWidget extends StatefulWidget {
  final List<SigningProfile> profiles;
  final VaultService vaultService;

  const PushNotificationWidget({
    super.key,
    required this.profiles,
    required this.vaultService,
  });

  @override
  State<PushNotificationWidget> createState() => _PushNotificationWidgetState();
}

class _PushNotificationWidgetState extends State<PushNotificationWidget> with SingleTickerProviderStateMixin {
  late TabController _platformTabController;
  
  // Shared Preferences Key Names
  static const String _prefApnsSandbox = "push_apns_sandbox";
  static const String _prefApnsUseToken = "push_apns_use_token";
  static const String _prefApnsP8Path = "push_apns_p8_path";
  static const String _prefApnsKeyId = "push_apns_key_id";
  static const String _prefApnsTeamId = "push_apns_team_id";
  static const String _prefApnsBundleId = "push_apns_bundle_id";
  static const String _prefApnsCertPath = "push_apns_cert_path";
  static const String _prefApnsDeviceToken = "push_apns_device_token";
  
  static const String _prefFcmIsV1 = "push_fcm_is_v1";
  static const String _prefFcmSaPath = "push_fcm_sa_path";
  static const String _prefFcmServerKey = "push_fcm_server_key";
  static const String _prefFcmToken = "push_fcm_token";

  // APNs controllers & state
  bool _apnsIsSandbox = true;
  bool _apnsUseToken = true;
  final _apnsP8PathController = TextEditingController();
  final _apnsKeyIdController = TextEditingController();
  final _apnsTeamIdController = TextEditingController();
  final _apnsBundleIdController = TextEditingController();
  final _apnsCertPathController = TextEditingController();
  final _apnsCertPasswordController = TextEditingController();
  final _apnsDeviceTokenController = TextEditingController();
  String _p8Content = "";

  // FCM controllers & state
  bool _fcmIsV1 = true;
  final _fcmSaPathController = TextEditingController();
  final _fcmServerKeyController = TextEditingController();
  final _fcmTokenController = TextEditingController();
  String _serviceAccountJson = "";

  // Payload controllers & state
  final _payloadTitleController = TextEditingController();
  final _payloadBodyController = TextEditingController();
  bool _payloadSound = true;
  final _payloadBadgeController = TextEditingController();
  final _payloadCustomJsonController = TextEditingController();
  bool _isCustomJsonValid = true;

  // Layout & Console State
  double _splitRatio = 0.55;
  bool _isSending = false;
  PushResult? _lastResult;

  // Profile Vault integration
  List<SigningProfile> _vaultProfiles = [];
  List<SigningProfile> _androidVaultProfiles = [];
  SigningProfile? _selectedProfile;
  SigningProfile? _selectedAndroidProfile;

  @override
  void initState() {
    super.initState();
    _platformTabController = TabController(length: 2, vsync: this);
    
    // Default Payload values
    _payloadTitleController.text = "Hello from SignNext!";
    _payloadBodyController.text = "This is a test push notification.";
    _payloadBadgeController.text = "1";
    _payloadCustomJsonController.text = '{\n  "click_action": "FLUTTER_NOTIFICATION_CLICK"\n}';

    _payloadCustomJsonController.addListener(_validateCustomJson);
    _loadSavedCredentials();
    _loadVaultProfiles();
  }

  @override
  void didUpdateWidget(covariant PushNotificationWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profiles != widget.profiles) {
      _loadVaultProfiles();
    }
  }

  @override
  void dispose() {
    _platformTabController.dispose();
    _apnsP8PathController.dispose();
    _apnsKeyIdController.dispose();
    _apnsTeamIdController.dispose();
    _apnsBundleIdController.dispose();
    _apnsCertPathController.dispose();
    _apnsCertPasswordController.dispose();
    _apnsDeviceTokenController.dispose();
    _fcmSaPathController.dispose();
    _fcmServerKeyController.dispose();
    _fcmTokenController.dispose();
    _payloadTitleController.dispose();
    _payloadBodyController.dispose();
    _payloadBadgeController.dispose();
    _payloadCustomJsonController.dispose();
    super.dispose();
  }

  void _validateCustomJson() {
    final text = _payloadCustomJsonController.text.trim();
    if (text.isEmpty) {
      setState(() => _isCustomJsonValid = true);
      return;
    }
    try {
      json.decode(text);
      if (!_isCustomJsonValid) {
        setState(() => _isCustomJsonValid = true);
      }
    } catch (_) {
      if (_isCustomJsonValid) {
        setState(() => _isCustomJsonValid = false);
      }
    }
  }

  void _loadVaultProfiles() {
    setState(() {
      _vaultProfiles = widget.profiles.where((p) => p.platform == 'ios').toList();
      _androidVaultProfiles = widget.profiles.where((p) => p.platform == 'android').toList();
    });
  }

  Widget _buildVaultProfileDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Import from Profile Vault",
          style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F11),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF27272A)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<SigningProfile?>(
              value: _selectedProfile,
              dropdownColor: const Color(0xFF1E1E22),
              isExpanded: true,
              style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white),
              hint: const Text(
                "Manual Configuration / No Vault",
                style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF52525B)),
              ),
              items: [
                const DropdownMenuItem<SigningProfile?>(
                  value: null,
                  child: Text("Manual Configuration / No Vault", style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF71717A))),
                ),
                ..._vaultProfiles.map((p) {
                  return DropdownMenuItem<SigningProfile?>(
                    value: p,
                    child: Text(p.name, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white)),
                  );
                }),
              ],
              onChanged: (SigningProfile? profile) {
                setState(() {
                  _selectedProfile = profile;
                  if (profile != null) {
                    _apnsUseToken = false; // Certificate Authentication
                    _apnsCertPathController.text = profile.p12Path;
                    _apnsCertPasswordController.text = profile.p12Password;
                    _apnsBundleIdController.text = profile.bundleId;
                  }
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFcmVaultProfileDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Import from Profile Vault",
          style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F11),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF27272A)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<SigningProfile?>(
              value: _selectedAndroidProfile,
              dropdownColor: const Color(0xFF1E1E22),
              isExpanded: true,
              style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white),
              hint: const Text(
                "Manual Configuration / No Vault",
                style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF52525B)),
              ),
              items: [
                const DropdownMenuItem<SigningProfile?>(
                  value: null,
                  child: Text("Manual Configuration / No Vault", style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF71717A))),
                ),
                ..._androidVaultProfiles.map((p) {
                  return DropdownMenuItem<SigningProfile?>(
                    value: p,
                    child: Text(p.name, style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white)),
                  );
                }),
              ],
              onChanged: (SigningProfile? profile) async {
                setState(() {
                  _selectedAndroidProfile = profile;
                  if (profile != null) {
                    _fcmServerKeyController.text = profile.fcmServerKey;
                    _fcmSaPathController.text = profile.fcmServiceAccountPath;
                    if (profile.fcmServiceAccountPath.isNotEmpty) {
                      _fcmIsV1 = true;
                    } else if (profile.fcmServerKey.isNotEmpty) {
                      _fcmIsV1 = false;
                    }
                  }
                });
                if (profile != null && profile.fcmServiceAccountPath.isNotEmpty) {
                  try {
                    final file = File(profile.fcmServiceAccountPath);
                    if (await file.exists()) {
                      final content = await file.readAsString();
                      setState(() {
                        _serviceAccountJson = content;
                      });
                    } else {
                      setState(() {
                        _serviceAccountJson = '';
                      });
                    }
                  } catch (e) {
                    _showSnack("Error loading Service Account JSON: $e", Colors.red);
                  }
                } else {
                  setState(() {
                    _serviceAccountJson = '';
                  });
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apnsIsSandbox = prefs.getBool(_prefApnsSandbox) ?? true;
      _apnsUseToken = prefs.getBool(_prefApnsUseToken) ?? true;
      _apnsP8PathController.text = prefs.getString(_prefApnsP8Path) ?? "";
      _apnsKeyIdController.text = prefs.getString(_prefApnsKeyId) ?? "";
      _apnsTeamIdController.text = prefs.getString(_prefApnsTeamId) ?? "";
      _apnsBundleIdController.text = prefs.getString(_prefApnsBundleId) ?? "";
      _apnsCertPathController.text = prefs.getString(_prefApnsCertPath) ?? "";
      _apnsDeviceTokenController.text = prefs.getString(_prefApnsDeviceToken) ?? "";

      _fcmIsV1 = prefs.getBool(_prefFcmIsV1) ?? true;
      _fcmSaPathController.text = prefs.getString(_prefFcmSaPath) ?? "";
      _fcmServerKeyController.text = prefs.getString(_prefFcmServerKey) ?? "";
      _fcmTokenController.text = prefs.getString(_prefFcmToken) ?? "";
    });

    // Attempt to load file contents from paths if they exist
    if (_apnsP8PathController.text.isNotEmpty) {
      final f = File(_apnsP8PathController.text);
      if (await f.exists()) {
        _p8Content = await f.readAsString();
      }
    }
    if (_fcmSaPathController.text.isNotEmpty) {
      final f = File(_fcmSaPathController.text);
      if (await f.exists()) {
        _serviceAccountJson = await f.readAsString();
      }
    }
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefApnsSandbox, _apnsIsSandbox);
    await prefs.setBool(_prefApnsUseToken, _apnsUseToken);
    await prefs.setString(_prefApnsP8Path, _apnsP8PathController.text);
    await prefs.setString(_prefApnsKeyId, _apnsKeyIdController.text);
    await prefs.setString(_prefApnsTeamId, _apnsTeamIdController.text);
    await prefs.setString(_prefApnsBundleId, _apnsBundleIdController.text);
    await prefs.setString(_prefApnsCertPath, _apnsCertPathController.text);
    await prefs.setString(_prefApnsDeviceToken, _apnsDeviceTokenController.text);

    await prefs.setBool(_prefFcmIsV1, _fcmIsV1);
    await prefs.setString(_prefFcmSaPath, _fcmSaPathController.text);
    await prefs.setString(_prefFcmServerKey, _fcmServerKeyController.text);
    await prefs.setString(_prefFcmToken, _fcmTokenController.text);
  }

  Future<void> _browseFile(TextEditingController controller, String typeLabel, List<String>? extensions, Function(String) onLoaded) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: extensions != null ? FileType.custom : FileType.any,
        allowedExtensions: extensions,
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        controller.text = path;
        final content = await File(path).readAsString();
        onLoaded(content);
        await _saveCredentials();
      }
    } catch (e) {
      _showSnack("Error loading $typeLabel file: $e", Colors.red);
    }
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'Inter', fontSize: 12)),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _sendTestNotification() async {
    if (!_isCustomJsonValid) {
      _showSnack("Invalid custom data payload JSON syntax.", Colors.red);
      return;
    }

    setState(() {
      _isSending = true;
      _lastResult = null;
    });

    Map<String, dynamic> customData = {};
    if (_payloadCustomJsonController.text.trim().isNotEmpty) {
      try {
        customData = json.decode(_payloadCustomJsonController.text);
      } catch (_) {}
    }

    final badge = int.tryParse(_payloadBadgeController.text) ?? 0;

    PushResult result;

    if (_platformTabController.index == 0) {
      // APNs Flow
      final deviceToken = _apnsDeviceTokenController.text.trim().replaceAll(' ', '');
      if (deviceToken.isEmpty) {
        _showSnack("Device token is required", Colors.red);
        setState(() => _isSending = false);
        return;
      }
      if (_apnsUseToken && _p8Content.isEmpty) {
        _showSnack("Please select or load a valid APNs .p8 key file", Colors.red);
        setState(() => _isSending = false);
        return;
      }

      result = await PushService.sendApns(
        isSandbox: _apnsIsSandbox,
        useToken: _apnsUseToken,
        p8Content: _apnsUseToken ? _p8Content : null,
        keyId: _apnsUseToken ? _apnsKeyIdController.text.trim() : null,
        teamId: _apnsUseToken ? _apnsTeamIdController.text.trim() : null,
        certPath: !_apnsUseToken ? _apnsCertPathController.text.trim() : null,
        certPassword: !_apnsUseToken ? _apnsCertPasswordController.text : null,
        bundleId: _apnsBundleIdController.text.trim(),
        deviceToken: deviceToken,
        title: _payloadTitleController.text,
        body: _payloadBodyController.text,
        sound: _payloadSound,
        badge: badge,
        customData: customData,
      );
    } else {
      // FCM Flow
      final fcmToken = _fcmTokenController.text.trim();
      if (fcmToken.isEmpty) {
        _showSnack("FCM registration token is required", Colors.red);
        setState(() => _isSending = false);
        return;
      }
      if (_fcmIsV1 && _serviceAccountJson.isEmpty) {
        _showSnack("Please select or load a Firebase Service Account JSON file", Colors.red);
        setState(() => _isSending = false);
        return;
      }

      result = await PushService.sendFcm(
        isV1: _fcmIsV1,
        serviceAccountJson: _fcmIsV1 ? _serviceAccountJson : null,
        serverKey: !_fcmIsV1 ? _fcmServerKeyController.text.trim() : null,
        registrationToken: fcmToken,
        title: _payloadTitleController.text,
        body: _payloadBodyController.text,
        sound: _payloadSound,
        badge: badge,
        customData: customData,
      );
    }

    setState(() {
      _lastResult = result;
      _isSending = false;
    });

    await _saveCredentials();

    if (result.success) {
      _showSnack("Notification sent successfully!", const Color(0xFF10B981));
    } else {
      _showSnack("Failed to send notification.", const Color(0xFFEF4444));
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnack("Copied $label to clipboard!", const Color(0xFF8B5CF6));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          const dividerWidth = 16.0;
          final availableWidth = totalWidth - dividerWidth;
          
          double leftWidth = (availableWidth * _splitRatio).clamp(320.0, availableWidth - 250.0);
          double rightWidth = availableWidth - leftWidth;

          return Row(
            children: [
              // Left Input Form Panel
              SizedBox(
                width: leftWidth,
                child: _buildInputsPanel(),
              ),

              // Draggable vertical divider splitter
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    double newLeftWidth = leftWidth + details.delta.dx;
                    _splitRatio = (newLeftWidth / availableWidth).clamp(0.1, 0.9);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: Container(
                    width: dividerWidth,
                    color: const Color(0xFF0F0F11),
                    child: Center(
                      child: Container(
                        width: 2,
                        height: 60,
                        decoration: BoxDecoration(
                          color: const Color(0xFF3F3F46),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Right Logs & Response Console Panel
              SizedBox(
                width: rightWidth,
                child: _buildConsolePanel(),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInputsPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tab Selector (APNs vs FCM)
        Container(
          height: 48,
          decoration: const BoxDecoration(
            color: Color(0xFF18181B),
            borderRadius: BorderRadius.only(topLeft: Radius.circular(16)),
            border: Border(bottom: BorderSide(color: Color(0xFF27272A))),
          ),
          child: TabBar(
            controller: _platformTabController,
            indicatorColor: const Color(0xFF8B5CF6),
            labelColor: Colors.white,
            unselectedLabelColor: const Color(0xFF71717A),
            labelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold),
            tabs: const [
              Tab(text: "Apple APNs (iOS)"),
              Tab(text: "Google FCM (Android)"),
            ],
          ),
        ),
        
        // Form Fields
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 440,
                  child: TabBarView(
                    controller: _platformTabController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _buildApnsForm(),
                      _buildFcmForm(),
                    ],
                  ),
                ),
                const Divider(height: 32, color: Color(0xFF27272A)),
                _buildPayloadEditor(),
                const SizedBox(height: 24),
                
                // Submit Button
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B5CF6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  onPressed: _isSending ? null : _sendTestNotification,
                  icon: _isSending
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded, size: 16),
                  label: Text(
                    _isSending ? "Sending Notification..." : "Send Test Notification",
                    style: const TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildApnsForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildVaultProfileDropdown(),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text(
              "APNs Gateway Target",
              style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F11),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Row(
                children: [
                  _buildMiniToggleBtn(
                    label: "Sandbox",
                    active: _apnsIsSandbox,
                    onTap: () => setState(() => _apnsIsSandbox = true),
                  ),
                  _buildMiniToggleBtn(
                    label: "Production",
                    active: !_apnsIsSandbox,
                    onTap: () => setState(() => _apnsIsSandbox = false),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Text(
              "Authentication Type",
              style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F11),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Row(
                children: [
                  _buildMiniToggleBtn(
                    label: "JWT Token (.p8)",
                    active: _apnsUseToken,
                    onTap: () => setState(() => _apnsUseToken = true),
                  ),
                  _buildMiniToggleBtn(
                    label: "Certificate",
                    active: !_apnsUseToken,
                    onTap: () => setState(() => _apnsUseToken = false),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_apnsUseToken) ...[
          // Token inputs
          _buildFileInputRow(
            label: "APNs .p8 Key File",
            controller: _apnsP8PathController,
            hint: "Select signing key file path...",
            extensions: ["p8"],
            onBrowse: (content) {
              _p8Content = content;
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildInputCol(
                  label: "Key ID",
                  controller: _apnsKeyIdController,
                  hint: "ABC123XYZ0",
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInputCol(
                  label: "Team ID",
                  controller: _apnsTeamIdController,
                  hint: "Apple Team ID",
                ),
              ),
            ],
          ),
        ] else ...[
          // Certificate inputs
          _buildFileInputRow(
            label: "APNs .pem / .p12 Certificate",
            controller: _apnsCertPathController,
            hint: "Select push certificate path...",
            extensions: ["pem", "p12"],
            onBrowse: (_) {},
          ),
          const SizedBox(height: 10),
          _buildInputCol(
            label: "Certificate Password (Optional)",
            controller: _apnsCertPasswordController,
            hint: "Leave empty if certificate has no password",
            obscureText: true,
          ),
        ],
        const SizedBox(height: 10),
        _buildInputCol(
          label: "App Bundle ID",
          controller: _apnsBundleIdController,
          hint: "com.example.app",
        ),
        const SizedBox(height: 10),
        _buildInputCol(
          label: "Device Token (Hex)",
          controller: _apnsDeviceTokenController,
          hint: "Enter physical iOS device push token (64 hex characters)...",
        ),
      ],
    );
  }

  Widget _buildFcmForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFcmVaultProfileDropdown(),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text(
              "FCM Protocol Version",
              style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F11),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF27272A)),
              ),
              child: Row(
                children: [
                  _buildMiniToggleBtn(
                    label: "HTTP v1 (Modern)",
                    active: _fcmIsV1,
                    onTap: () => setState(() => _fcmIsV1 = true),
                  ),
                  _buildMiniToggleBtn(
                    label: "Legacy",
                    active: !_fcmIsV1,
                    onTap: () => setState(() => _fcmIsV1 = false),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_fcmIsV1) ...[
          // FCM HTTP v1 Service Account JSON
          _buildFileInputRow(
            label: "Google Service Account JSON File",
            controller: _fcmSaPathController,
            hint: "Upload service account credential key JSON file...",
            extensions: ["json"],
            onBrowse: (content) {
              _serviceAccountJson = content;
            },
          ),
        ] else ...[
          // FCM Legacy Key input
          _buildInputCol(
            label: "FCM Server Key (Legacy)",
            controller: _fcmServerKeyController,
            hint: "Enter your Firebase cloud messaging legacy server key...",
          ),
        ],
        const SizedBox(height: 10),
        _buildInputCol(
          label: "FCM Device Token (Registration Token)",
          controller: _fcmTokenController,
          hint: "Paste target FCM device registration token...",
        ),
      ],
    );
  }

  Widget _buildPayloadEditor() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F11),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.edit_note_rounded, color: Color(0xFF8B5CF6), size: 16),
              SizedBox(width: 8),
              Text(
                "Push Payload Customization",
                style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildInputCol(
            label: "Notification Title",
            controller: _payloadTitleController,
            hint: "Title string...",
          ),
          const SizedBox(height: 10),
          _buildInputCol(
            label: "Notification Body Message",
            controller: _payloadBodyController,
            hint: "Body message string...",
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Row(
                    children: [
                      const Text(
                        "Sound Alert",
                        style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70),
                      ),
                      const Spacer(),
                      Switch(
                        value: _payloadSound,
                        activeColor: const Color(0xFF8B5CF6),
                        onChanged: (val) => setState(() => _payloadSound = val),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInputCol(
                  label: "Badge Count",
                  controller: _payloadBadgeController,
                  hint: "e.g. 1",
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    "Custom Key-Value Data Payload (JSON)",
                    style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
                  ),
                  const Spacer(),
                  if (!_isCustomJsonValid)
                    const Text(
                      "Invalid JSON syntax",
                      style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFFEF4444), fontWeight: FontWeight.bold),
                    )
                  else
                    const Text(
                      "Valid JSON",
                      style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF10B981)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E22),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _isCustomJsonValid ? const Color(0xFF27272A) : const Color(0xFFEF4444)),
                ),
                child: TextField(
                  controller: _payloadCustomJsonController,
                  maxLines: 4,
                  style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.all(12),
                    border: InputBorder.none,
                    hintText: '{\n  "custom_key": "custom_value"\n}',
                    hintStyle: TextStyle(fontFamily: 'Courier', fontSize: 12, color: Color(0xFF52525B)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConsolePanel() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F11),
        borderRadius: BorderRadius.only(topRight: Radius.circular(16), bottomRight: Radius.circular(16)),
        border: Border(left: BorderSide(color: Color(0xFF27272A))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Console Header
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: Color(0xFF18181B),
              border: Border(bottom: BorderSide(color: Color(0xFF27272A))),
              borderRadius: BorderRadius.only(topRight: Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal_rounded, size: 16, color: Color(0xFF8B5CF6)),
                const SizedBox(width: 8),
                const Text(
                  "Developer Console Logs & Response",
                  style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Spacer(),
                if (_lastResult != null) ...[
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 16, color: Color(0xFFA1A1AA)),
                    tooltip: "Copy Server Response",
                    onPressed: () => _copyToClipboard(_lastResult!.responseBody, "Response Body"),
                  ),
                ],
              ],
            ),
          ),

          // Console output
          Expanded(
            child: _lastResult == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.portable_wifi_off_rounded, size: 40, color: Color(0xFF3F3F46)),
                        const SizedBox(height: 12),
                        const Text(
                          "No transactions logged yet",
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF71717A)),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "Configure inputs and trigger a notification to see request logs",
                          style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: Color(0xFF52525B)),
                        ),
                      ],
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Result Status Box
                        _buildStatusHeader(),
                        const SizedBox(height: 12),

                        // Troubleshooting tips if transaction failed
                        if (!_lastResult!.success) ...[
                          _buildTroubleshootingTips(),
                          const SizedBox(height: 8),
                        ],

                        // Request curl
                        const Text(
                          "Generated Request Payload (curl equivalent)",
                          style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
                        ),
                        const SizedBox(height: 8),
                        _buildCodeSnippetBox(_lastResult!.requestLog, "curl command"),
                        const SizedBox(height: 20),

                        // Server Response Headers / Body
                        const Text(
                          "Server Response Output",
                          style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
                        ),
                        const SizedBox(height: 8),
                        _buildCodeSnippetBox(_lastResult!.responseBody, "response output"),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTroubleshootingTips() {
    final response = _lastResult!.responseBody;
    String title = "Troubleshooting Diagnosis";
    String message = "";
    bool matched = false;

    if (response.contains("unknown ca") || response.contains("unknown_ca")) {
      matched = true;
      message = "Apple APNs server rejected the SSL handshake with an 'unknown ca' (Unknown Certificate Authority) alert.\n\n"
          "This typically indicates a mismatch between the gateway target and your certificate type:\n"
          "1. Environment Mismatch: You might be connecting to the Sandbox gateway using a Production-only certificate (or vice-versa).\n"
          "   -> Try toggling the APNs Gateway Target to 'Production'.\n"
          "2. Bundle ID Mismatch: The App Bundle ID entered might not match the Bundle ID embedded inside the certificate.\n"
          "3. Expired Certificate: The push certificate (.p12) may have expired or is revoked.";
    } else if (response.contains("BadDeviceToken")) {
      matched = true;
      message = "Apple returned a 'BadDeviceToken' error.\n\n"
          "This indicates that the iOS Device Token is invalid, formatted incorrectly, or has expired.\n"
          "Make sure you copy the device token from a physical iOS device running the correct build variant (Sandbox tokens will only work on Sandbox gateway).";
    } else if (response.contains("TopicDisallowed")) {
      matched = true;
      message = "Apple returned a 'TopicDisallowed' error.\n\n"
          "This indicates the App Bundle ID (apns-topic) is not associated with this push certificate/token.\n"
          "Double check your App Bundle ID spelling.";
    } else if (response.contains("InvalidRegistration") || response.contains("messaging/invalid-argument")) {
      matched = true;
      message = "Firebase returned an 'Invalid Registration' / 'invalid-argument' token error.\n\n"
          "The FCM registration token is invalid, incorrectly formatted, or belongs to a different Firebase project.";
    } else if (response.contains("messaging/authentication-error") || response.contains("401")) {
      matched = true;
      message = "Authentication failure.\n\n"
          "For FCM HTTP v1: The Service Account JSON configuration is invalid, lacks FCM permissions, or the system time is out of sync (preventing OAuth2 signature token creation).\n"
          "For APNs: Double check your Key ID, Team ID, or certificate password.";
    }

    if (!matched) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x15F59E0B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline_rounded, color: Color(0xFFF59E0B), size: 16),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFF59E0B)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusHeader() {
    final success = _lastResult!.success;
    final code = _lastResult!.statusCode;
    
    Color bg = success ? const Color(0x1510B981) : const Color(0x15EF4444);
    Color border = success ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    IconData icon = success ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded;
    String label = success ? "TRANSACTION SUCCESSFUL" : "TRANSACTION FAILED";
    String details = code == -1 ? "Curl execution error" : "HTTP Status Code: $code";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: border, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: border),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeSnippetBox(String content, String label) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF09090B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF18181B),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8)),
            ),
            child: Row(
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF71717A)),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => _copyToClipboard(content, label),
                  child: const Row(
                    children: [
                      Icon(Icons.copy_rounded, size: 10, color: Color(0xFF8B5CF6)),
                      SizedBox(width: 4),
                      Text("COPY", style: TextStyle(fontFamily: 'Inter', fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF8B5CF6))),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              content,
              style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Colors.white, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniToggleBtn({required String label, required bool active, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF27272A) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 10,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? Colors.white : const Color(0xFF71717A),
          ),
        ),
      ),
    );
  }

  Widget _buildInputCol({
    required String label,
    required TextEditingController controller,
    required String hint,
    bool obscureText = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Container(
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F11),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF27272A)),
          ),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF52525B)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: InputBorder.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFileInputRow({
    required String label,
    required TextEditingController controller,
    required String hint,
    required List<String> extensions,
    required Function(String) onBrowse,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F0F11),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF27272A)),
                ),
                child: TextField(
                  controller: controller,
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Color(0xFF52525B)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF27272A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                onPressed: () => _browseFile(controller, label, extensions, onBrowse),
                child: const Text(
                  "Browse",
                  style: TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
