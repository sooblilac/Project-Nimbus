import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../codec/nimbus_codec.dart' as codec;
import '../data/town_pack.dart';
import 'theme.dart';

/// Schematic map, drawn on a 360 x 800 canvas scaled to the screen width:
/// light blue blocks, the town's river, overlays for the open tab, and the typhoon.
class StormMap extends StatefulWidget {
  const StormMap({super.key, required this.town, required this.tab, this.reply});
  final Town town;
  final String tab;
  final codec.Reply? reply;

  @override
  State<StormMap> createState() => _StormMapState();
}

class _StormMapState extends State<StormMap> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 12));

  @override
  void initState() {
    super.initState();
    if (!WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations) _spin.repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Schematic map of ${widget.town.name}',
        child: AnimatedBuilder(
          animation: _spin,
          builder: (_, __) => CustomPaint(
            size: Size.infinite,
            painter: _MapPainter(widget.town, widget.tab, widget.reply, _spin.value),
          ),
        ),
      );
}

class _MapPainter extends CustomPainter {
  _MapPainter(this.town, this.tab, this.reply, this.spin);
  final Town town;
  final String tab;
  final codec.Reply? reply;
  final double spin;

  static const _levelColor = {'H': NimbusColors.danger, 'M': NimbusColors.warning, 'L': NimbusColors.ok};

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 360);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 360, 800), Paint()..color = NimbusColors.mapGround);
    _sea(canvas);
    _blocks(canvas);
    // Town features are scaled into the open area between the side controls, like the web demo.
    canvas.save();
    canvas.translate(40, -10);
    canvas.scale(0.85);
    _river(canvas);
    _overlays(canvas);
    canvas.restore();
    _storm(canvas, strong: tab == 'Q');
    canvas.restore();
  }

  void _sea(Canvas canvas) {
    final path = Path()
      ..moveTo(190, 0)
      ..lineTo(360, 0)
      ..lineTo(360, 250)
      ..cubicTo(336, 214, 300, 178, 268, 150)
      ..cubicTo(236, 120, 206, 70, 190, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = NimbusColors.mapWater.withValues(alpha: 0.55));
  }

  void _blocks(Canvas canvas) {
    final rnd = math.Random(int.parse(town.code));
    final top = Paint()..color = NimbusColors.mapTop;
    final side = Paint()..color = NimbusColors.mapSide;
    final side2 = Paint()..color = NimbusColors.mapSide2;
    for (var row = 0; row < 26; row++) {
      for (var col = 0; col < 9; col++) {
        final x = col * 42.0 + (row.isOdd ? 21 : 0) + 8, y = 132.0 + row * 26;
        if ((y < 250 && x > 176) || rnd.nextDouble() < 0.5) continue;
        final h = 5.0 + rnd.nextInt(14), w = 12.0 + rnd.nextInt(5), d = w * 0.55;
        canvas.drawPath(Path()..moveTo(x, y)..relativeLineTo(w, -d)..relativeLineTo(0, -h)..relativeLineTo(-w, d)..close(), side);
        canvas.drawPath(Path()..moveTo(x, y)..relativeLineTo(-w, -d)..relativeLineTo(0, -h)..relativeLineTo(w, d)..close(), side2);
        canvas.drawPath(Path()..moveTo(x, y - h)..relativeLineTo(w, -d)..relativeLineTo(-w, -d)..relativeLineTo(-w, d)..close(), top);
      }
    }
  }

  void _river(Canvas canvas) {
    final path = Path()..moveTo(town.river.first.dx, town.river.first.dy);
    for (final pt in town.river.skip(1)) {
      path.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(path, Paint()
      ..color = NimbusColors.mapWater
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  }

  // Overlays use only what the last reply said, so the map never shows data the phone hasn't received.
  void _overlays(Canvas canvas) {
    final r = reply;
    if (r == null || r.type != tab || r.type != 'F') return;
    for (final item in r.items) {
      if (item.customName != null || item.index > town.zones.length) continue;
      final zone = town.zones[item.index - 1];
      final color = _levelColor[item.level] ?? NimbusColors.primary;
      canvas.drawOval(zone, Paint()..color = color.withValues(alpha: 0.3));
      canvas.drawOval(zone, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = item.now == 'F' ? 3 : 1.5);
      _badge(canvas, zone.center, '${item.index}', color);
    }
  }

  void _badge(Canvas canvas, Offset at, String label, Color color) {
    canvas.drawCircle(at, 11, Paint()..color = color);
    canvas.drawCircle(at, 11, Paint()
      ..color = NimbusColors.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5);
    final tp = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(color: NimbusColors.onPrimary, fontSize: 11.5, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  /// Typhoon: a dot with a radial gradient, curved arrows for the counterclockwise wind,
  /// an arrow for its heading, and dots along its past track.
  void _storm(Canvas canvas, {required bool strong}) {
    final at = town.stormAt;
    canvas.saveLayer(null, Paint()..color = Colors.black.withValues(alpha: strong ? 1 : 0.45));
    final track = Paint()
      ..color = NimbusColors.muted
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final points = [...town.stormTrack, at];
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i], b = points[i + 1];
      for (var t = 0.0; t < 1; t += 0.25) {
        canvas.drawCircle(Offset.lerp(a, b, t)!, 1.4, track);
      }
    }
    for (var i = 0; i < town.stormTrack.length; i++) {
      final c = town.stormTrack[i];
      canvas.drawCircle(c, 3 + i * 0.6, Paint()..color = NimbusColors.surface);
      canvas.drawCircle(c, 3 + i * 0.6, Paint()
        ..color = NimbusColors.muted
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    }
    canvas.drawCircle(at, 46, Paint()
      ..shader = RadialGradient(colors: [
        NimbusColors.surface.withValues(alpha: 0.95),
        NimbusColors.primary.withValues(alpha: 0.55),
        NimbusColors.primary.withValues(alpha: 0),
      ], stops: const [0, 0.35, 1]).createShader(Rect.fromCircle(center: at, radius: 46)));
    final wind = Paint()
      ..color = NimbusColors.wind
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const r = 34.0;
    for (var i = 0; i < 4; i++) {
      final start = i * math.pi / 2 - spin * 2 * math.pi;
      canvas.drawArc(Rect.fromCircle(center: at, radius: r), start, -0.75, false, wind);
      final end = start - 0.75;
      final tip = at + Offset(math.cos(end), math.sin(end)) * r;
      canvas.drawLine(tip, tip + Offset(math.cos(end - math.pi / 2 + 0.6), math.sin(end - math.pi / 2 + 0.6)) * 7, wind);
      canvas.drawLine(tip, tip + Offset(math.cos(end + 0.4), math.sin(end + 0.4)) * 7, wind);
    }
    canvas.drawCircle(at, 9, Paint()..color = NimbusColors.primary);
    canvas.drawCircle(at, 9, Paint()
      ..color = NimbusColors.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
    // Heading: west-northwest, away from the track.
    final heading = Paint()
      ..color = NimbusColors.primary
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    final from = at + const Offset(-14, -6), to = at + const Offset(-62, -26);
    canvas.drawLine(from, to, heading);
    final dir = (to - from) / (to - from).distance;
    final normal = Offset(-dir.dy, dir.dx);
    canvas.drawPath(
      Path()
        ..moveTo(to.dx + dir.dx * 8, to.dy + dir.dy * 8)
        ..lineTo(to.dx + normal.dx * 6, to.dy + normal.dy * 6)
        ..lineTo(to.dx - normal.dx * 6, to.dy - normal.dy * 6)
        ..close(),
      Paint()..color = NimbusColors.primary,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MapPainter old) => old.spin != spin || old.town != town || old.tab != tab || old.reply != reply;
}
