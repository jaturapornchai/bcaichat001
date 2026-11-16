import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
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

  /// true = เลื่อน/ซูมได้ แตะเพื่อย้ายหมุด กดที่หมุดแล้วลากได้
  /// สลับภาพดาวเทียม และจับตำแหน่งปัจจุบันจาก GPS ได้
  final bool interactive;
  final void Function(double lat, double lng)? onPick;

  /// true = เปิดมายังไม่มีหมุด ให้จับตำแหน่งปัจจุบันเองหนึ่งครั้ง (ใช้คู่กับ interactive)
  final bool autoLocate;

  const BcMapPreview({
    super.key,
    this.lat,
    this.lng,
    this.height = 140,
    this.interactive = false,
    this.onPick,
    this.autoLocate = false,
  });

  static const tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// ภาพดาวเทียม Sentinel-2 cloudless ปี 2016 (CC BY 4.0, ไม่ต้องมี API key)
  /// ที่มา: https://cloudless.eox.at/documentation/faq — ลำดับไทล์เป็น {z}/{y}/{x}
  static const satelliteTileUrl =
      'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg';
  static const satelliteMaxNativeZoom = 14;
  static const mapCredit = '© OpenStreetMap';
  static const satelliteCredit =
      'EOxCloudless https://cloudless.eox.at by EOX IT Services GmbH '
      '(Contains modified Copernicus Sentinel data 2016)';
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

class _BcMapPreviewState extends State<BcMapPreview>
    with SingleTickerProviderStateMixin {
  static const double _pinZoom = 15;
  static const double _mapMaxZoom = 19;
  static const double _pinBox = 44;

  /// ระยะจากขอบแผนที่ที่เริ่มเลื่อนแผนที่ตามนิ้วระหว่างลากหมุด
  static const double _edgeZone = 44;
  static const double _edgeStep = 9;

  final MapController _controller = MapController();
  final GlobalKey _mapBoxKey = GlobalKey();
  late final AnimationController _moveAnim;

  bool _mapReady = false;
  bool _satellite = false;
  bool _dragging = false;
  bool _gpsLoading = false;
  String? _notice;

  /// ตำแหน่งหมุดที่วาดอยู่จริง (ต่างจาก widget.lat/lng ระหว่าง animation และระหว่างลาก)
  LatLng? _shownPin;
  LatLng? _moveFromPin;
  LatLng? _moveToPin;
  LatLng? _moveFromCenter;
  double _moveFromZoom = _pinZoom;

  /// ภาพดาวเทียมชัดถึงซูม 14 จึงไม่ให้ซูมลึกกว่านั้น (ซูมลึกกว่าเป็นภาพขยายที่เบลอ)
  double get _maxZoom => _satellite
      ? BcMapPreview.satelliteMaxNativeZoom.toDouble()
      : _mapMaxZoom;

  double _pinZoomFrom(double current) =>
      math.min(math.max(current, _pinZoom), _maxZoom);

  void _toggleLayer() {
    setState(() => _satellite = !_satellite);
    if (!_mapReady) return;
    final camera = _controller.camera;
    if (camera.zoom > _maxZoom) _controller.move(camera.center, _maxZoom);
  }

  Offset _grabDelta = Offset.zero;
  Offset _fingerLocal = Offset.zero;
  Timer? _edgeTimer;

  LatLng? get _pin => BcMapPreview.isValidLatLng(widget.lat, widget.lng)
      ? LatLng(widget.lat!, widget.lng!)
      : null;

  @override
  void initState() {
    super.initState();
    // สร้างตรงนี้ (ไม่ lazy) เพราะ dispose() ห้ามเป็นจุดแรกที่สร้าง ticker
    _moveAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(_onMoveTick);
    _shownPin = _pin;
    if (widget.interactive && widget.autoLocate && _pin == null) {
      // รอเฟรมแรกก่อน เพราะ _useGps เรียก setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _useGps(auto: true);
      });
    }
  }

  @override
  void didUpdateWidget(BcMapPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lat == widget.lat && oldWidget.lng == widget.lng) return;
    final pin = _pin;
    final from = _shownPin;
    if (pin == null || from == null || !_mapReady) {
      _moveAnim.stop();
      _shownPin = pin;
      if (pin != null && _mapReady) {
        _controller.move(pin, _pinZoomFrom(_controller.camera.zoom));
      }
      return;
    }
    _moveFromPin = from;
    _moveToPin = pin;
    _moveFromCenter = _controller.camera.center;
    _moveFromZoom = _controller.camera.zoom;
    _moveAnim.forward(from: 0);
  }

  /// เลื่อนหมุดและกึ่งกลางแผนที่ไปยังตำแหน่งใหม่แบบนุ่มนวล
  void _onMoveTick() {
    final from = _moveFromPin, to = _moveToPin, center = _moveFromCenter;
    if (from == null || to == null || center == null) return;
    final t = Curves.easeOutCubic.transform(_moveAnim.value);
    final toZoom = _pinZoomFrom(_moveFromZoom);
    _controller.move(
      _lerp(center, to, t),
      _moveFromZoom + (toZoom - _moveFromZoom) * t,
    );
    setState(() => _shownPin = _lerp(from, to, t));
  }

  static LatLng _lerp(LatLng a, LatLng b, double t) => LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );

  @override
  void dispose() {
    _edgeTimer?.cancel();
    _moveAnim.dispose();
    _controller.dispose();
    super.dispose();
  }

  // ───── ลากหมุด ─────

  Offset _toMapLocal(Offset global) {
    final box = _mapBoxKey.currentContext!.findRenderObject()! as RenderBox;
    return box.globalToLocal(global);
  }

  void _onPinDragStart(DragStartDetails details) {
    final pin = _shownPin;
    if (pin == null) return;
    _moveAnim.stop();
    _fingerLocal = _toMapLocal(details.globalPosition);
    // จำระยะจากนิ้วถึงปลายหมุด เพื่อไม่ให้หมุดกระโดดไปอยู่ใต้นิ้วตอนเริ่มลาก
    _grabDelta = _controller.camera.latLngToScreenOffset(pin) - _fingerLocal;
    setState(() => _dragging = true);
  }

  void _onPinDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _fingerLocal = _toMapLocal(details.globalPosition);
    _movePinUnderFinger();
    final velocity = _edgeVelocity();
    if (velocity == Offset.zero) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
    } else {
      _edgeTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _onEdgeTick(),
      );
    }
  }

  void _onPinDragEnd() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    if (!_dragging) return;
    setState(() => _dragging = false);
    final pin = _shownPin;
    if (pin != null) widget.onPick?.call(pin.latitude, pin.longitude);
  }

  void _movePinUnderFinger() {
    final tip = _fingerLocal + _grabDelta;
    setState(() => _shownPin = _controller.camera.screenOffsetToLatLng(tip));
  }

  /// ทิศและความเร็วที่แผนที่ต้องเลื่อน เมื่อนิ้วเข้าใกล้ขอบระหว่างลากหมุด
  Offset _edgeVelocity() {
    final size = _mapBoxKey.currentContext?.size;
    if (size == null) return Offset.zero;
    double axis(double pos, double extent) {
      if (pos < _edgeZone) return -_edgeStep;
      if (pos > extent - _edgeZone) return _edgeStep;
      return 0;
    }

    return Offset(
      axis(_fingerLocal.dx, size.width),
      axis(_fingerLocal.dy, size.height),
    );
  }

  void _onEdgeTick() {
    final size = _mapBoxKey.currentContext?.size;
    final velocity = _edgeVelocity();
    if (!_dragging || size == null || velocity == Offset.zero) return;
    final camera = _controller.camera;
    final center = camera.screenOffsetToLatLng(
      size.center(Offset.zero) + velocity,
    );
    _controller.move(center, camera.zoom);
    _movePinUnderFinger();
  }

  // ───── ตำแหน่งปัจจุบันจาก GPS ─────

  /// auto = จับเองตอนเปิดแผนที่ (ไม่ใช่การกดปุ่ม) — ถ้าผู้ใช้ปักหมุดเองไปก่อนแล้ว ไม่ทับหมุดนั้น
  Future<void> _useGps({bool auto = false}) async {
    if (_gpsLoading) return;
    setState(() {
      _gpsLoading = true;
      _notice = null;
    });
    String? notice;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        notice = 'ยังไม่ได้เปิดบริการตำแหน่งของเครื่อง';
      } else {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          notice = 'ยังไม่ได้อนุญาตให้แอปใช้ตำแหน่ง';
        } else {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 12),
            ),
          );
          // ปิดหน้าแผนที่ไปก่อนได้ตำแหน่ง: ห้ามเรียก onPick ของหน้าที่ถูกทิ้งแล้ว
          if (!mounted) return;
          if (!(auto && _pin != null)) {
            widget.onPick?.call(pos.latitude, pos.longitude);
          }
        }
      }
    } catch (_) {
      notice = 'จับตำแหน่งปัจจุบันไม่ได้ แตะบนแผนที่เพื่อปักหมุดแทน';
    }
    if (!mounted) return;
    setState(() {
      _gpsLoading = false;
      _notice = auto && _pin != null ? null : notice;
    });
  }

  // ───── UI ─────

  @override
  Widget build(BuildContext context) {
    final pin = _shownPin;
    final map = FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: pin ?? BcMapPreview.defaultCenter,
        initialZoom: pin != null ? _pinZoom : 11,
        maxZoom: _maxZoom,
        onMapReady: () => _mapReady = true,
        onTap: (_, point) {
          setState(() => _notice = null);
          widget.onPick?.call(point.latitude, point.longitude);
        },
        interactionOptions: InteractionOptions(
          flags: widget.interactive
              ? InteractiveFlag.all & ~InteractiveFlag.rotate
              : InteractiveFlag.none,
        ),
      ),
      children: [
        TileLayer(
          key: ValueKey(_satellite),
          urlTemplate: _satellite
              ? BcMapPreview.satelliteTileUrl
              : BcMapPreview.tileUrl,
          userAgentPackageName: BcMapPreview.userAgentPackage,
          maxZoom: _maxZoom,
          maxNativeZoom: _maxZoom.toInt(),
        ),
        if (pin != null)
          MarkerLayer(
            markers: [
              Marker(
                point: pin,
                width: _pinBox,
                height: _pinBox,
                alignment: Alignment.topCenter,
                child: _buildPin(),
              ),
            ],
          ),
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: SizedBox(
        key: _mapBoxKey,
        height: widget.height,
        child: Stack(
          children: [
            // การ์ดในรายการแชท: ไม่รับนิ้ว เพื่อให้เลื่อนรายการข้อความได้ตามปกติ
            Positioned.fill(
              child: IgnorePointer(ignoring: !widget.interactive, child: map),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.bottomRight,
                child: _buildCredit(),
              ),
            ),
            if (widget.interactive)
              Positioned(top: 6, right: 6, child: _buildControls()),
            if (widget.interactive && _notice != null)
              Positioned(
                top: 6,
                left: 6,
                right: 112,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _buildNotice(_notice!),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPin() {
    final icon = Align(
      alignment: Alignment.bottomCenter,
      child: AnimatedScale(
        scale: _dragging ? 1.3 : 1,
        alignment: Alignment.bottomCenter,
        duration: const Duration(milliseconds: 150),
        child: Icon(
          Icons.location_on_rounded,
          key: const Key('map-preview-pin'),
          color: AppTheme.brandPrimary,
          size: 36,
          shadows: const [Shadow(color: Colors.white, blurRadius: 4)],
        ),
      ),
    );
    if (!widget.interactive) return icon;
    // ชนะการแย่ง gesture กับแผนที่ทันทีที่นิ้วแตะหมุด เพื่อให้ "กดแล้วลากได้เลย"
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _ImmediatePanRecognizer:
            GestureRecognizerFactoryWithHandlers<_ImmediatePanRecognizer>(
              _ImmediatePanRecognizer.new,
              (recognizer) => recognizer
                ..onStart = _onPinDragStart
                ..onUpdate = _onPinDragUpdate
                ..onEnd = ((_) => _onPinDragEnd())
                ..onCancel = _onPinDragEnd,
            ),
      },
      child: icon,
    );
  }

  Widget _buildControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _MapChipButton(
          key: const Key('map-layer-btn'),
          icon: _satellite ? Icons.map_rounded : Icons.satellite_alt_rounded,
          label: _satellite ? 'แผนที่' : 'ดาวเทียม',
          onTap: _toggleLayer,
        ),
        const SizedBox(height: 4),
        _MapChipButton(
          key: const Key('map-gps-btn'),
          icon: Icons.my_location_rounded,
          label: _gpsLoading ? 'กำลังจับพิกัด...' : 'ตำแหน่งฉัน',
          onTap: _gpsLoading ? null : _useGps,
        ),
      ],
    );
  }

  Widget _buildNotice(String text) {
    return Container(
      key: const Key('map-notice'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xF2FFFFFF),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: AppTheme.slateDark),
      ),
    );
  }

  Widget _buildCredit() {
    return GestureDetector(
      onTap: () => launchUrl(
        Uri.parse(
          _satellite
              ? 'https://cloudless.eox.at'
              : 'https://www.openstreetmap.org/copyright',
        ),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        key: const Key('map-preview-credit'),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        color: const Color(0xCCFFFFFF),
        child: Text(
          _satellite ? BcMapPreview.satelliteCredit : BcMapPreview.mapCredit,
          style: const TextStyle(fontSize: 9.5, color: AppTheme.slateBody),
        ),
      ),
    );
  }
}

/// ปุ่มเล็กบนแผนที่ (สลับชั้นแผนที่ / ตำแหน่งปัจจุบัน)
class _MapChipButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _MapChipButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        side: const BorderSide(color: AppTheme.hairline),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: AppTheme.brandPrimary),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.slateDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pan recognizer ที่รับ gesture ทันทีตั้งแต่นิ้วแตะ (ไม่รอระยะ slop) ใช้กับการลากหมุด
class _ImmediatePanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
