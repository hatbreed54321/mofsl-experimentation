import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/sdk_config.dart';
import '../utils/logger.dart';
import 'config_cache.dart';

/// Fetches [SdkConfig] from the platform config server via HTTP.
///
/// Protocol details (per CONFIG_SERVER_API.md):
/// - Auth:    `X-API-Key` header on every request.
/// - Compression: `Accept-Encoding: gzip` on every request.
/// - ETag:    `If-None-Match: "<etag>"` when a cached ETag is available.
/// - Timeout: 15 seconds total (covers connection + read; package:http does
///   not distinguish between them on all platforms without dart:io).
///
/// This class **never throws**. Every failure path returns a cached config or
/// null, so the host app always gets a usable result.
class ConfigLoader {
  static const Duration _requestTimeout = Duration(seconds: 15);

  final String _configUrl;
  final String _apiKey;
  final String _clientCode;
  final Map<String, dynamic>? _attributes;
  final http.Client _httpClient;
  final ConfigCache _cache;
  final Logger _logger;

  ConfigLoader({
    required String configUrl,
    required String apiKey,
    required String clientCode,
    Map<String, dynamic>? attributes,
    required http.Client httpClient,
    required ConfigCache cache,
    required Logger logger,
  })  : _configUrl = configUrl,
        _apiKey = apiKey,
        _clientCode = clientCode,
        _attributes = attributes,
        _httpClient = httpClient,
        _cache = cache,
        _logger = logger;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Fetch the latest config from the server.
  ///
  /// Returns:
  /// - A freshly parsed [SdkConfig] on HTTP 200.
  /// - The cached [SdkConfig] on HTTP 304, 4xx, 5xx, or any network error.
  /// - `null` if the server fails **and** there is no cached config.
  Future<SdkConfig?> fetch() async {
    final uri = _buildUri();
    final headers = _buildHeaders();

    _logger.debug('Fetching config: GET $uri');

    try {
      final response = await _httpClient
          .get(uri, headers: headers)
          .timeout(_requestTimeout);
      return _handleResponse(response);
    } on TimeoutException {
      _logger.warning('Config fetch timed out — using cached config');
      return _cache.load();
    } catch (e, stack) {
      _logger.error('Config fetch failed', e, stack);
      return _cache.load();
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Uri _buildUri() {
    final base = Uri.parse(_configUrl);
    final params = <String, String>{'clientCode': _clientCode};
    final attrs = _attributes;
    if (attrs != null && attrs.isNotEmpty) {
      // URL-encoded JSON object — Uri.replace handles percent-encoding.
      params['attributes'] = jsonEncode(attrs);
    }
    return base.replace(queryParameters: params);
  }

  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'X-API-Key': _apiKey,
      'Accept-Encoding': 'gzip',
    };
    final etag = _cache.etag;
    if (etag != null) {
      // ETag must be quoted per HTTP spec (RFC 7232).
      headers['If-None-Match'] = '"$etag"';
    }
    return headers;
  }

  SdkConfig? _handleResponse(http.Response response) {
    _logger.debug(
      'Config response: ${response.statusCode} (${response.body.length} bytes)',
    );

    switch (response.statusCode) {
      case 200:
        return _parse200(response);
      case 304:
        _logger.debug('Config not modified (304) — using cached config');
        return _cache.load();
      case 401:
        _logger.warning('Config fetch unauthorized (401) — verify API key');
        return _cache.load();
      case 400:
        _logger.warning('Config fetch bad request (400): ${response.body}');
        return _cache.load();
      default:
        _logger.warning(
          'Config fetch error (${response.statusCode}) — using cached config',
        );
        return _cache.load();
    }
  }

  SdkConfig? _parse200(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        _logger.warning(
          'Config body is not a JSON object — using cached config',
        );
        return _cache.load();
      }
      final config = SdkConfig.fromJson(decoded);
      final version = decoded['version'] as String? ?? '';
      // Cache update is best-effort; do not block the caller.
      unawaited(_cache.save(config, version));
      _logger.debug('Config cached (version: $version)');
      return config;
    } catch (e, stack) {
      _logger.error('Failed to parse config response', e, stack);
      return _cache.load();
    }
  }
}
