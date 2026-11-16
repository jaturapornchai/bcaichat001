import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// คำขอที่ถูกจับไว้ เพื่อให้ test ตรวจ URL / body ได้
class FakeRequest {
  FakeRequest(this.method, this.uri, this.body);
  final String method;
  final Uri uri;
  final String body;
}

/// ตอบกลับ: (สถานะ, JSON) — คืน null = 404
typedef FakeRoute = (int, Object?)? Function(FakeRequest req);

/// ครอบ `dart:io` HttpClient ให้ `package:http` ใน ApiService คุยกับ route จำลอง
/// (ใช้แทนหลังบ้านใน widget test; ปิดด้วย `HttpOverrides.global = null`)
class FakeHttpOverrides extends HttpOverrides {
  FakeHttpOverrides(this.route);
  final FakeRoute route;
  final List<FakeRequest> requests = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeClient(route, requests);
}

class _FakeClient implements HttpClient {
  _FakeClient(this.route, this.log);
  final FakeRoute route;
  final List<FakeRequest> log;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(method, url, route, log);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.method, this.uri, this.route, this.log);
  @override
  final String method;
  @override
  final Uri uri;
  final FakeRoute route;
  final List<FakeRequest> log;

  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  final HttpHeaders headers = _FakeHeaders();
  final BytesBuilder _buffer = BytesBuilder();

  @override
  void add(List<int> data) => _buffer.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _buffer.add(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    final req = FakeRequest(method, uri, utf8.decode(_buffer.takeBytes()));
    log.add(req);
    final hit = route(req);
    return _FakeResponse(hit?.$1 ?? 404, jsonEncode(hit?.$2 ?? const {}));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    values.forEach((k, v) => action(k, [v]));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, String body) : _bytes = utf8.encode(body);

  @override
  final int statusCode;
  final List<int> _bytes;

  @override
  int get contentLength => _bytes.length;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpHeaders get headers => _FakeHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([_bytes]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
