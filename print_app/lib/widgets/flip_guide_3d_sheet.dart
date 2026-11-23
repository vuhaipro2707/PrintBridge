import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Widget animation 3D minh họa từng bước (1: mặt trước, 2: lật trục dài, 3: trang lẻ cuối).
class FlipStep3DVisual extends StatefulWidget {
  final int step;
  final double height;

  const FlipStep3DVisual({
    super.key,
    required this.step,
    this.height = 220,
  });

  @override
  State<FlipStep3DVisual> createState() => _FlipStep3DVisualState();
}

class _FlipStep3DVisualState extends State<FlipStep3DVisual>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant FlipStep3DVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step != widget.step) {
      _controller.forward(from: 0);
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [Color(0xFF0F172A), Color(0xFF1E1B4B)]
              : const [Color(0xFFF8FAFC), Color(0xFFEEF2FF)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return switch (widget.step) {
            1 => _buildStep1Scene(_controller.value),
            2 => _buildStep2FlipScene(_controller.value),
            _ => _buildStep3BonusScene(_controller.value),
          };
        },
      ),
    );
  }

  Widget _buildStep1Scene(double t) {
    final swayY = math.sin(t * math.pi * 2) * 0.08;
    return Center(
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0015)
          ..rotateX(0.12)
          ..rotateY(-0.18 + swayY),
        child: _portraitPaperStack(
          title: 'MẶT TRƯỚC',
          subtitle: 'Trang 1, 3, 5...',
          accent: const Color(0xFF4F46E5),
          showReadableText: true,
        ),
      ),
    );
  }

  Widget _buildStep2FlipScene(double t) {
    final flipProgress = ((t - 0.18) / 0.54).clamp(0.0, 1.0);
    final eased = Curves.easeInOutCubic.transform(flipProgress);
    final angleY = eased * math.pi;
    final isBackVisible = angleY > (math.pi / 2);

    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 2,
          height: widget.height * 0.8,
          decoration: BoxDecoration(
            color: const Color(0xFF0284C7).withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015)
            ..rotateX(0.14)
            ..rotateY(angleY),
          child: isBackVisible
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.rotationY(math.pi),
                  child: _portraitPaperStack(
                    title: 'MẶT SAU TRẮNG',
                    subtitle: 'Đầu giấy vẫn ở trên',
                    accent: const Color(0xFF0284C7),
                    isBlankSide: true,
                  ),
                )
              : _portraitPaperStack(
                  title: 'ĐỌC XUÔI CHỮ',
                  subtitle: 'Cầm thẳng đứng',
                  accent: const Color(0xFF4F46E5),
                  showReadableText: true,
                ),
        ),
        Positioned(
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFBAE6FD)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sync_alt_rounded,
                    size: 14, color: Color(0xFF0284C7)),
                const SizedBox(width: 6),
                Text(
                  isBackVisible
                      ? 'Đã lật úp theo trục dài — giữ nguyên đầu giấy'
                      : 'Cầm đọc xuôi → lật úp theo trục dài dọc',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0369A1),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStep3BonusScene(double t) {
    final floatY = math.sin(t * math.pi * 2) * 6;
    return Center(
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0015)
          ..rotateX(0.14)
          ..rotateY(0.18)
          ..translateByDouble(0.0, floatY, 0.0, 1.0),
        child: _portraitPaperStack(
          title: 'TRANG LẺ CUỐI',
          subtitle: 'In riêng 1 tờ cuối',
          accent: const Color(0xFFD97706),
          singleSheet: true,
          showReadableText: true,
        ),
      ),
    );
  }

  Widget _portraitPaperStack({
    required String title,
    required String subtitle,
    required Color accent,
    bool isBlankSide = false,
    bool singleSheet = false,
    bool showReadableText = false,
  }) {
    final scale = widget.height < 200 ? 0.82 : 1.0;
    return Transform.scale(
      scale: scale,
      child: SizedBox(
        width: 122,
        height: 164,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (!singleSheet) ...[
              Positioned(
                top: 10,
                left: 10,
                child: _sheetLayer(const Color(0xFFE2E8F0)),
              ),
              Positioned(
                top: 5,
                left: 5,
                child: _sheetLayer(const Color(0xFFF1F5F9)),
              ),
            ],
            Container(
              width: 110,
              height: 152,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isBlankSide ? const Color(0xFFF8FAFC) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x220F172A),
                    blurRadius: 12,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'ĐẦU GIẤY ▲',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (showReadableText) ...[
                    Text(
                      'Văn bản xuôi',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _textBar(0.95),
                    const SizedBox(height: 3),
                    _textBar(0.8),
                    const SizedBox(height: 3),
                    _textBar(0.88),
                    const SizedBox(height: 3),
                    _textBar(0.6),
                  ] else ...[
                    Expanded(
                      child: Center(
                        child: Icon(
                          Icons.layers_clear_rounded,
                          size: 28,
                          color: accent.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 9.5,
                      color: Color(0xFF475569),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textBar(double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFCBD5E1),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _sheetLayer(Color color) {
    return Container(
      width: 110,
      height: 152,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
    );
  }
}

class FlipGuide3DSheet extends StatefulWidget {
  final bool hasBonusOddLast;
  final int initialStep;

  const FlipGuide3DSheet({
    super.key,
    required this.hasBonusOddLast,
    this.initialStep = 1,
  });

  @override
  State<FlipGuide3DSheet> createState() => _FlipGuide3DSheetState();
}

class _FlipGuide3DSheetState extends State<FlipGuide3DSheet> {
  late int _activeStep;

  @override
  void initState() {
    super.initState();
    _activeStep = widget.initialStep;
  }

  @override
  Widget build(BuildContext context) {
    final totalSteps = widget.hasBonusOddLast ? 3 : 2;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFCBD5E1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.threed_rotation_rounded,
                  color: Color(0xFF4F46E5),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hướng dẫn lật giấy 3D',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const Text(
                      'Lật theo trục dài (giữ nguyên đầu giấy)',
                      style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SegmentedButton<int>(
            segments: [
              const ButtonSegment(value: 1, label: Text('Bước 1')),
              const ButtonSegment(value: 2, label: Text('Bước 2')),
              if (totalSteps == 3)
                const ButtonSegment(value: 3, label: Text('Bước 3')),
            ],
            selected: {_activeStep},
            onSelectionChanged: (s) => setState(() => _activeStep = s.first),
          ),
          const SizedBox(height: 16),
          FlipStep3DVisual(step: _activeStep, height: 240),
          const SizedBox(height: 14),
          _buildStepDescription(),
        ],
      ),
    );
  }

  Widget _buildStepDescription() {
    final (String title, String body, Color bg, Color fg) = switch (_activeStep) {
      1 => (
          'Bước 1: In mặt trước (trang lẻ 1, 3, 5...)',
          'Bấm "In mặt trước". Đợi máy in chạy xong hết các trang lẻ rồi cầm toàn bộ xấp giấy ra.',
          const Color(0xFFEEF2FF),
          const Color(0xFF3730A3),
        ),
      2 => (
          'Bước 2: Đợi in xong hẳn → Lật úp theo trục dài',
          'Đợi máy in chạy xong hết hẳn các trang lẻ rồi mới cầm xấp giấy lên! Cầm thẳng đứng đọc xuôi chữ, lật úp sang ngang theo trục dài dọc (giữ nguyên đầu giấy ở trên) rồi đặt vào khay và bấm In mặt sau.',
          const Color(0xFFE0F2FE),
          const Color(0xFF075985),
        ),
      _ => (
          'Bước 3: In trang lẻ cuối (Bonus)',
          'Vì tổng số trang là số lẻ, trang cuối cùng không có mặt sau. Chỉ cần nạp giấy trắng bình thường và bấm bước này để in nốt tờ cuối.',
          const Color(0xFFFEF3C7),
          const Color(0xFF92400E),
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: fg),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(fontSize: 12.5, color: fg, height: 1.4),
          ),
        ],
      ),
    );
  }
}
