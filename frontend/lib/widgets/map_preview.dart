import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';

/// แผนที่ฟรีจาก OpenStreetMap (ไม่ต้องมี API key) ใช้ร่วมกันทั้งการ์ดตำแหน่งและถาดส่งตำแหน่ง
///
/// ต้องแสดงเครดิตบนแผนที่และส่งชื่อแอปเป็น User-Agent
/// ตาม https://operations.osmfoundation.org/policies/tiles/
class BcMapPreview extends StatefulWidget {
  /// พิกัดหมุด; null หรือไม่ถูกต้อง = ยังไม่มีหมุด
  final double? lat;
  final double? lng;

  /// ความสูงเป็นพิกเซล; null = เต็มพื้นที่ของกล่องแม่
  final double? height;

  /// true = เลื่อน/ซูมได้ และแตะเพื่อปักหมุด
  final bool interactive;
  final void Function(double lat, double lng)? onPick;

  const BcMapPreview({
    super.key,
    this.lat,
    this.lng,
    this.height = 140,
    this.interactive = false,
    this.onPick,
  });

  static const tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const userAgentPackage = 'com.bcaichat.app';
  static const defaultCenter = LatLng(13.7563, 100.5018); // กรุงเทพฯ

  static bool isValidLatLng(double? lat, double? lng) =>
      lat != null &&
      lng != null &&
      lat.isFinite &&
      lng.isFinite &&
      lat.abs() <= 90 &&
      lng.abs() <= 180;

  @override
  State<BcMapPreview> createState() => _BcMapPreviewState();
}

class _BcMapPreviewState extends State<BcMapPreview> {
  static const double _pinZoom = 15;

  final MapController _controller = MapController();
  bool _mapReady = false;

  LatLng? get _pin => BcMapPreview.isValidLatLng(widget.lat, widget.lng)
      ? LatLng(widget.lat!, widget.lng!)
      : null;

  @override
  void didUpdateWidget(BcMapPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pin = _pin;
    final moved = oldWidget.lat != widget.lat || oldWidget.lng != widget.lng;
    if (pin != null && moved && _mapReady) {
      _controller.move(pin, math.max(_controller.camera.zoom, _pinZoom));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pin = _pin;
    final map = FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: pin ?? BcMapPreview.defaultCenter,
        initialZoom: pin != null ? _pinZoom : 11,
        maxZoom: 19,
        onMapReady: () => _mapReady = true,
        onTap: (_, point) =>
            widget.onPick?.call(point.latitude, point.longitude),
        interactionOptions: InteractionOptions(
          flags: widget.interactive
              ? InteractiveFlag.all & ~InteractiveFlag.rotate
              : InteractiveFlag.none,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: BcMapPreview.tileUrl,
          userAgentPackageName: BcMapPreview.userAgentPackage,
          maxZoom: 19,
        ),
        if (pin != null)
          MarkerLayer(
            markers: [
              Marker(
                point: pin,
                width: 36,
                height: 36,
                alignment: Alignment.topCenter,
                child: Icon(
                  Icons.location_on_rounded,
                  key: const Key('map-preview-pin'),
                  color: AppTheme.brandPrimary,
                  size: 36,
                  shadows: const [Shadow(color: Colors.white, blurRadius: 4)],
                ),
              ),
            ],
          ),
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            // การ์ดในรายการแชท: ไม่รับนิ้ว เพื่อให้เลื่อนรายการข้อความได้ตามปกติ
            Positioned.fill(
              child: IgnorePointer(ignoring: !widget.interactive, child: map),
            ),
            Positioned(right: 0, bottom: 0, child: _buildCredit()),
          ],
        ),
      ),
    );
  }

  Widget _buildCredit() {
    return GestureDetector(
      onTap: () => launchUrl(
        Uri.parse('https://www.openstreetmap.org/copyright'),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        key: const Key('map-preview-credit'),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        color: const Color(0xCCFFFFFF),
        child: const Text(
          '© OpenStreetMap',
          style: TextStyle(fontSize: 9.5, color: AppTheme.slateBody),
        ),
      ),
    );
  }
}
