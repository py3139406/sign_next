import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SigningProfile {
  final String id;
  final String name;
  final String platform; // 'ios' or 'android'
  
  // iOS fields
  final String p12Path;
  final String provPath;
  final String p12Password;
  final String keychainPassword;
  final String bundleId;
  final String selectedIdentity;

  // Android fields
  final String keystorePath;
  final String keyAlias;
  final String keyPassword;
  final String storePassword;
  final String zipalignPath;
  final String apksignerJarPath;

  // FCM credentials
  final String fcmServerKey;
  final String fcmServiceAccountPath;

  SigningProfile({
    required this.id,
    required this.name,
    required this.platform,
    this.p12Path = '',
    this.provPath = '',
    this.p12Password = '',
    this.keychainPassword = '',
    this.bundleId = '',
    this.selectedIdentity = '',
    this.keystorePath = '',
    this.keyAlias = '',
    this.keyPassword = '',
    this.storePassword = '',
    this.zipalignPath = '',
    this.apksignerJarPath = '',
    this.fcmServerKey = '',
    this.fcmServiceAccountPath = '',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'p12Path': p12Path,
    'provPath': provPath,
    'p12Password': p12Password,
    'keychainPassword': keychainPassword,
    'bundleId': bundleId,
    'selectedIdentity': selectedIdentity,
    'keystorePath': keystorePath,
    'keyAlias': keyAlias,
    'keyPassword': keyPassword,
    'storePassword': storePassword,
    'zipalignPath': zipalignPath,
    'apksignerJarPath': apksignerJarPath,
    'fcmServerKey': fcmServerKey,
    'fcmServiceAccountPath': fcmServiceAccountPath,
  };

  factory SigningProfile.fromJson(Map<String, dynamic> json) => SigningProfile(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    platform: json['platform'] ?? 'ios',
    p12Path: json['p12Path'] ?? '',
    provPath: json['provPath'] ?? '',
    p12Password: json['p12Password'] ?? '',
    keychainPassword: json['keychainPassword'] ?? '',
    bundleId: json['bundleId'] ?? '',
    selectedIdentity: json['selectedIdentity'] ?? '',
    keystorePath: json['keystorePath'] ?? '',
    keyAlias: json['keyAlias'] ?? '',
    keyPassword: json['keyPassword'] ?? '',
    storePassword: json['storePassword'] ?? '',
    zipalignPath: json['zipalignPath'] ?? '',
    apksignerJarPath: json['apksignerJarPath'] ?? '',
    fcmServerKey: json['fcmServerKey'] ?? '',
    fcmServiceAccountPath: json['fcmServiceAccountPath'] ?? '',
  );
}

class VaultService {
  static const String _profilesKey = 'signing_profiles';
  static const String _lastUsedProfilePrefix = 'last_profile_';

  Future<List<SigningProfile>> getProfiles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_profilesKey);
      if (jsonStr == null) {
        print("VaultService: no profiles found under key '$_profilesKey'");
        return [];
      }
      
      final List<dynamic> list = json.decode(jsonStr);
      final profiles = list.map((item) => SigningProfile.fromJson(item)).toList();
      print("VaultService: successfully parsed ${profiles.length} profiles.");
      return profiles;
    } catch (e, stack) {
      print("VaultService Error loading profiles: $e\n$stack");
      return [];
    }
  }

  Future<void> saveProfiles(List<SigningProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = json.encode(profiles.map((p) => p.toJson()).toList());
    await prefs.setString(_profilesKey, jsonStr);
  }

  Future<void> addProfile(SigningProfile profile) async {
    final list = await getProfiles();
    list.removeWhere((p) => p.id == profile.id);
    list.add(profile);
    await saveProfiles(list);
  }

  Future<void> deleteProfile(String id) async {
    final list = await getProfiles();
    list.removeWhere((p) => p.id == id);
    await saveProfiles(list);
  }

  Future<String?> getLastUsedProfileId(String platform) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_lastUsedProfilePrefix$platform');
  }

  Future<void> setLastUsedProfileId(String platform, String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_lastUsedProfilePrefix$platform', id);
  }
}
