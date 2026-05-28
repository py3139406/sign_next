import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'vault_service.dart';

class ClientService {
  String? _serverUrl;

  void setServerUrl(String url) {
    if (url.endsWith('/')) {
      _serverUrl = url.substring(0, url.length - 1);
    } else {
      _serverUrl = url;
    }
  }

  String? get serverUrl => _serverUrl;

  /// Fetches signing profiles from the Desktop Server.
  Future<List<SigningProfile>> fetchProfiles() async {
    if (_serverUrl == null) throw Exception('No server URL configured.');
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$_serverUrl/api/profiles'));
      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw Exception('Server error (${response.statusCode}): $body');
      }
      final body = await response.transform(utf8.decoder).join();
      final List<dynamic> jsonList = json.decode(body);
      return jsonList.map((item) => SigningProfile.fromJson(item)).toList();
    } finally {
      client.close();
    }
  }

  /// Sends file to server for signing and yields progress values (0.0 to 1.0).
  Stream<double> uploadAndSign({
    required String localInputPath,
    required String profileId,
    required String platform,
    required String appType,
    String? bundleId,
    required String localOutputPath,
  }) async* {
    if (_serverUrl == null) throw Exception('No server URL configured.');
    final client = HttpClient();
    
    try {
      final file = File(localInputPath);
      final length = await file.length();
      final uri = Uri.parse('$_serverUrl/api/sign');
      final request = await client.postUrl(uri);
      
      // Configure Headers
      request.headers.add('x-profile-id', profileId);
      request.headers.add('x-platform', platform);
      request.headers.add('x-app-type', appType);
      request.headers.add('x-file-name', p.basename(localInputPath));
      if (bundleId != null && bundleId.trim().isNotEmpty) {
        request.headers.add('x-bundle-id', bundleId);
      }
      request.headers.contentType = ContentType('application', 'octet-stream');
      request.contentLength = length;

      yield 0.05; // Connection started

      // Pipe bytes chunk by chunk to calculate progress during upload
      final fileStream = file.openRead();
      int bytesSent = 0;
      await for (final chunk in fileStream) {
        request.add(chunk);
        bytesSent += chunk.length;
        // Yield 0.05 to 0.50 (Upload phase)
        yield 0.05 + (bytesSent / length) * 0.45;
      }

      yield 0.55; // Upload complete, server processing
      
      final response = await request.close();
      yield 0.65; // Server finished, download beginning

      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw Exception('Signing server error (${response.statusCode}): $body');
      }

      final responseLength = response.contentLength;
      final outputFile = File(localOutputPath);
      
      // Delete old output file if exists
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      await outputFile.create(recursive: true);
      
      final sink = outputFile.openWrite();
      int bytesReceived = 0;
      
      await for (final chunk in response) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (responseLength > 0) {
          // Yield 0.65 to 0.95 (Download phase)
          yield 0.65 + (bytesReceived / responseLength) * 0.30;
        } else {
          yield 0.80; // Fallback if length unknown
        }
      }
      
      await sink.close();
      yield 1.0; // Completed
    } finally {
      client.close();
    }
  }

  /// Sends file to server for unsigning and yields progress values (0.0 to 1.0).
  Stream<double> uploadAndUnsign({
    required String localInputPath,
    required String platform,
    required String localOutputPath,
  }) async* {
    if (_serverUrl == null) throw Exception('No server URL configured.');
    final client = HttpClient();
    
    try {
      final file = File(localInputPath);
      final length = await file.length();
      final uri = Uri.parse('$_serverUrl/api/unsign');
      final request = await client.postUrl(uri);

      request.headers.add('x-platform', platform);
      request.headers.add('x-file-name', p.basename(localInputPath));
      request.headers.contentType = ContentType('application', 'octet-stream');
      request.contentLength = length;

      yield 0.05;

      final fileStream = file.openRead();
      int bytesSent = 0;
      await for (final chunk in fileStream) {
        request.add(chunk);
        bytesSent += chunk.length;
        yield 0.05 + (bytesSent / length) * 0.45;
      }

      yield 0.55;

      final response = await request.close();
      yield 0.65;

      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw Exception('Unsigning server error (${response.statusCode}): $body');
      }

      final responseLength = response.contentLength;
      final outputFile = File(localOutputPath);
      
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      await outputFile.create(recursive: true);

      final sink = outputFile.openWrite();
      int bytesReceived = 0;
      
      await for (final chunk in response) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (responseLength > 0) {
          yield 0.65 + (bytesReceived / responseLength) * 0.30;
        } else {
          yield 0.80;
        }
      }

      await sink.close();
      yield 1.0;
    } finally {
      client.close();
    }
  }
}
