import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'vault_service.dart';
import 'signing_service.dart';

/// A single device download/install event captured from HTTP request metadata.
class DeviceInstallLog {
  final String deviceName;
  final String platform;
  final String downloadedAt;
  final String ip;

  DeviceInstallLog({
    required this.deviceName,
    required this.platform,
    required this.downloadedAt,
    required this.ip,
  });
}

/// Result returned by [SharingServer.startOta].
class OtaShareResult {
  final String localUrl;
  final String? publicUrl;
  final String qrUrl;
  final bool hasTunnel;

  const OtaShareResult({
    required this.localUrl,
    this.publicUrl,
    required this.qrUrl,
    required this.hasTunnel,
  });
}

class SharingServer {
  HttpServer? _server;
  Process? _sshProcess;

  String? _filePath;
  String? _fileName;
  String? _publicBaseUrl;
  String? _cloudUrl;
  final Map<String, String> _registeredFiles = {};

  // App metadata used for generating iOS manifest.plist
  String _appBundleId = 'com.example.app';
  String _appVersion = '1.0.0';
  String _appName = 'App';

  final List<DeviceInstallLog> _downloadLogs = [];
  final _logsController =
      StreamController<List<DeviceInstallLog>>.broadcast();

  final _vaultService = VaultService();
  final _signingService = SigningService();

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Broadcast stream — fires whenever a device downloads the file.
  Stream<List<DeviceInstallLog>> get logsStream => _logsController.stream;

  /// Snapshot of all logged download events so far.
  List<DeviceInstallLog> get downloadLogs =>
      List.unmodifiable(_downloadLogs);

  void setAppMetadata({
    required String bundleId,
    required String version,
    required String appName,
  }) {
    _appBundleId = bundleId;
    _appVersion = version;
    _appName = appName;
  }

  void registerFile(String filePath) {
    _registeredFiles[p.basename(filePath)] = filePath;
  }

  Future<String> getDownloadUrl(String filePath) async {
    registerFile(filePath);
    final apiUrl = await startServerMode();
    return '$apiUrl/download/${Uri.encodeComponent(p.basename(filePath))}';
  }

  // ── Network helpers ────────────────────────────────────────────────────────

  /// Returns the best non-virtual local IPv4 address.
  static Future<String?> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('docker') ||
            name.contains('virtual') ||
            name.contains('vbox') ||
            name.contains('vmnet') ||
            name.contains('vpn')) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Device / User-Agent parsing ────────────────────────────────────────────

  String _parseDeviceName(String? ua) {
    if (ua == null || ua.isEmpty) return 'Unknown Device';
    if (ua.contains('iPhone')) return 'iPhone';
    if (ua.contains('iPad')) return 'iPad';
    if (ua.contains('Android')) {
      final match =
          RegExp(r'Android[\s\d.]+;\s*([^;)]+)').firstMatch(ua);
      final model = match?.group(1)?.trim();
      return (model != null && model.isNotEmpty) ? model : 'Android Device';
    }
    if (ua.contains('Macintosh') || ua.contains('Mac OS X')) return 'Mac';
    if (ua.contains('Windows')) return 'Windows PC';
    return 'Unknown Device';
  }

  String _parsePlatformFromUa(String? ua) {
    if (ua == null) return 'Unknown';
    if (ua.contains('iPhone') || ua.contains('iPad')) return 'iOS';
    if (ua.contains('Android')) return 'Android';
    if (ua.contains('Macintosh') || ua.contains('Windows')) return 'Desktop';
    return 'Unknown';
  }

  void _logDownload(HttpRequest request) {
    final ua = request.headers.value('user-agent');
    final ip =
        request.connectionInfo?.remoteAddress.address ?? 'Unknown';
    final log = DeviceInstallLog(
      deviceName: _parseDeviceName(ua),
      platform: _parsePlatformFromUa(ua),
      downloadedAt:
          DateTime.now().toLocal().toString().substring(0, 19),
      ip: ip,
    );
    _downloadLogs.add(log);
    if (!_logsController.isClosed) {
      _logsController.add(List.unmodifiable(_downloadLogs));
    }
  }

  // ── iOS OTA manifest ───────────────────────────────────────────────────────

  String _buildManifestPlist(String ipaUrl) => '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>$ipaUrl</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>$_appBundleId</string>
        <key>bundle-version</key>
        <string>$_appVersion</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>$_appName</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>''';

  // ── ssh tunnel ─────────────────────────────────────────────────────────────

  /// Starts an SSH tunnel using localhost.run on [port] and returns the public HTTPS URL.
  /// Returns null if the tunnel fails to start or times out.
  Future<String?> _startSshTunnel(int port) async {
    _sshProcess?.kill();
    _sshProcess = null;

    try {
      final process = await Process.start(
        'ssh',
        [
          '-o', 'StrictHostKeyChecking=no',
          '-o', 'UserKnownHostsFile=/dev/null',
          '-R', '80:localhost:$port',
          'nokey@localhost.run',
        ],
        mode: ProcessStartMode.normal,
      );
      _sshProcess = process;

      final completer = Completer<String?>();
      final timeoutTimer = Timer(const Duration(seconds: 8), () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      final buffer = StringBuffer();
      process.stdout.transform(utf8.decoder).listen((data) {
        buffer.write(data);
        final content = buffer.toString();
        // Look for the tunnel line: "tunneled with tls termination, https://..."
        final regExp = RegExp(r'tunneled with tls termination,\s*(https://[a-zA-Z0-9.-]+)');
        final match = regExp.firstMatch(content);
        if (match != null && !completer.isCompleted) {
          timeoutTimer.cancel();
          completer.complete(match.group(1));
        }
      });

      process.exitCode.then((_) {
        if (!completer.isCompleted) {
          timeoutTimer.cancel();
          completer.complete(null);
        }
      });

      return await completer.future;
    } catch (_) {
      return null;
    }
  }

  // ── Core HTTP server ───────────────────────────────────────────────────────

  /// Starts the HTTP server (idempotent) and returns the base local URL.
  Future<String> startServerMode() async {
    final localIp = await getLocalIpAddress() ?? '127.0.0.1';
    if (_server != null) {
      return _publicBaseUrl ?? 'http://$localIp:${_server!.port}';
    }

    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = _server!.port;

    _server!.listen((HttpRequest request) async {
      final response = request.response;

      // CORS
      response.headers
        ..add('Access-Control-Allow-Origin', '*')
        ..add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        ..add(
          'Access-Control-Allow-Headers',
          'x-profile-id, x-platform, x-app-type, x-file-name, x-bundle-id, Content-Type',
        );

      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.ok;
        await response.close();
        return;
      }

      final uriPath = request.uri.path;

      try {
        // ── iOS OTA Manifest ────────────────────────────────────────────────
        if (uriPath == '/manifest.plist') {
          _logDownload(request);
          final baseUrl = _publicBaseUrl ?? 'http://$localIp:$port';
          final ipaUrl = _cloudUrl ??
              '$baseUrl/download/${Uri.encodeComponent(_fileName ?? '')}';
          final plist = _buildManifestPlist(ipaUrl);
          response.headers.contentType =
              ContentType('application', 'x-apple-aspen-config');
          response.write(plist);
        }

        // ── Profile list ────────────────────────────────────────────────────
        else if (uriPath == '/api/profiles') {
          if (request.method == 'GET') {
            final profiles = await _vaultService.getProfiles();
            final jsonStr =
                json.encode(profiles.map((p) => p.toJson()).toList());
            response.headers.contentType = ContentType.json;
            response.write(jsonStr);
          } else {
            response.statusCode = HttpStatus.methodNotAllowed;
          }
        }

        // ── Remote signing ──────────────────────────────────────────────────
        else if (uriPath == '/api/sign') {
          if (request.method == 'POST') {
            final profileId =
                request.headers.value('x-profile-id') ?? '';
            final platform =
                request.headers.value('x-platform') ?? 'ios';
            final appType =
                request.headers.value('x-app-type') ?? 'apk';
            final uploadName =
                request.headers.value('x-file-name') ?? 'unsigned.bin';
            final bundleId =
                request.headers.value('x-bundle-id');

            final profiles = await _vaultService.getProfiles();
            final profileMatching =
                profiles.where((p) => p.id == profileId);

            if (profileMatching.isEmpty) {
              response.statusCode = HttpStatus.badRequest;
              response.write(
                  'Error: Profile "$profileId" not found on server.');
              await response.close();
              return;
            }
            final profile = profileMatching.first;

            final tempDir =
                await Directory.systemTemp.createTemp('api_sign_');
            final unsignedFile =
                File(p.join(tempDir.path, uploadName));

            final sink = unsignedFile.openWrite();
            await sink.addStream(request);
            await sink.close();

            final ext = p.extension(uploadName);
            final baseName = p.basenameWithoutExtension(uploadName);
            final signedFilePath =
                p.join(tempDir.path, '$baseName-signed$ext');

            try {
              Stream<String> signStream;
              if (platform == 'ios') {
                signStream = _signingService.resignIpa(
                  ipaPath: unsignedFile.path,
                  p12Path: profile.p12Path,
                  provPath: profile.provPath,
                  p12Password: profile.p12Password,
                  keychainPassword: profile.keychainPassword,
                  chosenIdentity: profile.selectedIdentity,
                  newBundleId: bundleId ?? profile.bundleId,
                  outputPath: signedFilePath,
                );
              } else {
                if (appType == 'apk') {
                  final prefs = await SharedPreferences.getInstance();
                  final zipalign =
                      prefs.getString('zipalign_path') ?? 'zipalign';
                  final apksigner =
                      prefs.getString('apksigner_path') ?? 'apksigner';
                  signStream = _signingService.signApk(
                    apkPath: unsignedFile.path,
                    keystorePath: profile.keystorePath,
                    keyAlias: profile.keyAlias,
                    keyPassword: profile.keyPassword,
                    storePassword: profile.storePassword,
                    zipalignPath: zipalign,
                    apksignerJarPath: apksigner,
                    outputPath: signedFilePath,
                  );
                } else {
                  signStream = _signingService.signAab(
                    aabPath: unsignedFile.path,
                    keystorePath: profile.keystorePath,
                    keyAlias: profile.keyAlias,
                    keyPassword: profile.keyPassword,
                    storePassword: profile.storePassword,
                    outputPath: signedFilePath,
                  );
                }
              }
              await for (final _ in signStream) {}

              final signedFile = File(signedFilePath);
              if (await signedFile.exists()) {
                response.headers.contentType =
                    ContentType('application', 'octet-stream');
                response.headers.contentLength =
                    await signedFile.length();
                response.headers.add('Content-Disposition',
                    'attachment; filename="${p.basename(signedFilePath)}"');
                await response.addStream(signedFile.openRead());
              } else {
                throw Exception('Signed output file not generated.');
              }
            } catch (e) {
              response.statusCode = HttpStatus.internalServerError;
              response.write('Signing process error: $e');
            } finally {
              Future.delayed(const Duration(seconds: 10), () {
                tempDir.delete(recursive: true).catchError((_) => tempDir);
              });
            }
          } else {
            response.statusCode = HttpStatus.methodNotAllowed;
          }
        }

        // ── Remote un-signing ───────────────────────────────────────────────
        else if (uriPath == '/api/unsign') {
          if (request.method == 'POST') {
            final platform =
                request.headers.value('x-platform') ?? 'ios';
            final uploadName =
                request.headers.value('x-file-name') ?? 'signed.bin';

            final tempDir =
                await Directory.systemTemp.createTemp('api_unsign_');
            final signedFile =
                File(p.join(tempDir.path, uploadName));

            final sink = signedFile.openWrite();
            await sink.addStream(request);
            await sink.close();

            final ext = p.extension(uploadName);
            final baseName = p.basenameWithoutExtension(uploadName);
            final unsignedFilePath =
                p.join(tempDir.path, '$baseName-unsigned$ext');

            try {
              Stream<String> unsignStream;
              if (platform == 'ios') {
                unsignStream = _signingService.unsignIpa(
                  ipaPath: signedFile.path,
                  outputPath: unsignedFilePath,
                );
              } else {
                unsignStream = _signingService.unsignApk(
                  apkPath: signedFile.path,
                  outputPath: unsignedFilePath,
                );
              }
              await for (final _ in unsignStream) {}

              final unsignedFile = File(unsignedFilePath);
              if (await unsignedFile.exists()) {
                response.headers.contentType =
                    ContentType('application', 'octet-stream');
                response.headers.contentLength =
                    await unsignedFile.length();
                response.headers.add('Content-Disposition',
                    'attachment; filename="${p.basename(unsignedFilePath)}"');
                await response.addStream(unsignedFile.openRead());
              } else {
                throw Exception('Unsigned output file not generated.');
              }
            } catch (e) {
              response.statusCode = HttpStatus.internalServerError;
              response.write('Unsigning process error: $e');
            } finally {
              Future.delayed(const Duration(seconds: 10), () {
                tempDir.delete(recursive: true).catchError((_) => tempDir);
              });
            }
          } else {
            response.statusCode = HttpStatus.methodNotAllowed;
          }
        }

        // ── File download ───────────────────────────────────────────────────
        else if (uriPath.startsWith('/download')) {
          if (request.method == 'GET') {
            String? filePath;
            String fileName = '';

            if (uriPath.startsWith('/download/')) {
              fileName = Uri.decodeComponent(uriPath.substring(10));
              filePath = _registeredFiles[fileName];
            }

            filePath ??= _filePath;
            fileName = fileName.isNotEmpty ? fileName : (_fileName ?? '');

            if (_cloudUrl != null) {
              _logDownload(request);
              response.statusCode = HttpStatus.movedTemporarily;
              response.headers.set('Location', _cloudUrl!);
              await response.close();
              return;
            }

            if (filePath != null && fileName.isNotEmpty) {
              final file = File(filePath);
              if (await file.exists()) {
                // ★ Track download
                _logDownload(request);

                final length = await file.length();
                String mime = 'application/octet-stream';
                if (fileName.endsWith('.apk')) {
                  mime = 'application/vnd.android.package-archive';
                }
                response.headers.contentType =
                    ContentType.parse(mime);
                response.headers.contentLength = length;
                response.headers.add('Content-Disposition',
                    'attachment; filename="$fileName"');
                await response.addStream(file.openRead());
              } else {
                response.statusCode = HttpStatus.notFound;
                response.write('File not found');
              }
            } else {
              response.statusCode = HttpStatus.notFound;
              response.write('No file currently shared.');
            }
          } else {
            response.statusCode = HttpStatus.methodNotAllowed;
          }
        }

        // ── 404 ─────────────────────────────────────────────────────────────
        else {
          response.statusCode = HttpStatus.notFound;
          response.write('Endpoint not found');
        }
      } catch (e) {
        response.statusCode = HttpStatus.internalServerError;
        response.write('Server handling exception: $e');
      }

      try {
        await response.close();
      } catch (_) {}
    });

    return 'http://$localIp:$port';
  }

  // ── Public start methods ───────────────────────────────────────────────────

  /// OTA-capable share: starts server + attempts ngrok tunnel.
  /// Returns [OtaShareResult] with the correct QR payload per platform.
  Future<OtaShareResult> startOta(
    String filePath, {
    String? cloudUrl,
    String bundleId = 'com.example.app',
    String version = '1.0',
    String appName = 'App',
  }) async {
    _filePath = filePath;
    _fileName = p.basename(filePath);
    _cloudUrl = cloudUrl;
    registerFile(filePath);
    setAppMetadata(
        bundleId: bundleId, version: version, appName: appName);

    final localUrl = await startServerMode();
    final port = _server!.port;

    // Attempt SSH tunnel
    final publicUrl = await _startSshTunnel(port);
    _publicBaseUrl = publicUrl;

    final isIpa = filePath.toLowerCase().endsWith('.ipa');

    String qrUrl;
    if (isIpa && publicUrl != null) {
      // iOS OTA: HTTPS manifest required by iOS
      final manifestUrl = '$publicUrl/manifest.plist';
      qrUrl =
          'itms-services://?action=download-manifest&url=${Uri.encodeComponent(manifestUrl)}';
    } else if (publicUrl != null) {
      // Android/Desktop: direct redirect link
      qrUrl = '$publicUrl/download/${Uri.encodeComponent(_fileName!)}';
    } else {
      // Fallback: direct cloud URL or local URL
      qrUrl = cloudUrl ?? '$localUrl/download/${Uri.encodeComponent(_fileName!)}';
    }

    return OtaShareResult(
      localUrl: localUrl,
      publicUrl: publicUrl,
      qrUrl: qrUrl,
      hasTunnel: publicUrl != null,
    );
  }

  /// Legacy single-file direct download sharing.
  Future<String> start(String filePath) async {
    _filePath = filePath;
    _fileName = p.basename(filePath);
    registerFile(filePath);
    final apiUrl = await startServerMode();
    return '$apiUrl/download/${Uri.encodeComponent(_fileName!)}';
  }

  /// Stops the server, kills SSH tunnel, and clears state.
  Future<void> stop() async {
    _sshProcess?.kill();
    _sshProcess = null;
    _publicBaseUrl = null;
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _filePath = null;
      _fileName = null;
    }
    _downloadLogs.clear();
    if (!_logsController.isClosed) {
      _logsController.add([]);
    }
  }

  void dispose() {
    _logsController.close();
  }

  /// Uploads [filePath] to transfer.sh and returns the public HTTPS download URL.
  /// Returns null if the upload fails or curl is not available.
  Future<String?> uploadToCloud(String filePath) async {
    final fileName = p.basename(filePath);
    try {
      final result = await Process.run('curl', [
        '--upload-file', filePath,
        'https://transfer.sh/$fileName',
        '--silent',
        '--max-time', '300', // 5 min timeout for large files
      ]);
      if (result.exitCode == 0) {
        final url = (result.stdout as String).trim();
        if (url.startsWith('https://')) return url;
      }
    } catch (_) {}
    return null;
  }

  /// Generates an iOS OTA manifest.plist pointing at [ipaUrl],
  /// uploads it to transfer.sh, and returns the manifest's HTTPS URL.
  Future<String?> uploadManifestToCloud(String ipaUrl) async {
    final plist = _buildManifestPlist(ipaUrl);
    final tempPath = p.join(
      Directory.systemTemp.path,
      'manifest_${DateTime.now().millisecondsSinceEpoch}.plist',
    );
    final tempFile = File(tempPath);
    try {
      await tempFile.writeAsString(plist);
      final result = await Process.run('curl', [
        '--upload-file', tempPath,
        'https://transfer.sh/manifest.plist',
        '--silent',
        '--max-time', '30',
      ]);
      if (result.exitCode == 0) {
        final url = (result.stdout as String).trim();
        if (url.startsWith('https://')) return url;
      }
    } catch (_) {
    } finally {
      tempFile.delete().catchError((_) => tempFile);
    }
    return null;
  }

  bool get isRunning => _server != null;
  int? get port => _server?.port;
}
