import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/app_theme.dart';
import 'main_shell.dart' show BcQrBox;

/// หน้าเต็มจอ "สแกน QR / QR ของฉัน" สลับไปมาได้ — เป็นหน้าปกติ (route) ไม่ใช่ popup
///
/// คืนค่ารหัส QR ที่สแกนหรือวางได้ผ่าน `Navigator.pop(context, code)`
/// ให้ผู้เรียกนำไปเพิ่มเพื่อนด้วย flow เดิม
class QrFriendScreen extends StatefulWidget {
  final String myQrData;
  final String displayName;
  final String bcId;

  const QrFriendScreen({
    super.key,
    required this.myQrData,
    required this.displayName,
    required this.bcId,
  });

  /// mobile_scanner รองรับกล้องสแกนเฉพาะ Android / iOS / macOS
  static bool get cameraScanSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  State<QrFriendScreen> createState() => _QrFriendScreenState();
}

class _QrFriendScreenState extends State<QrFriendScreen> {
  static const _stageColor = Color(0xFF1C1412);

  final TextEditingController _pasteCtrl = TextEditingController();
  bool _showMyQr = false;
  bool _handled = false;
  bool _copied = false;

  @override
  void dispose() {
    _pasteCtrl.dispose();
    super.dispose();
  }

  void _submit(String? raw) {
    final code = raw?.trim() ?? '';
    if (code.isEmpty || _handled) return;
    _handled = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('qr-fullscreen-view'),
      backgroundColor: _stageColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _showMyQr ? _buildMyQr() : _buildScan()),
            _buildModeSwitch(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SizedBox(
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            key: const Key('qr-fullscreen-close-btn'),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            color: Colors.white,
            tooltip: 'ย้อนกลับ',
          ),
          Text(
            _showMyQr ? 'QR ของฉัน' : 'สแกน QR เพิ่มเพื่อน',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScan() {
    if (!QrFriendScreen.cameraScanSupported) return _buildPasteFallback();
    return LayoutBuilder(
      builder: (context, box) {
        final frame = (box.biggest.shortestSide * 0.68).clamp(180.0, 320.0);
        return Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            // สร้าง/ทำลายตามโหมด — สลับไป "QR ของฉัน" กล้องจะปิดเอง
            MobileScanner(
              key: const Key('qr-fullscreen-video'),
              onDetect: (capture) =>
                  _submit(capture.barcodes.firstOrNull?.rawValue),
              errorBuilder: (context, error) => _buildCameraError(),
            ),
            Center(
              child: Container(
                width: frame,
                height: frame,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: AppTheme.goldClay, width: 3),
                ),
              ),
            ),
            const Positioned(
              left: 16,
              right: 16,
              bottom: 18,
              child: Text(
                'วาง QR ของเพื่อนให้อยู่ในกรอบ',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCameraError() {
    return ColoredBox(
      color: _stageColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off_rounded,
                color: Colors.white70,
                size: 40,
              ),
              const SizedBox(height: 8),
              const Text(
                'เปิดกล้องไม่ได้ กรุณาอนุญาตการใช้กล้อง หรือวางรหัส QR แทน',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              _buildPasteRow(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPasteFallback() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.qr_code_scanner_rounded,
                color: AppTheme.goldClay,
                size: 44,
              ),
              const SizedBox(height: 8),
              const Text(
                'อุปกรณ์นี้ยังสแกนด้วยกล้องไม่ได้\nวางรหัส QR ที่เพื่อนส่งมาให้แทน',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              _buildPasteRow(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPasteRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: SizedBox(
            height: 40,
            child: TextField(
              key: const Key('qr-fullscreen-paste-input'),
              controller: _pasteCtrl,
              textInputAction: TextInputAction.done,
              onSubmitted: _submit,
              decoration: const InputDecoration(
                hintText: 'วางรหัส QR ของเพื่อน',
                isDense: true,
                filled: true,
                fillColor: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          height: 40,
          child: ElevatedButton(
            key: const Key('qr-fullscreen-paste-btn'),
            onPressed: () => _submit(_pasteCtrl.text),
            child: const Text('เพิ่มเพื่อน'),
          ),
        ),
      ],
    );
  }

  Widget _buildMyQr() {
    final hasQr = widget.myQrData.isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Container(
          key: const Key('qr-fullscreen-my-qr'),
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasQr)
                BcQrBox(data: widget.myQrData, size: 232)
              else
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('ยังไม่มี QR ของบัญชีนี้'),
                ),
              const SizedBox(height: 10),
              Text(
                widget.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (widget.bcId.isNotEmpty)
                Text(
                  '@${widget.bcId}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.slateMuted,
                  ),
                ),
              const SizedBox(height: 8),
              const Text(
                'ให้เพื่อนสแกน QR นี้เพื่อเพิ่มคุณเป็นเพื่อน',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              ),
              if (hasQr) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('qr-fullscreen-copy-btn'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.myQrData));
                    setState(() => _copied = true);
                  },
                  icon: Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    size: 15,
                  ),
                  label: Text(_copied ? 'คัดลอกแล้ว' : 'คัดลอกรหัส QR'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeSwitch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildModeButton(
              key: const Key('qr-fullscreen-tab-scan'),
              icon: Icons.qr_code_scanner_rounded,
              label: 'สแกน QR',
              selected: !_showMyQr,
              onTap: () => setState(() => _showMyQr = false),
            ),
            _buildModeButton(
              key: const Key('qr-fullscreen-tab-mine'),
              icon: Icons.qr_code_2_rounded,
              label: 'QR ของฉัน',
              selected: _showMyQr,
              onTap: () => setState(() => _showMyQr = true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeButton({
    required Key key,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: selected ? AppTheme.brandPrimary : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: key,
          onTap: onTap,
          child: SizedBox(
            height: 42,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
