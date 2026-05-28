import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'vault_service.dart';
import 'signing_service.dart';

class SharingServer {
  HttpServer? _server;
  String? _filePath;
  String? _fileName;
  final Map<String, String> _registeredFiles = {};

  final _vaultService = VaultService();
  final _signingService = SigningService();

  void registerFile(String filePath) {
    _registeredFiles[p.basename(filePath)] = filePath;
  }

  Future<String> getDownloadUrl(String filePath) async {
    registerFile(filePath);
    final apiUrl = await startServerMode();
    return '$apiUrl/download/${Uri.encodeComponent(p.basename(filePath))}';
  }

  /// Discovers the local machine's IPv4 address.
  static Future<String?> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.contains('docker') ||
            name.contains('virtual') ||
            name.contains('vbox') ||
            name.contains('vmnet') ||
            name.contains('vpn')) {
          continue;
        }
        
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            return address.address;
          }
        }
      }
      
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            return address.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Starts the server and returns the base API URL.
  Future<String> startServerMode() async {
    final localIp = await getLocalIpAddress() ?? '127.0.0.1';
    if (_server != null) {
      return 'http://$localIp:${_server!.port}';
    }

    // Bind to all interfaces on a random free port (port 0)
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = _server!.port;

    _server!.listen((HttpRequest request) async {
      final response = request.response;
      
      // CORS configuration
      response.headers.add('Access-Control-Allow-Origin', '*');
      response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      response.headers.add(
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
        if (uriPath == '/api/profiles') {
          if (request.method == 'GET') {
            final profiles = await _vaultService.getProfiles();
            final jsonStr = json.encode(profiles.map((p) => p.toJson()).toList());
            response.headers.contentType = ContentType.json;
            response.write(jsonStr);
          } else {
            response.statusCode = HttpStatus.methodNotAllowed;
          }
        }
        
        else if (uriPath == '/api/sign') {
          if (request.method == 'POST') {
            // Read headers
            final profileId = request.headers.value('x-profile-id') ?? '';
            final platform = request.headers.value('x-platform') ?? 'ios';
            final appType = request.headers.value('x-app-type') ?? 'apk';
            final uploadName = request.headers.value('x-file-name') ?? 'unsigned.bin';
            final bundleId = request.headers.value('x-bundle-id');

            // Find profile in Vault
            final profiles = await _vaultService.getProfiles();
            final profileMatching = profiles.where((p) => p.id == profileId);
            
            if (profileMatching.isEmpty) {
              response.statusCode = HttpStatus.badRequest;
              response.write('Error: Selected profile ID "$profileId" not found on server.');
              await response.close();
              return;
            }
            final profile = profileMatching.first;

            // Prepare temporary paths
            final tempDir = await Directory.systemTemp.createTemp('api_sign_');
            final unsignedFile = File(p.join(tempDir.path, uploadName));
            
            // Save request stream to file
            final sink = unsignedFile.openWrite();
            await sink.addStream(request);
            await sink.close();

            final ext = p.extension(uploadName);
            final baseName = p.basenameWithoutExtension(uploadName);
            final signedFilePath = p.join(tempDir.path, '$baseName-signed$ext');

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
                  final zipalign = prefs.getString('zipalign_path') ?? 'zipalign';
                  final apksigner = prefs.getString('apksigner_path') ?? 'apksigner';

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

              // Exhaust the stream to complete the signing process
              await for (final _ in signStream) {
                // Logs can be output to server console if needed
              }

              final signedFile = File(signedFilePath);
              if (await signedFile.exists()) {
                response.headers.contentType = ContentType('application', 'octet-stream');
                response.headers.contentLength = await signedFile.length();
                response.headers.add(
                  'Content-Disposition',
                  'attachment; filename="${p.basename(signedFilePath)}"',
                );
                await response.addStream(signedFile.openRead());
              } else {
                throw Exception('Signed output file not generated.');
              }
            } catch (e) {
              response.statusCode = HttpStatus.internalServerError;
              response.write('Signing process error: $e');
            } finally {
              // Schedule deletion of temp assets shortly after closing
              Future.delayed(const Duration(seconds: 10), () {
                tempDir.delete(recursive: true).catchError((_) {});
              });
            }
          } else {
            response.statusCode = HttpStatus.methodNotAllowed;
          }
        }

        else if (uriPath == '/api/unsign') {
          if (request.method == 'POST') {
            final platform = request.headers.value('x-platform') ?? 'ios';
            final uploadName = request.headers.value('x-file-name') ?? 'signed.bin';

            final tempDir = await Directory.systemTemp.createTemp('api_unsign_');
            final signedFile = File(p.join(tempDir.path, uploadName));
            
            final sink = signedFile.openWrite();
            await sink.addStream(request);
            await sink.close();

            final ext = p.extension(uploadName);
            final baseName = p.basenameWithoutExtension(uploadName);
            final unsignedFilePath = p.join(tempDir.path, '$baseName-unsigned$ext');

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
                response.headers.contentType = ContentType('application', 'octet-stream');
                response.headers.contentLength = await unsignedFile.length();
                response.headers.add(
                  'Content-Disposition',
                  'attachment; filename="${p.basename(unsignedFilePath)}"',
                );
                await response.addStream(unsignedFile.openRead());
              } else {
                throw Exception('Unsigned output file not generated.');
              }
            } catch (e) {
              response.statusCode = HttpStatus.internalServerError;
              response.write('Unsigning process error: $e');
            } finally {
              Future.delayed(const Duration(seconds: 10), () {
                tempDir.delete(recursive: true).catchError((_) {});
              });
            }
          } else {
            response.statusCode = HttpStatus.methodNotAllowed;
          }
        }

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
            
            if (filePath != null && fileName.isNotEmpty) {
              final file = File(filePath);
              if (await file.exists()) {
                final length = await file.length();
                String mime = 'application/octet-stream';
                if (fileName.endsWith('.apk')) {
                  mime = 'application/vnd.android.package-archive';
                }
                response.headers.contentType = ContentType.parse(mime);
                response.headers.contentLength = length;
                response.headers.add(
                  'Content-Disposition',
                  'attachment; filename="$fileName"',
                );
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

  /// Single-file direct download sharing (standard QR share link)
  Future<String> start(String filePath) async {
    _filePath = filePath;
    _fileName = p.basename(filePath);
    registerFile(filePath);
    final apiUrl = await startServerMode();
    return '$apiUrl/download/${Uri.encodeComponent(_fileName!)}';
  }

  /// Stops the server if running.
  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _filePath = null;
      _fileName = null;
    }
  }

  bool get isRunning => _server != null;
  int? get port => _server?.port;
}
