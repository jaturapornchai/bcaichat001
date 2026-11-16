import 'dart:async';

import 'package:bcaichat_app/screens/location_picker_screen.dart';
import 'package:bcaichat_app/widgets/map_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 300, child: child)),
);

/// ตัวจำลองบริการตำแหน่งของเครื่อง (ไม่แตะ GPS จริง)
class _FakeGeolocator extends GeolocatorPlatform {
  _FakeGeolocator({
    required this.position,
    this.permission = LocationPermission.whileInUse,
  });

  final Future<Position> position;
  final LocationPermission permission;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async => permission;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      position;
}

Position _positionAt(double lat, double lng) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.utc(2026),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  group('เปิดหน้าแชร์ตำแหน่ง: ไปตำแหน่งของผู้ใช้เอง', () {
    late GeolocatorPlatform original;
    setUp(() => original = GeolocatorPlatform.instance);
    tearDown(() => GeolocatorPlatform.instance = original);

    String? coordsText(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const Key('loc-fullmap-coords')))
        .data;

    testWidgets('จับตำแหน่งได้: ปักหมุดและเลื่อนแผนที่ไปเองโดยไม่ต้องแตะ', (
      tester,
    ) async {
      GeolocatorPlatform.instance = _FakeGeolocator(
        position: Future.value(_positionAt(18.7883, 98.9853)),
      );
      await tester.pumpWidget(const MaterialApp(home: LocationPickerScreen()));
      await tester.pumpAndSettle();

      expect(coordsText(tester), 'พิกัด: 18.78830, 98.98530');
      expect(find.byKey(const Key('map-preview-pin')), findsOneWidget);
      final confirm = find.byKey(const Key('loc-fullmap-confirm-btn'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      final camera = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!
          .camera;
      expect(camera.center.latitude, closeTo(18.7883, 0.0001));
      expect(camera.center.longitude, closeTo(98.9853, 0.0001));
      expect(camera.zoom, greaterThanOrEqualTo(15));
    });

    testWidgets('ผู้ใช้แตะปักหมุดเองก่อนได้ตำแหน่ง: ไม่ทับหมุดของผู้ใช้', (
      tester,
    ) async {
      final gps = Completer<Position>();
      GeolocatorPlatform.instance = _FakeGeolocator(position: gps.future);
      await tester.pumpWidget(const MaterialApp(home: LocationPickerScreen()));
      await tester.pump();
      await tester.pump();
      expect(find.text('กำลังจับพิกัด...'), findsOneWidget);

      await tester.tap(find.byType(FlutterMap));
      await tester.pump(const Duration(milliseconds: 400));
      final picked = coordsText(tester);
      expect(picked, startsWith('พิกัด: 13.'));

      gps.complete(_positionAt(18.7883, 98.9853));
      await tester.pumpAndSettle();
      expect(coordsText(tester), picked);
      expect(find.text('ตำแหน่งฉัน'), findsOneWidget);
    });

    testWidgets('ไม่อนุญาตตำแหน่ง: อยู่ที่มุมมองเดิม บอกเหตุผล และยังแตะปักหมุดได้', (
      tester,
    ) async {
      GeolocatorPlatform.instance = _FakeGeolocator(
        // ไม่อนุญาต = ไม่ถูกเรียก จึงใช้ future ที่ไม่มีวันจบ
        position: Completer<Position>().future,
        permission: LocationPermission.denied,
      );
      await tester.pumpWidget(const MaterialApp(home: LocationPickerScreen()));
      await tester.pumpAndSettle();

      expect(coordsText(tester), 'แตะบนแผนที่เพื่อปักหมุด');
      expect(find.text('ยังไม่ได้อนุญาตให้แอปใช้ตำแหน่ง'), findsOneWidget);
      expect(find.byKey(const Key('map-preview-pin')), findsNothing);

      await tester.tap(find.byType(FlutterMap));
      await tester.pump(const Duration(milliseconds: 400));
      expect(coordsText(tester), startsWith('พิกัด: '));
      expect(find.text('ยังไม่ได้อนุญาตให้แอปใช้ตำแหน่ง'), findsNothing);
    });
  });

  test('isValidLatLng ตรวจช่วงพิกัด', () {
    expect(BcMapPreview.isValidLatLng(13.7563, 100.5018), isTrue);
    expect(BcMapPreview.isValidLatLng(null, 100), isFalse);
    expect(BcMapPreview.isValidLatLng(91, 100), isFalse);
    expect(BcMapPreview.isValidLatLng(13, 181), isFalse);
    expect(BcMapPreview.isValidLatLng(double.nan, 100), isFalse);
  });

  testWidgets('มีพิกัด: แสดงหมุด เครดิตแผนที่ และใช้ไทล์ OpenStreetMap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const BcMapPreview(lat: 13.7563, lng: 100.5018)),
    );
    await tester.pump();
    expect(find.byKey(const Key('map-preview-pin')), findsOneWidget);
    expect(find.text('© OpenStreetMap'), findsOneWidget);
    final layer = tester.widget<TileLayer>(find.byType(TileLayer));
    expect(layer.urlTemplate, BcMapPreview.tileUrl);
  });

  testWidgets('ยังไม่มีพิกัด: ไม่มีหมุด แตะแผนที่แล้วได้พิกัดกลับมา', (
    tester,
  ) async {
    double? pickedLat;
    await tester.pumpWidget(
      _host(
        BcMapPreview(
          interactive: true,
          height: 200,
          onPick: (lat, lng) => pickedLat = lat,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('map-preview-pin')), findsNothing);
    await tester.tap(find.byType(FlutterMap));
    await tester.pump(const Duration(milliseconds: 400));
    expect(pickedLat, isNotNull);
    expect(pickedLat, closeTo(13.7563, 0.2));
  });

  testWidgets('หน้าเลือกตำแหน่งเต็มจอ: แตะแผนที่แล้วกดยืนยัน คืนพิกัดกลับ', (
    tester,
  ) async {
    ({double lat, double lng})? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context)
                  .push<({double lat, double lng})>(
                    MaterialPageRoute(
                      builder: (_) => const LocationPickerScreen(),
                    ),
                  );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('แตะบนแผนที่เพื่อปักหมุด'), findsOneWidget);
    final confirm = find.byKey(const Key('loc-fullmap-confirm-btn'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byType(FlutterMap));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('map-preview-pin')), findsOneWidget);
    expect(find.textContaining('พิกัด: '), findsOneWidget);

    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.lat, closeTo(13.7563, 0.3));
  });

  testWidgets(
    'ปุ่มสลับชั้นแผนที่: เปลี่ยนเป็นภาพดาวเทียมและเครดิตตามแหล่งภาพ',
    (tester) async {
      await tester.pumpWidget(
        _host(
          BcMapPreview(
            interactive: true,
            height: 260,
            lat: 13.7563,
            lng: 100.5018,
            onPick: (_, _) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('map-gps-btn')), findsOneWidget);
      await tester.tap(find.byKey(const Key('map-layer-btn')));
      await tester.pump();
      final layer = tester.widget<TileLayer>(find.byType(TileLayer));
      expect(layer.urlTemplate, BcMapPreview.satelliteTileUrl);
      expect(layer.maxNativeZoom, BcMapPreview.satelliteMaxNativeZoom);
      // ซูมถูกจำกัดไว้ที่ระดับที่ภาพดาวเทียมยังชัด (หมุดเดิมอยู่ที่ซูม 15 ต้องถอยลงมา)
      final satMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(satMap.options.maxZoom, BcMapPreview.satelliteMaxNativeZoom);
      expect(
        satMap.mapController!.camera.zoom,
        BcMapPreview.satelliteMaxNativeZoom,
      );
      expect(find.text(BcMapPreview.satelliteCredit), findsOneWidget);
      await tester.tap(find.byKey(const Key('map-layer-btn')));
      await tester.pump();
      expect(find.text(BcMapPreview.mapCredit), findsOneWidget);
    },
  );

  testWidgets('กดที่หมุดแล้วลาก: ได้พิกัดใหม่ตามทิศที่ลาก', (tester) async {
    double lat = 13.7563, lng = 100.5018;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => BcMapPreview(
            interactive: true,
            height: 260,
            lat: lat,
            lng: lng,
            onPick: (a, b) => setState(() {
              lat = a;
              lng = b;
            }),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('map-preview-pin')),
      const Offset(40, 30),
    );
    await tester.pump();
    expect(lng, greaterThan(100.5018), reason: 'ลากไปทางขวา = ลองจิจูดเพิ่ม');
    expect(lat, lessThan(13.7563), reason: 'ลากลงล่าง = ละติจูดลด');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('map-preview-pin')), findsOneWidget);
  });

  testWidgets('การ์ดในแชท (ไม่ interactive): ไม่มีปุ่มสลับชั้นและปุ่ม GPS', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const BcMapPreview(lat: 13.7563, lng: 100.5018)),
    );
    await tester.pump();
    expect(find.byKey(const Key('map-layer-btn')), findsNothing);
    expect(find.byKey(const Key('map-gps-btn')), findsNothing);
  });
}
