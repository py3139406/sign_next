import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SecurityGuardWidget extends StatefulWidget {
  const SecurityGuardWidget({super.key});

  @override
  State<SecurityGuardWidget> createState() => _SecurityGuardWidgetState();
}

class _SecurityGuardWidgetState extends State<SecurityGuardWidget> {
  final _packageIdController = TextEditingController(text: 'com.businessnext.crmnext');
  final _androidHashController = TextEditingController(text: 'DE:AD:BE:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78');
  final _iosTeamIdController = TextEditingController(text: 'ABC123XYZ9');
  
  String _activePlatform = 'android';

  @override
  void dispose() {
    _packageIdController.dispose();
    _androidHashController.dispose();
    _iosTeamIdController.dispose();
    super.dispose();
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $label script to clipboard!'),
        backgroundColor: const Color(0xFF10B981),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildIntroCard(),
          const SizedBox(height: 20),
          _buildConfigurationPanel(),
          const SizedBox(height: 20),
          _buildCodeGeneratorSection(),
        ],
      ),
    );
  }

  Widget _buildIntroCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEF4444).withAlpha(76)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, color: Color(0xFFEF4444), size: 36),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The Re-Signing Threat & Security Solution',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 8),
                const Text(
                  'If an attacker downloads your signed or unsigned APK/IPA, they can inject malicious code, strip your digital signature, and re-sign the bundle using their own developer certificate. They can then side-load it or upload it to unofficial stores.',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: Color(0xFFA1A1AA), height: 1.4),
                ),
                const SizedBox(height: 8),
                Text(
                  'To prevent this, implement Runtime Signature Verification. Your application will check its own signing certificate fingerprint or team ID on startup, comparing it to your expected hardcoded hash. If a mismatch is detected, the app immediately exits.',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 13, color: const Color(0xFF10B981).withAlpha(230), height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigurationPanel() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F11),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '1. Configure App Credentials',
            style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Package ID Field
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('App Package ID / Bundle Identifier', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA))),
                    const SizedBox(height: 6),
                    Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E22),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF27272A)),
                      ),
                      child: TextField(
                        controller: _packageIdController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Android Signature SHA-256
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Expected Android Certificate SHA-256 Fingerprint', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA))),
                    const SizedBox(height: 6),
                    Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E22),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF27272A)),
                      ),
                      child: TextField(
                        controller: _androidHashController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Colors.white),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // iOS Team ID
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Expected iOS Developer Team ID', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: Color(0xFFA1A1AA))),
                    const SizedBox(height: 6),
                    Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E22),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF27272A)),
                      ),
                      child: TextField(
                        controller: _iosTeamIdController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.white),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCodeGeneratorSection() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F11),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Navigation Tab
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF1E1E22),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.code_rounded, color: Color(0xFF8B5CF6), size: 18),
                const SizedBox(width: 8),
                const Text(
                  '2. Generated Native Shield Code',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Spacer(),
                _buildPlatformTabBtn('Android (Kotlin)', 'android'),
                _buildPlatformTabBtn('iOS (Swift)', 'ios'),
                _buildPlatformTabBtn('Flutter Bridge (Dart)', 'dart'),
              ],
            ),
          ),
          // Code Display Area
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _getPlatformFilename(),
                      style: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 16, color: Color(0xFF71717A)),
                      tooltip: 'Copy Shield Script',
                      constraints: const BoxConstraints(),
                      padding: EdgeInsets.zero,
                      onPressed: () => _copyToClipboard(_getPlatformCode(), _getPlatformFilename()),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: SelectableText(
                    _getPlatformCode(),
                    style: const TextStyle(
                      fontFamily: 'Courier',
                      fontSize: 11,
                      color: Color(0xFFA7F3D0),
                      height: 1.4,
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

  Widget _buildPlatformTabBtn(String label, String platform) {
    final active = _activePlatform == platform;
    return Container(
      margin: const EdgeInsets.only(left: 8),
      child: InkWell(
        onTap: () => setState(() => _activePlatform = platform),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF8B5CF6) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? Colors.transparent : const Color(0xFF27272A)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? Colors.white : const Color(0xFFA1A1AA),
            ),
          ),
        ),
      ),
    );
  }

  String _getPlatformFilename() {
    switch (_activePlatform) {
      case 'android':
        return 'SignatureVerifier.kt';
      case 'ios':
        return 'AppIntegrityVerifier.swift';
      case 'dart':
        return 'integrity_channel.dart';
      default:
        return '';
    }
  }

  String _getPlatformCode() {
    final packageId = _packageIdController.text.trim();
    final androidHash = _androidHashController.text.trim().toUpperCase();
    final iosTeamId = _iosTeamIdController.text.trim();

    switch (_activePlatform) {
      case 'android':
        return '''package $packageId

import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import java.security.MessageDigest
import kotlin.system.exitProcess

object SignatureVerifier {
    // The expected SHA-256 fingerprint of your official certificate
    private const val EXPECTED_SHA256 = "$androidHash"

    fun verifySignature(context: Context) {
        try {
            val pm = context.packageManager
            val packageName = context.packageName
            val signatures: Array<Signature>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val packageInfo = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                packageInfo.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                val packageInfo = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                packageInfo.signatures
            }

            if (signatures == null || signatures.isEmpty()) {
                exitProcess(0) // Terminate if signature collection is empty
            }

            for (sig in signatures) {
                val sha256 = getSHA256(sig)
                if (sha256 == EXPECTED_SHA256) {
                    return // Official signature matched, execute application normally!
                }
            }
            
            // Signature mismatch: Tampering detected!
            exitProcess(0)
        } catch (e: Exception) {
            exitProcess(0) // Default to termination on exception
        }
    }

    private fun getSHA256(sig: Signature): String {
        val md = MessageDigest.getInstance("SHA-256")
        val digest = md.digest(sig.toByteArray())
        return digest.joinToString(":") { String.format("%02X", it) }
    }
}''';
      case 'ios':
        return '''import Foundation

struct AppIntegrityVerifier {
    static let expectedTeamID = "$iosTeamId"
    static let expectedBundleID = "$packageId"

    static func verifyAppSignature() -> Bool {
        // Locate provisioning profile embedded during codesigning
        guard let profilePath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            // Provisioning profile missing (typical of altered app configurations or simulator)
            #if targetEnvironment(simulator)
            return true
            #else
            return false
            #endif
        }

        do {
            let profileData = try Data(contentsOf: URL(fileURLWithPath: profilePath))
            guard let profileString = String(data: profileData, encoding: .ascii) else { return false }
            
            // Extract the embedded plist XML payload from PKCS#7 container
            guard let plistStart = profileString.range(of: "<plist"),
                  let plistEnd = profileString.range(of: "</plist>") else {
                return false
            }
            
            let plistString = String(profileString[plistStart.lowerBound...plistEnd.upperBound])
            guard let plistData = plistString.data(using: .utf8) else { return false }
            
            // Deserialize plist keys
            if let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                
                // Validate Application Identifier Prefix (TeamID.BundleID)
                if let entitlements = plist["Entitlements"] as? [String: Any],
                   let appId = entitlements["application-identifier"] as? String {
                    let expectedAppIDPrefix = "\\(expectedTeamID).\\(expectedBundleID)"
                    if appId != expectedAppIDPrefix {
                        return false // App ID mismatch!
                    }
                }
                
                // Validate Team ID
                if let teamIDs = plist["TeamIdentifier"] as? [String],
                   !teamIDs.contains(expectedTeamID) {
                    return false // Team ID mismatch!
                }
            }
            return true
        } catch {
            return false
        }
    }
    
    static func enforceIntegrity() {
        if !verifyAppSignature() {
            // Tamper detected! Exit application immediately
            exit(0)
        }
    }
}''';
      case 'dart':
        return '''import 'package:flutter/services.dart';

class IntegrityChecker {
  static const MethodChannel _channel = MethodChannel('com.businessnext.sign/integrity');

  /// Invokes native methods to verify that the app signature hasn't been tampered.
  /// Call this method in main() before runApp() or inside the init of your primary screen.
  static Future<void> checkAppIntegrity() async {
    try {
      await _channel.invokeMethod('verifySignature');
    } on PlatformException catch (e) {
      // If native side exits on validation error, execution will not reach here.
      // If method fails, treat as potential tamper/unsupported.
      print("Integrity verification check failed: \${e.message}");
    }
  }
}''';
      default:
        return '';
    }
  }
}
