import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class SigningIdentity {
  final String fingerprint;
  final String name;

  SigningIdentity({required this.fingerprint, required this.name});

  @override
  String toString() => '$name ($fingerprint)';
}

class SigningService {
  /// Runs a system command and streams its stdout/stderr output.
  Stream<String> _runCommand(
    String command,
    List<String> args, {
    String? workingDirectory,
  }) {
    final controller = StreamController<String>();
    final printableCmd = '$command ${args.map((a) => a.contains(' ') ? '"$a"' : a).join(' ')}';
    controller.add('[EXEC] $printableCmd');

    Process.start(command, args, workingDirectory: workingDirectory, runInShell: true).then((process) {
      var stdoutDone = false;
      var stderrDone = false;

      void checkDone() async {
        if (stdoutDone && stderrDone) {
          final exitCode = await process.exitCode;
          if (exitCode != 0) {
            controller.addError(Exception('Command failed with exit code $exitCode'));
          } else {
            controller.add('[SUCCESS] Command completed successfully.');
          }
          controller.close();
        }
      }

      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) {
          if (!controller.isClosed) controller.add(line);
        },
        onDone: () {
          stdoutDone = true;
          checkDone();
        },
        onError: (err) {
          if (!controller.isClosed) controller.addError(err);
        },
      );

      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) {
          if (!controller.isClosed) controller.add('[STDERR] $line');
        },
        onDone: () {
          stderrDone = true;
          checkDone();
        },
        onError: (err) {
          if (!controller.isClosed) controller.addError(err);
        },
      );
    }).catchError((err) {
      if (!controller.isClosed) {
        controller.addError(err);
        controller.close();
      }
    });

    return controller.stream;
  }

  /// Lists iOS code signing identities on macOS.
  Future<List<SigningIdentity>> getSigningIdentities(String keychainPath) async {
    if (!Platform.isMacOS) return [];
    try {
      final result = await Process.run('security', ['find-identity', '-v', '-p', 'codesigning', keychainPath]);
      if (result.exitCode != 0) return [];

      final lines = const LineSplitter().convert(result.stdout as String);
      final List<SigningIdentity> identities = [];
      for (final line in lines) {
        // Example:   1) 8B5CF6... "Apple Development: Pavan Yadav (XXXX)"
        final match = RegExp(r'^\s*\d+\)\s+([A-F0-9]+)\s+"([^"]+)"').firstMatch(line);
        if (match != null) {
          identities.add(SigningIdentity(
            fingerprint: match.group(1)!,
            name: match.group(2)!,
          ));
        }
      }
      return identities;
    } catch (e) {
      return [];
    }
  }

  /// iOS Resigning Stream
  Stream<String> resignIpa({
    required String ipaPath,
    required String p12Path,
    required String provPath,
    required String p12Password,
    required String keychainPassword,
    required String chosenIdentity,
    String? newBundleId,
    required String outputPath,
  }) async* {
    if (!Platform.isMacOS) {
      yield '[ERROR] iOS Resigning is only supported on macOS.';
      throw Exception('iOS signing requires macOS');
    }

    final tempDir = await Directory.systemTemp.createTemp('ipa_resign_');
    yield '📁 Created temporary workspace: ${tempDir.path}';

    try {
      // 1. Import P12 into Keychain
      yield '🔐 Importing certificate into login keychain...';
      final keychain = p.join(Platform.environment['HOME']!, 'Library/Keychains/login.keychain-db');
      
      // Unlock keychain first
      yield '🔓 Unlocking login keychain...';
      await for (final log in _runCommand('security', ['unlock-keychain', '-p', keychainPassword, keychain])) {
        yield log;
      }

      yield '🔑 Importing P12 file...';
      final importArgs = [
        'import',
        p12Path,
        '-k',
        keychain,
        '-P',
        p12Password,
        '-T',
        '/usr/bin/codesign',
        '-A'
      ];
      await for (final log in _runCommand('security', importArgs)) {
        yield log;
      }

      // 2. Unzip IPA
      yield '📦 Extracting IPA file...';
      await for (final log in _runCommand('unzip', ['-q', ipaPath, '-d', tempDir.path])) {
        yield log;
      }

      final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
      if (!await payloadDir.exists()) {
        throw Exception('Payload directory not found inside IPA');
      }

      final appDir = await payloadDir
          .list()
          .firstWhere((entity) => entity is Directory && entity.path.endsWith('.app'))
          .then((entity) => entity as Directory);
      yield '🔍 Found App Bundle: ${p.basename(appDir.path)}';

      // Extract iOS App Metadata
      try {
        final infoPlistPath = p.join(appDir.path, 'Info.plist');
        final nameResult = await Process.run('/usr/libexec/PlistBuddy', ['-c', 'Print CFBundleDisplayName', infoPlistPath]);
        var appName = (nameResult.stdout as String).trim();
        if (appName.isEmpty || nameResult.exitCode != 0) {
          final nameResultFallback = await Process.run('/usr/libexec/PlistBuddy', ['-c', 'Print CFBundleName', infoPlistPath]);
          appName = (nameResultFallback.stdout as String).trim();
        }
        final idResult = await Process.run('/usr/libexec/PlistBuddy', ['-c', 'Print CFBundleIdentifier', infoPlistPath]);
        final bundleId = (idResult.stdout as String).trim();
        final verNameResult = await Process.run('/usr/libexec/PlistBuddy', ['-c', 'Print CFBundleShortVersionString', infoPlistPath]);
        final versionName = (verNameResult.stdout as String).trim();
        final verCodeResult = await Process.run('/usr/libexec/PlistBuddy', ['-c', 'Print CFBundleVersion', infoPlistPath]);
        final versionCode = (verCodeResult.stdout as String).trim();

        yield '[METADATA] ${json.encode({
          'name': appName.isNotEmpty ? appName : p.basenameWithoutExtension(ipaPath),
          'packageId': bundleId,
          'versionName': versionName,
          'versionCode': versionCode,
        })}';
      } catch (_) {}

      // 3. Optional: Modify Bundle ID
      if (newBundleId != null && newBundleId.trim().isNotEmpty) {
        yield '🔖 Updating Bundle ID in Info.plist to: $newBundleId';
        final appPlist = p.join(appDir.path, 'Info.plist');
        await for (final log in _runCommand('/usr/libexec/PlistBuddy', [
          '-c',
          'Set :CFBundleIdentifier $newBundleId',
          appPlist
        ])) {
          yield log;
        }
      }

      // 4. Replace Provisioning Profile
      yield '📄 Replacing embedded.mobileprovision...';
      final embeddedProvPath = p.join(appDir.path, 'embedded.mobileprovision');
      final embeddedFile = File(embeddedProvPath);
      if (await embeddedFile.exists()) {
        await embeddedFile.delete();
      }
      await File(provPath).copy(embeddedProvPath);

      // 5. Extract Entitlements
      yield '🛡️ Extracting entitlements from provisioning profile...';
      final profilePlist = p.join(tempDir.path, 'profile.plist');
      final entitlementsPlist = p.join(tempDir.path, 'entitlements.plist');

      await for (final log in _runCommand('security', ['cms', '-D', '-i', provPath])) {
        // Note: security cms output goes to stdout. We need to save it. We can write a custom runner or redirect in bash.
        // Let's use shell redirect since runInShell is true.
      }
      // Better: execute a small inline bash script to handle redirects securely
      final extractScript = '''
security cms -D -i "$provPath" > "$profilePlist"
/usr/libexec/PlistBuddy -x -c "Print:Entitlements" "$profilePlist" > "$entitlementsPlist"
''';
      final scriptFile = File(p.join(tempDir.path, 'extract.sh'));
      await scriptFile.writeAsString(extractScript);
      await Process.run('chmod', ['+x', scriptFile.path]);

      await for (final log in _runCommand('bash', [scriptFile.path])) {
        yield log;
      }
      yield '✅ Entitlements generated at: $entitlementsPlist';

      // 6. Sign nested Frameworks
      final frameworksDir = Directory(p.join(appDir.path, 'Frameworks'));
      if (await frameworksDir.exists()) {
        yield '🧱 Signing embedded Frameworks...';
        await for (final entity in frameworksDir.list()) {
          if (entity is Directory) {
            yield '  ↳ Signing framework: ${p.basename(entity.path)}';
            await for (final log in _runCommand('codesign', [
              '-f',
              '-s',
              chosenIdentity,
              '--timestamp=none',
              entity.path
            ])) {
              yield log;
            }
          }
        }
      }

      // 7. Sign nested PlugIns (Extensions)
      final pluginsDir = Directory(p.join(appDir.path, 'PlugIns'));
      if (await pluginsDir.exists()) {
        yield '🔌 Signing embedded App Extensions...';
        await for (final entity in pluginsDir.list()) {
          if (entity is Directory && entity.path.endsWith('.appex')) {
            yield '  ↳ Signing extension: ${p.basename(entity.path)}';
            // Extensions can contain frameworks too
            final nestedFrameworks = Directory(p.join(entity.path, 'Frameworks'));
            if (await nestedFrameworks.exists()) {
              await for (final subFramework in nestedFrameworks.list()) {
                if (subFramework is Directory) {
                  await for (final log in _runCommand('codesign', [
                    '-f',
                    '-s',
                    chosenIdentity,
                    '--timestamp=none',
                    subFramework.path
                  ])) {
                    yield log;
                  }
                }
              }
            }

            await for (final log in _runCommand('codesign', [
              '-f',
              '-s',
              chosenIdentity,
              '--entitlements',
              entitlementsPlist,
              '--timestamp=none',
              entity.path
            ])) {
              yield log;
            }
          }
        }
      }

      // 8. Sign Main App Bundle
      yield '📱 Signing the main application bundle...';
      await for (final log in _runCommand('codesign', [
        '-f',
        '-s',
        chosenIdentity,
        '--entitlements',
        entitlementsPlist,
        '--timestamp=none',
        appDir.path
      ])) {
        yield log;
      }

      // 9. Verify Signature
      yield '🔎 Verifying codesign signature...';
      await for (final log in _runCommand('codesign', [
        '--verify',
        '--deep',
        '--verbose=2',
        appDir.path
      ])) {
        yield log;
      }

      // 10. Re-package into IPA
      yield '📦 Rebuilding IPA archive...';
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      // Create output directory if it doesn't exist
      await Directory(p.dirname(outputPath)).create(recursive: true);

      // Execute zip command inside temp workspace
      await for (final log in _runCommand('zip', [
        '-qr',
        outputPath,
        'Payload'
      ], workingDirectory: tempDir.path)) {
        yield log;
      }

      yield '🎉 Resigning successful! Saved to: $outputPath';
    } catch (e) {
      yield '[ERROR] iOS Resigning failed: $e';
      rethrow;
    } finally {
      yield '🧹 Cleaning up temporary directory...';
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  /// Android APK Signing Stream
  Stream<String> signApk({
    required String apkPath,
    required String keystorePath,
    required String keyAlias,
    required String keyPassword,
    required String storePassword,
    required String zipalignPath,
    required String apksignerJarPath,
    required String outputPath,
  }) async* {
    final tempDir = await Directory.systemTemp.createTemp('apk_sign_');
    yield '📁 Created temporary workspace: ${tempDir.path}';

    try {
      final baseName = p.basenameWithoutExtension(apkPath);
      final alignedApk = p.join(tempDir.path, '$baseName-aligned.apk');

      // 1. Zipalign the APK
      yield '📦 Aligning APK via zipalign...';
      await for (final log in _runCommand(zipalignPath, [
        '-v',
        '-f',
        '-p',
        '4',
        apkPath,
        alignedApk
      ])) {
        yield log;
      }

      // 2. Sign APK via apksigner
      yield '🔐 Signing APK via apksigner.jar...';
      // Create output directory if needed
      await Directory(p.dirname(outputPath)).create(recursive: true);
      
      final signArgs = [
        '-jar',
        apksignerJarPath,
        'sign',
        '--ks',
        keystorePath,
        '--ks-key-alias',
        keyAlias,
        '--ks-pass',
        'pass:$storePassword',
        '--key-pass',
        'pass:$keyPassword',
        '--out',
        outputPath,
        alignedApk
      ];

      await for (final log in _runCommand('java', signArgs)) {
        yield log;
      }

      // 3. Verify Signature
      yield '🔎 Verifying APK signature...';
      await for (final log in _runCommand('java', [
        '-jar',
        apksignerJarPath,
        'verify',
        '--verbose',
        outputPath
      ])) {
        yield log;
      }

      yield '🎉 APK Signing successful! Saved to: $outputPath';
    } catch (e) {
      yield '[ERROR] APK Signing failed: $e';
      rethrow;
    } finally {
      yield '🧹 Cleaning up temporary directory...';
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  /// Android AAB Signing Stream
  Stream<String> signAab({
    required String aabPath,
    required String keystorePath,
    required String keyAlias,
    required String keyPassword,
    required String storePassword,
    required String outputPath,
  }) async* {
    try {
      yield '🔐 Signing App Bundle (AAB) via jarsigner...';
      
      // Copy original AAB to output path first since jarsigner signs in-place
      yield '📄 Copying AAB to output target...';
      await Directory(p.dirname(outputPath)).create(recursive: true);
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      await File(aabPath).copy(outputPath);

      final args = [
        '-verbose',
        '-sigalg',
        'SHA256withRSA',
        '-digestalg',
        'SHA-256',
        '-keystore',
        keystorePath,
        '-storepass',
        storePassword,
        '-keypass',
        keyPassword,
        outputPath,
        keyAlias
      ];

      await for (final log in _runCommand('jarsigner', args)) {
        yield log;
      }

      yield '🎉 AAB Signing successful! Saved to: $outputPath';
    } catch (e) {
      yield '[ERROR] AAB Signing failed: $e';
      rethrow;
    }
  }

  /// Unsign IPA (Removes signature & embedded.mobileprovision)
  Stream<String> unsignIpa({
    required String ipaPath,
    required String outputPath,
  }) async* {
    if (!Platform.isMacOS) {
      yield '[ERROR] iOS operations are only supported on macOS.';
      throw Exception('iOS operations require macOS');
    }

    final tempDir = await Directory.systemTemp.createTemp('ipa_unsign_');
    yield '📁 Created temporary workspace: ${tempDir.path}';

    try {
      // 1. Unzip IPA
      yield '📦 Extracting IPA...';
      await for (final log in _runCommand('unzip', ['-q', ipaPath, '-d', tempDir.path])) {
        yield log;
      }

      final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
      if (!await payloadDir.exists()) {
        throw Exception('Payload directory not found inside IPA');
      }

      yield '🧹 Stripping digital signatures and provisioning files...';
      // Find and delete all _CodeSignature folders and embedded.mobileprovision files
      final cleanScript = '''
find "${payloadDir.path}" -name "_CodeSignature" -exec rm -rf {} +
find "${payloadDir.path}" -name "embedded.mobileprovision" -exec rm -f {} +
''';
      final scriptFile = File(p.join(tempDir.path, 'clean.sh'));
      await scriptFile.writeAsString(cleanScript);
      await Process.run('chmod', ['+x', scriptFile.path]);

      await for (final log in _runCommand('bash', [scriptFile.path])) {
        yield log;
      }

      // 2. Re-pack into IPA
      yield '📦 Rebuilding unsigned IPA archive...';
      await Directory(p.dirname(outputPath)).create(recursive: true);
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      await for (final log in _runCommand('zip', [
        '-qr',
        outputPath,
        'Payload'
      ], workingDirectory: tempDir.path)) {
        yield log;
      }

      yield '🎉 Unsigning successful! Saved unsigned IPA to: $outputPath';
    } catch (e) {
      yield '[ERROR] IPA Unsigning failed: $e';
      rethrow;
    } finally {
      yield '🧹 Cleaning up temporary directory...';
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  /// Unsign APK/AAB (Removes signing keys from META-INF)
  Stream<String> unsignApk({
    required String apkPath,
    required String outputPath,
  }) async* {
    yield '🧹 Copying APK/AAB to output target...';
    await Directory(p.dirname(outputPath)).create(recursive: true);
    final outputFile = File(outputPath);
    if (await outputFile.exists()) {
      await outputFile.delete();
    }
    await File(apkPath).copy(outputPath);

    if (Platform.isWindows) {
      yield '🧹 Stripping signatures via PowerShell ZipArchive API...';
      final tempDir = await Directory.systemTemp.createTemp('apk_unsign_ps_');
      final scriptFile = File(p.join(tempDir.path, 'unsign.ps1'));

      // PowerShell script to delete signing files from zip in-place
      final psScript = '''
Add-Type -AssemblyName System.IO.Compression
\$zip = [System.IO.Compression.ZipFile]::Open('${outputFile.path.replaceAll("'", "''")}', 'Update')
\$toDelete = New-Object System.Collections.Generic.List[System.IO.Compression.ZipArchiveEntry]
foreach (\$entry in \$zip.Entries) {
    if (\$entry.FullName.StartsWith('META-INF/') -and (\$entry.FullName.EndsWith('.SF') -or \$entry.FullName.EndsWith('.RSA') -or \$entry.FullName.EndsWith('.DSA') -or \$entry.FullName.EndsWith('.EC') -or \$entry.FullName.EndsWith('MANIFEST.MF') -or \$entry.Name.StartsWith('SIG-'))) {
        \$toDelete.Add(\$entry)
    }
}
foreach (\$entry in \$toDelete) {
    Write-Output "Removing entry: \$(\$entry.FullName)"
    \$entry.Delete()
}
\$zip.Dispose()
''';
      await scriptFile.writeAsString(psScript);

      await for (final log in _runCommand('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path
      ])) {
        yield log;
      }

      await tempDir.delete(recursive: true);
    } else {
      yield '🧹 Stripping signatures via zip utility...';
      // On macOS/Linux we can directly use zip -d to delete the files from the archive
      final args = [
        '-d',
        outputPath,
        'META-INF/*.SF',
        'META-INF/*.RSA',
        'META-INF/*.DSA',
        'META-INF/*.EC',
        'META-INF/MANIFEST.MF',
        'META-INF/SIG-*'
      ];
      // zip -d might fail if any pattern doesn't match. We'll run in-shell or ignore warning.
      // To prevent throwing when some extensions aren't there, we can write a small script
      final tempDir = await Directory.systemTemp.createTemp('apk_unsign_');
      final scriptFile = File(p.join(tempDir.path, 'unsign.sh'));
      final shScript = '''
zip -d "$outputPath" "META-INF/*.SF" "META-INF/*.RSA" "META-INF/*.DSA" "META-INF/*.EC" "META-INF/MANIFEST.MF" "META-INF/SIG-*" || true
''';
      await scriptFile.writeAsString(shScript);
      await Process.run('chmod', ['+x', scriptFile.path]);

      await for (final log in _runCommand('bash', [scriptFile.path])) {
        yield log;
      }
      await tempDir.delete(recursive: true);
    }

    yield '🎉 Unsigning successful! Saved unsigned APK/AAB to: $outputPath';
  }
}
