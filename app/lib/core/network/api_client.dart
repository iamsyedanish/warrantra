import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../errors/failure.dart';
import '../storage/secure_store.dart';

typedef Json = Map<String, dynamic>;

/// Thin HTTP client for the Warrantra API.
/// - attaches the access token, refreshes once on 401 and retries;
/// - unwraps `{ data: ... }` envelopes;
/// - maps every error to a [Failure] with the API's stable error code.
class ApiClient {
  ApiClient(this._store, {Dio? dio, this.onSessionExpired})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: '${AppConfig.apiBaseUrl}/v1',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 45),
              headers: {'Accept': 'application/json'},
            )) {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.extra['auth'] != false) {
        final token = await _store.accessToken();
        if (token != null) options.headers['Authorization'] = 'Bearer $token';
      }
      handler.next(options);
    }));
  }

  final Dio _dio;
  final SecureStore _store;
  void Function()? onSessionExpired;
  Completer<bool>? _refreshing;
  static const _uuid = Uuid();

  /// New idempotency key for create calls; reuse the same key when retrying.
  static String newIdempotencyKey() => _uuid.v4();

  Future<T> get<T>(String path, {Map<String, dynamic>? query, bool auth = true}) =>
      _send<T>(() => _dio.get(path, queryParameters: query, options: Options(extra: {'auth': auth})));

  Future<T> post<T>(String path, {Object? body, String? idempotencyKey, bool auth = true}) => _send<T>(() => _dio.post(path,
      data: body ?? const <String, dynamic>{},
      options: Options(extra: {'auth': auth}, headers: {if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey})));

  Future<T> patch<T>(String path, {Object? body, int? ifMatchVersion}) => _send<T>(() => _dio.patch(path,
      data: body, options: Options(headers: {if (ifMatchVersion != null) 'If-Match': '"$ifMatchVersion"'})));

  Future<T> put<T>(String path, {Object? body}) => _send<T>(() => _dio.put(path, data: body));

  Future<T> delete<T>(String path, {Map<String, dynamic>? query}) => _send<T>(() => _dio.delete(path, queryParameters: query));

  /// Upload raw bytes to a Supabase signed upload URL (no API token is sent there).
  Future<void> uploadToSignedUrl(String signedUrl, List<int> bytes, String mime) async {
    try {
      await Dio().put(signedUrl,
          data: Stream.fromIterable([bytes]),
          options: Options(headers: {
            Headers.contentTypeHeader: mime,
            Headers.contentLengthHeader: bytes.length,
            'x-upsert': 'true',
          }));
    } on DioException catch (e) {
      throw _toFailure(e);
    }
  }

  Future<T> _send<T>(Future<Response<dynamic>> Function() call, {bool retried = false}) async {
    try {
      final res = await call();
      return _unwrap<T>(res.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && !retried && e.requestOptions.extra['auth'] != false) {
        if (await _refresh()) return _send<T>(call, retried: true);
        onSessionExpired?.call();
      }
      throw _toFailure(e);
    }
  }

  T _unwrap<T>(dynamic body) {
    if (body is Map<String, dynamic> && body.containsKey('data')) return body['data'] as T;
    return body as T;
  }

  /// Single-flight token refresh shared by concurrent requests.
  Future<bool> _refresh() async {
    if (_refreshing != null) return _refreshing!.future;
    final c = _refreshing = Completer<bool>();
    try {
      final refresh = await _store.refreshToken();
      if (refresh == null) {
        c.complete(false);
      } else {
        final res = await _dio.post('/auth/refresh', data: {'refresh_token': refresh}, options: Options(extra: {'auth': false}));
        final session = (res.data['data'] as Json)['session'] as Json;
        await _store.saveTokens(access: session['access_token'] as String, refresh: session['refresh_token'] as String);
        c.complete(true);
      }
    } catch (_) {
      await _store.clearTokens();
      c.complete(false);
    } finally {
      _refreshing = null;
    }
    return c.future;
  }

  Failure _toFailure(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return Failure.offline;
    }
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      return Failure(
        (err['code'] ?? 'error').toString(),
        (err['message'] ?? 'Something went wrong').toString(),
        status: e.response?.statusCode,
        details: err['details'] is Map ? Map<String, dynamic>.from(err['details'] as Map) : null,
      );
    }
    return Failure('http_${e.response?.statusCode ?? 0}', 'Something went wrong. Please try again.', status: e.response?.statusCode);
  }
}

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(ref.watch(secureStoreProvider)));
