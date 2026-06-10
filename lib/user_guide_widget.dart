import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class UserGuideWidget extends StatefulWidget {
  const UserGuideWidget({super.key});

  @override
  State<UserGuideWidget> createState() => _UserGuideWidgetState();
}

class _UserGuideWidgetState extends State<UserGuideWidget> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $label command to clipboard!'),
        backgroundColor: const Color(0xFF10B981),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27272A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TabBar(
            controller: _tabController,
            indicatorColor: const Color(0xFF8B5CF6),
            labelColor: Colors.white,
            unselectedLabelColor: const Color(0xFF71717A),
            tabs: const [
              Tab(
                icon: Icon(Icons.android, size: 20),
                text: 'Android signing (.jks / .keystore)',
              ),
              Tab(
                icon: Icon(Icons.apple, size: 20),
                text: 'iOS signing (.p12 / provisioning)',
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildAndroidGuide(),
                _buildIosGuide(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidGuide() {
    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        _buildSectionHeader('Android Codesigning Overview', Icons.info_outline),
        _buildInfoText(
          'Android apps must be signed before installation on physical devices. '
          'Signing uses a public-key certificate that identifies the developer of the application. '
          'The signing process involves generating a Keystore, aligning the APK, and signing the APK.',
        ),
        const SizedBox(height: 24),
        _buildCard(
          title: '1. Keystore Files (.jks or .keystore)',
          description: 'A Keystore is a binary file containing one or more private keys. '
              'The private key in this keystore is used to digitally sign your app. '
              'Keep this keystore file extremely secure: if you lose it, you will not be able to publish updates to your app.',
          details: [
            'Keystore Path: Location where the keystore file is saved.',
            'Key Alias: A name assigned to the private key entry inside the keystore.',
            'Store Password: Password used to protect the entire keystore.',
            'Key Password: Password used to protect the specific private key alias.',
          ],
          commandTitle: 'Generate Keystore Command',
          commandText: 'keytool -genkey -v -keystore my-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias my-key-alias',
        ),
        const SizedBox(height: 20),
        _buildCard(
          title: '2. ZipAlign Alignment Tool',
          description: 'zipalign is an archive alignment tool that ensures all uncompressed data starts '
              'with a particular alignment relative to the start of the file. '
              'Aligning files reduces the amount of RAM consumed when running the app.',
          details: [
            'Alignment must be done BEFORE signing with apksigner.',
            'The aligner lines up zip entries on 4-byte boundaries.',
          ],
          commandTitle: 'Align APK Command',
          commandText: 'zipalign -v -p 4 input-unsigned.apk output-aligned.apk',
        ),
        const SizedBox(height: 20),
        _buildCard(
          title: '3. ApkSigner Tool',
          description: 'apksigner signs your APK with a keystore key and ensures that the signature '
              'is verified successfully on all versions of Android that the APK supports. '
              'It operates on the aligned APK file.',
          details: [
            'Supports v1 (JAR signature), v2 (APK Signature Scheme v2), v3, and v4 signing.',
            'Generates signatures that verify the integrity of the archive blocks.',
          ],
          commandTitle: 'Sign APK Command',
          commandText: 'java -jar apksigner.jar sign --ks my-release-key.jks --ks-key-alias my-key-alias --ks-pass pass:MyStorePassword --key-pass pass:MyKeyPassword --out signed-aligned.apk output-aligned.apk',
        ),
        const SizedBox(height: 20),
        _buildCard(
          title: '4. Verify Android Signature',
          description: 'Always verify that your APK signature is correct and valid.',
          details: [
            'Verifies signature schemes v1, v2, v3, and v4.',
          ],
          commandTitle: 'Verify APK Command',
          commandText: 'java -jar apksigner.jar verify --verbose signed-aligned.apk',
        ),
      ],
    );
  }

  Widget _buildIosGuide() {
    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        _buildSectionHeader('iOS Codesigning Overview', Icons.info_outline),
        _buildInfoText(
          'iOS apps require codesigning and provisioning to run on physical iOS devices or be distributed '
          'via TestFlight and the App Store. Codesigning cryptographically seals the app bundle with your developer certificate, '
          'while the Provisioning Profile lists which Apple devices are allowed to run your app.',
        ),
        const SizedBox(height: 24),
        _buildCard(
          title: '1. P12 Certificate (.p12)',
          description: 'A Personal Information Exchange (.p12) file contains your iOS Codesigning Certificate '
              'along with its matching private key. This certificate is issued by Apple via the Developer Portal.',
          details: [
            'P12 contains both public and private keys, allowing you to sign on any Mac machine.',
            'To export a P12: Open Keychain Access on Mac -> Certificates -> Expand your Developer Certificate -> Select both private key and certificate -> Right-click -> Export as Personal Information (.p12).',
            'Certificate password is required during import.',
          ],
          commandTitle: 'Import P12 into macOS Keychain via CLI',
          commandText: 'security import my-developer-cert.p12 -k ~/Library/Keychains/login.keychain-db -P my-p12-password -T /usr/bin/codesign',
        ),
        const SizedBox(height: 20),
        _buildCard(
          title: '2. Provisioning Profile (.mobileprovision)',
          description: 'A Provisioning Profile is a file downloaded from Apple Developer Portal. It is packaged inside '
              'your app bundle (renamed to embedded.mobileprovision) and read by iOS at launch to check permissions.',
          details: [
            'App ID & Bundle ID: Must match the bundle identifier in your app\'s Info.plist.',
            'Entitlements: Lists capabilities like Push Notifications, iCloud, Keychain sharing, etc.',
            'Provisioned Devices (UDID): A whitelist of physical device identifiers for development/ad-hoc builds.',
            'Certificates: The certificate used to sign the app must be contained in the provisioning profile.',
          ],
          commandTitle: 'Extract Profile Entitlements',
          commandText: 'security cms -D -i embedded.mobileprovision > profile.plist\n/usr/libexec/PlistBuddy -x -c "Print:Entitlements" profile.plist > entitlements.plist',
        ),
        const SizedBox(height: 20),
        _buildCard(
          title: '3. Codesign Signing Utility',
          description: 'The `codesign` tool on macOS seals components inside the app bundle including '
              'frameworks, extensions, dylibs, and the main executable.',
          details: [
            'Sign all frameworks inside Payload/AppName.app/Frameworks/ first.',
            'Sign any app extensions in Payload/AppName.app/PlugIns/ next.',
            'Finally, sign the main app bundle utilizing your extracted entitlements.',
          ],
          commandTitle: 'Manual Sign Commands',
          commandText: '# Sign frameworks\n'
              'codesign -f -s "Apple Development: Developer Name (ID)" --timestamp=none Payload/AppName.app/Frameworks/MyFramework.framework\n\n'
              '# Sign App Bundle\n'
              'codesign -f -s "Apple Development: Developer Name (ID)" --entitlements entitlements.plist --timestamp=none Payload/AppName.app',
        ),
        const SizedBox(height: 20),
        _buildCard(
          title: '4. Verify and Repackage IPA',
          description: 'Verify codesign integrity using macOS tools, and zip the Payload folder to create the .ipa archive.',
          details: [
            'Codesign verification ensures that components are not tampered with and match the certificate.',
          ],
          commandTitle: 'Verify and Zip Commands',
          commandText: '# Verify signature\n'
              'codesign --verify --deep --verbose=2 Payload/AppName.app\n\n'
              '# Repackage unsigned or resigned app\n'
              'zip -qr my-signed-app.ipa Payload',
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF8B5CF6), size: 24),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoText(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          color: Color(0xFFA1A1AA),
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildCard({
    required String title,
    required String description,
    required List<String> details,
    required String commandTitle,
    required String commandText,
  }) {
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
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: Color(0xFFA1A1AA),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Key Concepts:',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8B5CF6),
            ),
          ),
          const SizedBox(height: 6),
          ...details.map((detail) => Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(' • ', style: TextStyle(color: Color(0xFF8B5CF6))),
                    Expanded(
                      child: Text(
                        detail,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: Color(0xFF71717A),
                        ),
                      ),
                    ),
                  ],
                ),
              )),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF27272A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      commandTitle,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF10B981),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 14, color: Color(0xFF71717A)),
                      tooltip: 'Copy Command',
                      constraints: const BoxConstraints(),
                      padding: EdgeInsets.zero,
                      onPressed: () => _copyToClipboard(context, commandText, commandTitle),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(
                  commandText,
                  style: const TextStyle(
                    fontFamily: 'Courier',
                    fontSize: 11,
                    color: Color(0xFFA7F3D0),
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
