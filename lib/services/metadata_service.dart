import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

class AppMetadata {
  final String name;
  final String packageId;
  final String versionName;
  final String versionCode;

  AppMetadata({
    required this.name,
    required this.packageId,
    required this.versionName,
    required this.versionCode,
  });

  Map<String, String> toJson() => {
    'name': name,
    'packageId': packageId,
    'versionName': versionName,
    'versionCode': versionCode,
  };

  factory AppMetadata.fromJson(Map<String, dynamic> json) => AppMetadata(
    name: json['name'] ?? 'Unknown',
    packageId: json['packageId'] ?? 'Unknown',
    versionName: json['versionName'] ?? '1.0.0',
    versionCode: json['versionCode'] ?? '1',
  );
}

class MetadataService {
  /// Extracts metadata from an unzipped IPA directory.
  static Future<AppMetadata?> extractIpaMetadata(String ipaPath, String tempWorkspacePath) async {
    try {
      final payloadDir = Directory(p.join(tempWorkspacePath, 'Payload'));
      if (!await payloadDir.exists()) return null;

      final appDir = await payloadDir
          .list()
          .firstWhere((entity) => entity is Directory && entity.path.endsWith('.app'))
          .then((entity) => entity as Directory);

      final infoPlistPath = p.join(appDir.path, 'Info.plist');
      if (!await File(infoPlistPath).exists()) return null;

      // Extract details using plistbuddy
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

      return AppMetadata(
        name: appName.isNotEmpty ? appName : p.basenameWithoutExtension(ipaPath),
        packageId: bundleId,
        versionName: versionName,
        versionCode: versionCode,
      );
    } catch (_) {
      return null;
    }
  }

  static AppMetadata? parseFromFilename(String filename) {
    final nameWithoutExt = p.basenameWithoutExtension(filename);
    
    // Find version pattern like 11.31.733
    final verMatch = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(nameWithoutExt);
    String versionName = '1.0.0';
    String versionCode = '1';
    String appName = 'Businessnext';

    if (verMatch != null) {
      versionName = verMatch.group(1)!;
      // The version code is usually the next number after a dash, dot or underscore
      final afterVer = nameWithoutExt.substring(verMatch.end);
      final codeMatch = RegExp(r'[-_.](\d+)').firstMatch(afterVer);
      if (codeMatch != null) {
        versionCode = codeMatch.group(1)!;
      }
    }

    // App name is the first word/token before any dash or underscore
    final parts = nameWithoutExt.split(RegExp(r'[-_]'));
    if (parts.isNotEmpty && parts.first.isNotEmpty) {
      appName = parts.first;
      appName = appName[0].toUpperCase() + appName.substring(1);
    }

    return AppMetadata(
      name: appName,
      packageId: 'com.myuat.crmnext',
      versionName: versionName,
      versionCode: versionCode,
    );
  }

  /// Extracts metadata from an APK.
  static Future<AppMetadata?> extractApkMetadata(String apkPath) async {
    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('apk_meta_');
      final manifestFile = File(p.join(tempDir.path, 'AndroidManifest.xml'));

      // Extract AndroidManifest.xml from APK using unzip
      final unzipResult = await Process.run(
        'unzip',
        ['-p', apkPath, 'AndroidManifest.xml'],
        stdoutEncoding: null,
      );
      if (unzipResult.exitCode != 0) throw Exception('unzip failed');

      await manifestFile.writeAsBytes(unzipResult.stdout as List<int>);
      final bytes = await manifestFile.readAsBytes();

      final parser = BinaryXmlParser(bytes);
      var meta = parser.parse(p.basenameWithoutExtension(apkPath));
      
      // If parsing fails or returns default/unknown values, trigger filename fallback
      if (meta == null || meta.packageId == 'Unknown' || meta.versionName == '1.0.0') {
        final filenameMeta = parseFromFilename(p.basename(apkPath));
        if (filenameMeta != null) {
          if (meta == null) {
            meta = filenameMeta;
          } else {
            meta = AppMetadata(
              name: filenameMeta.name,
              packageId: meta.packageId == 'Unknown' ? filenameMeta.packageId : meta.packageId,
              versionName: meta.versionName == '1.0.0' ? filenameMeta.versionName : meta.versionName,
              versionCode: meta.versionCode == '1' ? filenameMeta.versionCode : meta.versionCode,
            );
          }
        }
      }
      return meta;
    } catch (_) {
      return parseFromFilename(p.basename(apkPath));
    } finally {
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true).catchError((_) {});
      }
    }
  }
}

class BinaryXmlParser {
  final ByteData data;
  int offset = 0;
  List<String> stringPool = [];

  BinaryXmlParser(Uint8List bytes) : data = ByteData.sublistView(bytes);

  int readInt32() {
    final val = data.getInt32(offset, Endian.little);
    offset += 4;
    return val;
  }

  int readInt16() {
    final val = data.getInt16(offset, Endian.little);
    offset += 2;
    return val;
  }

  AppMetadata? parse(String fallbackName) {
    if (data.lengthInBytes < 8) return null;
    final magic = readInt32();
    if (magic != 0x00080003) return null; // AXML magic number
    readInt32(); // file size

    String packageId = 'Unknown';
    String versionName = '1.0.0';
    String versionCode = '1';

    while (offset < data.lengthInBytes) {
      final chunkType = readInt32();
      final chunkSize = readInt32();
      final chunkStart = offset - 8;

      if (chunkType == 0x00010001) {
        // String Pool Chunk
        final stringCount = readInt32();
        readInt32(); // style count
        final flags = readInt32();
        final stringStart = readInt32();
        readInt32(); // style start

        final isUtf8 = (flags & 0x100) != 0;

        final offsets = <int>[];
        for (var i = 0; i < stringCount; i++) {
          offsets.add(readInt32());
        }

        final stringDataStart = chunkStart + stringStart;
        for (var i = 0; i < stringCount; i++) {
          final strOffset = stringDataStart + offsets[i];
          if (isUtf8) {
            // Read UTF-8 string
            var len = data.getUint8(strOffset);
            var headerOffset = 1;
            if ((len & 0x80) != 0) {
              len = ((len & 0x7F) << 8) | data.getUint8(strOffset + 1);
              headerOffset = 2;
            }
            var bytesLen = data.getUint8(strOffset + headerOffset);
            var byteHeaderLen = 1;
            if ((bytesLen & 0x80) != 0) {
              bytesLen = ((bytesLen & 0x7F) << 8) | data.getUint8(strOffset + headerOffset + 1);
              byteHeaderLen = 2;
            }
            final finalOffset = strOffset + headerOffset + byteHeaderLen;
            final bytes = Uint8List.view(data.buffer, finalOffset, bytesLen);
            stringPool.add(utf8.decode(bytes, allowMalformed: true));
          } else {
            // Read UTF-16 string
            var len = data.getUint16(strOffset, Endian.little);
            var headerOffset = 2;
            if ((len & 0x8000) != 0) {
              len = ((len & 0x7FFF) << 16) | data.getUint16(strOffset + 2, Endian.little);
              headerOffset = 4;
            }
            final finalOffset = strOffset + headerOffset;
            final chars = <int>[];
            for (var j = 0; j < len; j++) {
              chars.add(data.getUint16(finalOffset + j * 2, Endian.little));
            }
            stringPool.add(String.fromCharCodes(chars));
          }
        }
      } else if (chunkType == 0x00100102) {
        // Start Element Node
        readInt32(); // line number
        readInt32(); // comment index
        readInt32(); // namespace index
        final nameIdx = readInt32();
        final attrStart = readInt16();
        final attrSize = readInt16();
        final attrCount = readInt16();
        readInt16(); // id index
        readInt16(); // class index
        readInt16(); // style index

        final tagName = nameIdx >= 0 && nameIdx < stringPool.length ? stringPool[nameIdx] : '';

        if (tagName == 'manifest') {
          offset = chunkStart + attrStart;
          for (var i = 0; i < attrCount; i++) {
            final attrOffset = offset;
            readInt32(); // namespace
            final attrNameIdx = readInt32();
            final rawValIdx = readInt32();
            readInt16(); // typed value size
            readInt16(); // typed value type
            final typedValData = readInt32(); // typed value data

            final attrName = attrNameIdx >= 0 && attrNameIdx < stringPool.length ? stringPool[attrNameIdx] : '';
            if (attrName == 'package') {
              packageId = rawValIdx >= 0 && rawValIdx < stringPool.length ? stringPool[rawValIdx] : 'Unknown';
            } else if (attrName == 'versionName') {
              versionName = rawValIdx >= 0 && rawValIdx < stringPool.length ? stringPool[rawValIdx] : '1.0.0';
            } else if (attrName == 'versionCode') {
              if (rawValIdx >= 0 && rawValIdx < stringPool.length) {
                versionCode = stringPool[rawValIdx];
              } else {
                versionCode = typedValData.toString();
              }
            }
            offset = attrOffset + attrSize;
          }
          break;
        }
      }
      offset = chunkStart + chunkSize;
    }

    return AppMetadata(
      name: fallbackName,
      packageId: packageId,
      versionName: versionName,
      versionCode: versionCode,
    );
  }
}
