import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class PushService {
  static String base64UrlNoPadding(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Uint8List _normalize32(Uint8List bytes) {
    if (bytes.length == 32) return bytes;
    if (bytes.length > 32) {
      if (bytes[0] == 0) {
        return bytes.sublist(bytes.length - 32);
      }
      return bytes.sublist(0, 32);
    }
    final res = Uint8List(32);
    res.setRange(32 - bytes.length, 32, bytes);
    return res;
  }

  static Uint8List derToRaw(Uint8List der) {
    int index = 0;
    if (der[index++] != 0x30) throw Exception("Invalid DER signature prefix");
    int totalLen = der[index++];
    if (totalLen > 0x80) {
      index += totalLen - 0x80; // Skip multi-byte length indicator
    }
    
    if (der[index++] != 0x02) throw Exception("Invalid DER signature R tag");
    int rLen = der[index++];
    int rStart = index;
    index += rLen;
    
    if (der[index++] != 0x02) throw Exception("Invalid DER signature S tag");
    int sLen = der[index++];
    int sStart = index;
    
    Uint8List rBytes = der.sublist(rStart, rStart + rLen);
    Uint8List sBytes = der.sublist(sStart, sStart + sLen);
    
    Uint8List rNorm = _normalize32(rBytes);
    Uint8List sNorm = _normalize32(sBytes);
    
    final raw = Uint8List(64);
    raw.setRange(0, 32, rNorm);
    raw.setRange(32, 64, sNorm);
    return raw;
  }

  /// Generates APNs JWT token from .p8 key content/file
  static Future<String> generateApnsJwt({
    required String p8Content,
    required String keyId,
    required String teamId,
  }) async {
    final iat = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final header = {"alg": "ES256", "kid": keyId};
    final payload = {"iss": teamId, "iat": iat};

    final headerB64 = base64UrlNoPadding(utf8.encode(json.encode(header)));
    final payloadB64 = base64UrlNoPadding(utf8.encode(json.encode(payload)));
    final signingInput = "$headerB64.$payloadB64";

    // Write signing input and p8 key to temporary files
    final tempDir = await Directory.systemTemp.createTemp('apns_jwt');
    final inputFile = File(p.join(tempDir.path, 'input.txt'));
    await inputFile.writeAsString(signingInput);

    final keyFile = File(p.join(tempDir.path, 'key.p8'));
    await keyFile.writeAsString(p8Content);

    try {
      final result = await Process.run(
        'openssl',
        ['dgst', '-binary', '-sha256', '-sign', keyFile.path, inputFile.path],
        stdoutEncoding: null,
      );

      if (result.exitCode != 0) {
        throw Exception("OpenSSL signing failed: ${result.stderr}");
      }

      final derSignature = result.stdout as List<int>;
      final rawSignature = derToRaw(Uint8List.fromList(derSignature));
      final signatureB64 = base64UrlNoPadding(rawSignature);

      return "$signingInput.$signatureB64";
    } finally {
      await tempDir.delete(recursive: true);
    }
  }

  /// Generates Google OAuth2 token for FCM HTTP v1 from service account JSON
  static Future<String> generateFcmOAuth2Token(String serviceAccountJson) async {
    final Map<String, dynamic> sa = json.decode(serviceAccountJson);
    final String clientEmail = sa['client_email'];
    final String privateKey = sa['private_key'];

    final iat = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final exp = iat + 3600;

    final header = {"alg": "RS256", "typ": "JWT"};
    final payload = {
      "iss": clientEmail,
      "scope": "https://www.googleapis.com/auth/firebase.messaging",
      "aud": "https://oauth2.googleapis.com/token",
      "exp": exp,
      "iat": iat
    };

    final headerB64 = base64UrlNoPadding(utf8.encode(json.encode(header)));
    final payloadB64 = base64UrlNoPadding(utf8.encode(json.encode(payload)));
    final signingInput = "$headerB64.$payloadB64";

    final tempDir = await Directory.systemTemp.createTemp('fcm_jwt');
    final inputFile = File(p.join(tempDir.path, 'input.txt'));
    await inputFile.writeAsString(signingInput);

    final keyFile = File(p.join(tempDir.path, 'key.pem'));
    await keyFile.writeAsString(privateKey);

    try {
      final result = await Process.run(
        'openssl',
        ['dgst', '-binary', '-sha256', '-sign', keyFile.path, inputFile.path],
        stdoutEncoding: null,
      );

      if (result.exitCode != 0) {
        throw Exception("OpenSSL RS256 signing failed: ${result.stderr}");
      }

      final signature = result.stdout as List<int>;
      final signatureB64 = base64UrlNoPadding(signature);
      final jwt = "$signingInput.$signatureB64";

      // POST to Google OAuth2 token endpoint
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$jwt',
      );

      if (response.statusCode != 200) {
        throw Exception("Failed to get Google access token: ${response.body}");
      }

      final tokenData = json.decode(response.body);
      return tokenData['access_token'];
    } finally {
      await tempDir.delete(recursive: true);
    }
  }

  /// Sends APNs push notification using macOS curl (supports HTTP/2)
  static Future<PushResult> sendApns({
    required bool isSandbox,
    required bool useToken,
    required String? p8Content,
    required String? keyId,
    required String? teamId,
    required String? certPath,
    required String? certPassword,
    required String bundleId,
    required String deviceToken,
    required String title,
    required String body,
    required bool sound,
    required int badge,
    required Map<String, dynamic> customData,
  }) async {
    final domain = isSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    final url = "https://$domain/3/device/$deviceToken";

    // Build Payload JSON
    final Map<String, dynamic> payload = {
      "aps": {
        "alert": {
          "title": title,
          "body": body,
        },
        "sound": sound ? "default" : null,
        "badge": badge,
      }
    };
    customData.forEach((key, value) {
      if (key != "aps") {
        payload[key] = value;
      }
    });

    final payloadJson = json.encode(payload);
    final headers = <String, String>{
      "apns-topic": bundleId,
      "apns-push-type": "alert",
    };

    List<String> curlArgs = ["-i", "--http2", "-X", "POST"];

    final tempDir = await Directory.systemTemp.createTemp('apns_push');
    String? token;

    try {
      if (useToken) {
        if (p8Content == null || keyId == null || teamId == null) {
          throw Exception("Missing token credentials (.p8 content, Key ID, or Team ID)");
        }
        token = await generateApnsJwt(p8Content: p8Content, keyId: keyId, teamId: teamId);
        headers["authorization"] = "bearer $token";
      } else {
        if (certPath == null) {
          throw Exception("Certificate path is required for cert authentication");
        }
        final ext = p.extension(certPath!).toLowerCase();
        if (ext == '.p12' || ext == '.pfx') {
          curlArgs.addAll(["--cert-type", "P12"]);
        }
        if (certPassword != null && certPassword.isNotEmpty) {
          curlArgs.addAll(["--cert", "$certPath:$certPassword"]);
        } else {
          curlArgs.addAll(["--cert", certPath]);
        }
      }

      // Add Headers to curl
      headers.forEach((key, val) {
        curlArgs.addAll(["-H", "$key: $val"]);
      });

      // Add Data payload
      curlArgs.addAll(["-d", payloadJson, url]);

      // Generate visual curl representation for display (without private key/password)
      final safeHeaders = Map<String, String>.from(headers);
      if (safeHeaders.containsKey("authorization")) {
        safeHeaders["authorization"] = "bearer <JWT_TOKEN>";
      }
      final safeCertPath = certPath != null ? p.basename(certPath) : null;
      final visualCurl = StringBuffer("curl -i --http2 -X POST \\\n");
      if (!useToken && safeCertPath != null) {
        final ext = p.extension(certPath!).toLowerCase();
        if (ext == '.p12' || ext == '.pfx') {
          visualCurl.write("  --cert-type P12 \\\n");
        }
        visualCurl.write("  --cert \"$safeCertPath${certPassword != null && certPassword.isNotEmpty ? ':<PASSWORD>' : ''}\" \\\n");
      }
      safeHeaders.forEach((key, val) {
        visualCurl.write("  -H \"$key: $val\" \\\n");
      });
      visualCurl.write("  -d '$payloadJson' \\\n");
      visualCurl.write("  \"$url\"");

      // Run curl
      final result = await Process.run('curl', curlArgs);

      return PushResult(
        statusCode: result.exitCode == 0 ? _parseCurlStatusCode(result.stdout) : -1,
        success: result.exitCode == 0 && _isCurlSuccess(result.stdout),
        requestLog: visualCurl.toString(),
        responseBody: result.exitCode == 0 ? result.stdout : "Curl process error:\n${result.stderr}",
      );
    } catch (e) {
      return PushResult(
        statusCode: -1,
        success: false,
        requestLog: "Failed to construct APNs request.",
        responseBody: e.toString(),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  }

  /// Sends FCM Push Notification (Legacy or HTTP v1)
  static Future<PushResult> sendFcm({
    required bool isV1,
    required String? serviceAccountJson,
    required String? serverKey,
    required String registrationToken,
    required String title,
    required String body,
    required bool sound,
    required int badge,
    required Map<String, dynamic> customData,
  }) async {
    final Map<String, dynamic> payload = {};
    String url = "";
    final headers = <String, String>{
      "Content-Type": "application/json",
    };

    try {
      if (isV1) {
        if (serviceAccountJson == null) {
          throw Exception("Firebase Service Account JSON is required for HTTP v1");
        }
        final Map<String, dynamic> sa = json.decode(serviceAccountJson);
        final String projectId = sa['project_id'];
        url = "https://fcm.googleapis.com/v1/projects/$projectId/messages:send";

        final accessToken = await generateFcmOAuth2Token(serviceAccountJson);
        headers["Authorization"] = "Bearer $accessToken";

        // Build FCM HTTP v1 body
        payload["message"] = {
          "token": registrationToken,
          "notification": {
            "title": title,
            "body": body,
          },
        };

        // Add sound/badge for platforms inside APNs/Android configurations
        final Map<String, dynamic> apnsPayload = {
          "payload": {
            "aps": {
              "sound": sound ? "default" : null,
              "badge": badge,
            }
          }
        };
        final Map<String, dynamic> androidPayload = {
          "notification": {
            "sound": sound ? "default" : null,
          }
        };

        payload["message"]["apns"] = apnsPayload;
        payload["message"]["android"] = androidPayload;

        if (customData.isNotEmpty) {
          // FCM v1 custom data must be flat String-to-String map
          final Map<String, String> stringData = {};
          customData.forEach((key, val) {
            stringData[key] = val.toString();
          });
          payload["message"]["data"] = stringData;
        }
      } else {
        if (serverKey == null) {
          throw Exception("FCM Legacy Server Key is required");
        }
        url = "https://fcm.googleapis.com/fcm/send";
        headers["Authorization"] = "key=$serverKey";

        // Build FCM Legacy body
        payload["to"] = registrationToken;
        payload["notification"] = {
          "title": title,
          "body": body,
          "sound": sound ? "default" : null,
          "badge": badge,
        };
        if (customData.isNotEmpty) {
          payload["data"] = customData;
        }
      }

      final payloadJson = json.encode(payload);

      // Construct request log for display
      final safeHeaders = Map<String, String>.from(headers);
      if (safeHeaders.containsKey("Authorization")) {
        safeHeaders["Authorization"] = isV1 ? "Bearer <OAUTH2_ACCESS_TOKEN>" : "key=<SERVER_KEY>";
      }
      final visualCurl = StringBuffer("curl -i -X POST \\\n");
      safeHeaders.forEach((key, val) {
        visualCurl.write("  -H \"$key: $val\" \\\n");
      });
      visualCurl.write("  -d '$payloadJson' \\\n");
      visualCurl.write("  \"$url\"");

      final response = await http.post(
        Uri.parse(url),
        headers: headers,
        body: payloadJson,
      );

      final success = response.statusCode == 200 &&
          (isV1 || !_hasLegacyFcmError(response.body));

      return PushResult(
        statusCode: response.statusCode,
        success: success,
        requestLog: visualCurl.toString(),
        responseBody: response.body,
      );
    } catch (e) {
      return PushResult(
        statusCode: -1,
        success: false,
        requestLog: "Failed to construct FCM request.",
        responseBody: e.toString(),
      );
    }
  }

  static bool _hasLegacyFcmError(String body) {
    try {
      final data = json.decode(body);
      if (data is Map && data.containsKey('failure') && data['failure'] > 0) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  static int _parseCurlStatusCode(String stdout) {
    try {
      final lines = stdout.split('\n');
      if (lines.isNotEmpty) {
        final parts = lines[0].split(' ');
        if (parts.length > 1) {
          return int.parse(parts[1]);
        }
      }
    } catch (_) {}
    return 200;
  }

  static bool _isCurlSuccess(String stdout) {
    final code = _parseCurlStatusCode(stdout);
    if (code == 200) {
      // APNs returns HTTP 200 for successful push
      return true;
    }
    return false;
  }
}

class PushResult {
  final int statusCode;
  final bool success;
  final String requestLog;
  final String responseBody;

  PushResult({
    required this.statusCode,
    required this.success,
    required this.requestLog,
    required this.responseBody,
  });
}
