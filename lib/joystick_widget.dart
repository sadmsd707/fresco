import 'package:flutter/material.dart';

/// A custom joystick widget built with CustomPainter and GestureDetector.
/// Reports normalized x,y values from -100 to 100 via [onChanged].
/// Springs back to center on release and calls [onChanged] with (0,0).
class JoystickWidget extends StatefulWidget {
  final double size;
  final String label;
  final String? horizontalLabel;
  final String? verticalLabel;
  final ValueChanged<Offset> onChanged;
  final Color baseColor;
  final Color knobColor;

  const JoystickWidget({
    super.key,
    this.size = 140,
    required this.label,
    this.horizontalLabel,
    this.verticalLabel,
    required this.onChanged,
    this.baseColor = const Color(0xFF161F38),
    this.knobColor = const Color(0xFF00E5FF),
  });

  @override
  State<JoystickWidget> createState() => _JoystickWidgetState();
}

class _JoystickWidgetState extends State<JoystickWidget>
    with SingleTickerProviderStateMixin {
  Offset _knobOffset = Offset.zero;
  late AnimationController _returnController;
  late Animation<Offset> _returnAnimation;

  double get _radius => widget.size / 2;
  double get _knobRadius => widget.size * 0.18;

  @override
  void initState() {
    super.initState();
    _returnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
    );
    _returnAnimation =
        Tween<Offset>(begin: Offset.zero, end: Offset.zero).animate(
      CurvedAnimation(parent: _returnController, curve: Curves.easeOut),
    );
    _returnController.addListener(() {
      setState(() {
        _knobOffset = _returnAnimation.value;
      });
    });
  }

  @override
  void dispose() {
    _returnController.dispose();
    super.dispose();
  }

  void _handleDrag(Offset localPosition) {
    final center = Offset(_radius, _radius);
    Offset delta = localPosition - center;
    final distance = delta.distance;
    final maxDist = _radius - _knobRadius;

    if (distance > maxDist) {
      delta = delta / distance * maxDist;
    }

    setState(() => _knobOffset = delta);

    // Normalize to -100..100
    final nx = (delta.dx / maxDist * 100).round().clamp(-100, 100);
    final ny = (-(delta.dy / maxDist) * 100).round().clamp(-100, 100);
    widget.onChanged(Offset(nx.toDouble(), ny.toDouble()));
  }

  void _handleRelease() {
    _returnAnimation =
        Tween<Offset>(begin: _knobOffset, end: Offset.zero).animate(
      CurvedAnimation(parent: _returnController, curve: Curves.easeOut),
    );
    _returnController.forward(from: 0);
    widget.onChanged(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 3),
        if (widget.verticalLabel != null)
          Text(
            widget.verticalLabel!,
            style: TextStyle(
              color: widget.knobColor.withValues(alpha: 0.8),
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onPanStart: (d) => _handleDrag(d.localPosition),
              onPanUpdate: (d) => _handleDrag(d.localPosition),
              onPanEnd: (_) => _handleRelease(),
              onPanCancel: _handleRelease,
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: CustomPaint(
                  painter: _JoystickPainter(
                    knobOffset: _knobOffset,
                    knobRadius: _knobRadius,
                    baseColor: widget.baseColor,
                    knobColor: widget.knobColor,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (widget.horizontalLabel != null) ...[
          const SizedBox(height: 2),
          Text(
            widget.horizontalLabel!,
            style: TextStyle(
              color: widget.knobColor.withValues(alpha: 0.8),
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _JoystickPainter extends CustomPainter {
  final Offset knobOffset;
  final double knobRadius;
  final Color baseColor;
  final Color knobColor;

  _JoystickPainter({
    required this.knobOffset,
    required this.knobRadius,
    required this.baseColor,
    required this.knobColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Outer glow / shadow
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black38
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // Base circle gradient
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            baseColor.withValues(alpha: 0.95),
            baseColor,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    // Outer boundary ring
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..color = knobColor.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Cross-hair lines
    final crossPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center.dx, center.dy - radius + 8),
      Offset(center.dx, center.dy + radius - 8),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx - radius + 8, center.dy),
      Offset(center.dx + radius - 8, center.dy),
      crossPaint,
    );

    // Concentric guide ring at 50%
    canvas.drawCircle(
      center,
      radius * 0.5,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.05)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Knob shadow
    final knobCenter = center + knobOffset;
    canvas.drawCircle(
      knobCenter + const Offset(0, 2),
      knobRadius,
      Paint()
        ..color = Colors.black45
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Knob body gradient
    canvas.drawCircle(
      knobCenter,
      knobRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            knobColor,
            knobColor.withValues(alpha: 0.65),
          ],
          stops: const [0.3, 1.0],
        ).createShader(
            Rect.fromCircle(center: knobCenter, radius: knobRadius)),
    );

    // Knob border
    canvas.drawCircle(
      knobCenter,
      knobRadius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Knob center highlight
    canvas.drawCircle(
      knobCenter - Offset(knobRadius * 0.25, knobRadius * 0.25),
      knobRadius * 0.3,
      Paint()..color = Colors.white38,
    );
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return knobOffset != oldDelegate.knobOffset;
  }
}
