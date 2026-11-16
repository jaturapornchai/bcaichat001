import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/map_preview.dart';

/// หน้าเต็มจอ "แชร์ตำแหน่ง" เลือกตำแหน่งบนแผนที่แล้วส่ง — เป็นหน้าปกติ (route) ไม่ใช่ popup
///
/// คืนค่าพิกัดที่เลือกผ่าน `Navigator.pop(context, (lat: ..., lng: ...))`
class LocationPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const LocationPickerScreen({super.key, this.initialLat, this.initialLng});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  double? _lat;
  double? _lng;

  bool get _hasPin => BcMapPreview.isValidLatLng(_lat, _lng);

  @override
  void initState() {
    super.initState();
    if (BcMapPreview.isValidLatLng(widget.initialLat, widget.initialLng)) {
      _lat = widget.initialLat;
      _lng = widget.initialLng;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('loc-fullmap-view'),
      backgroundColor: AppTheme.surfaceBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: BcMapPreview(
                key: const Key('loc-fullmap-map'),
                interactive: true,
                autoLocate: true,
                height: null,
                lat: _lat,
                lng: _lng,
                onPick: (lat, lng) => setState(() {
                  _lat = lat;
                  _lng = lng;
                }),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SizedBox(
      height: 46,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            key: const Key('loc-fullmap-close-btn'),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            color: AppTheme.slateDark,
            tooltip: 'ย้อนกลับ',
          ),
          const Text(
            'แชร์ตำแหน่ง',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.slateDark,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              _hasPin
                  ? 'พิกัด: ${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}'
                  : 'แตะบนแผนที่เพื่อปักหมุด',
              key: const Key('loc-fullmap-coords'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: AppTheme.slateDark,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('loc-fullmap-confirm-btn'),
            onPressed: _hasPin
                ? () => Navigator.of(context).pop((lat: _lat!, lng: _lng!))
                : null,
            icon: const Icon(Icons.check_rounded, size: 16),
            label: const Text('ส่งตำแหน่งนี้'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}
