import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/print_route.dart';

class PrintApiService {
  static String normalizeBaseUrl(String raw) {
    var trimmed = raw.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  static Map<String, String> _headers(String apiKey) {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) return {};
    return {'X-API-Key': trimmed};
  }

  static Future<List<PrintRoute>> fetchRoutes({
    required String baseUrl,
    String apiKey = '',
  }) async {
    final uri = Uri.parse('${normalizeBaseUrl(baseUrl)}/api/routes');
    final resp = await http
        .get(uri, headers: _headers(apiKey))
        .timeout(const Duration(seconds: 8));

    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${_extractError(resp.body)}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final rawList = (data['routes'] as List<dynamic>?) ?? [];
    return rawList
        .map((item) => PrintRoute.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  static Future<String> uploadPdf({
    required String baseUrl,
    required String routeId,
    required Uint8List pdfBytes,
    required String fileName,
    String apiKey = '',
  }) async {
    final uri = Uri.parse('${normalizeBaseUrl(baseUrl)}/api/print');
    final req = http.MultipartRequest('POST', uri);
    req.headers.addAll(_headers(apiKey));
    req.fields['route'] = routeId;
    req.files.add(
      http.MultipartFile.fromBytes('file', pdfBytes, filename: fileName),
    );

    final streamed = await req.send().timeout(const Duration(seconds: 30));
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${_extractError(resp.body)}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['job_file'] ?? fileName).toString();
  }

  static Future<Uint8List> convertToPdf({
    required String baseUrl,
    required Uint8List fileBytes,
    required String fileName,
    String apiKey = '',
  }) async {
    final uri = Uri.parse('${normalizeBaseUrl(baseUrl)}/api/convert');
    final req = http.MultipartRequest('POST', uri);
    req.headers.addAll(_headers(apiKey));
    req.files.add(
      http.MultipartFile.fromBytes('file', fileBytes, filename: fileName),
    );

    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${_extractError(resp.body)}');
    }
    return resp.bodyBytes;
  }

  static String _extractError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] != null) {
        return decoded['error'].toString();
      }
    } catch (_) {}
    return body.isEmpty ? 'Lỗi không xác định' : body;
  }
}
