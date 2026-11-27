import 'package:flutter/material.dart';

import 'theme.dart';

/// Landing screen: soft sky, the NIMBUS mark, and a choice between the
/// resident view and LGU sign-in resting on a bank of clouds.
class WelcomeScreenV2 extends StatefulWidget {
  const WelcomeScreenV2({
    super.key,
    required this.opening,
    required this.error,
    required this.onOpen,
    required this.onOpenGateway,
    required this.onSettings,
  });

  final bool opening;
  final String? error;

  /// `false` opens the resident view, `true` the LGU dashboard.
  final ValueChanged<bool> onOpen;
  final VoidCallback onOpenGateway;
  final VoidCallback onSettings;

  @override
  State<WelcomeScreenV2> createState() => _WelcomeScreenV2State();
}

class _WelcomeScreenV2State extends State<WelcomeScreenV2>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  Animation<double> _step(double from, double to) => CurvedAnimation(
    parent: _intro,
    curve: Interval(from, to, curve: Curves.easeOutCubic),
  );

  @override
  Widget build(BuildContext context) {
    final sky = _Sky.of(context);
    final palette = context.nimbusPalette;
    final mark = _step(0, 0.6);
    final actions = _step(0.35, 1);

    return Scaffold(
      backgroundColor: sky.top,
      body: Stack(
        children: [
          // Sky.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [sky.top, sky.bottom],
                ),
              ),
              child: CustomPaint(painter: _HaloPainter(sky.halo)),
            ),
          ),
          // Cloud bank; the actions sit on its white body.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _cloudHeight + MediaQuery.paddingOf(context).bottom,
            child: FadeTransition(
              opacity: actions,
              child: CustomPaint(painter: _CloudPainter(sky)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: IconButton(
                      tooltip: 'Settings',
                      onPressed: widget.onSettings,
                      icon: Icon(Icons.settings_outlined, color: palette.muted),
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: FadeTransition(
                      opacity: mark,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.06),
                          end: Offset.zero,
                        ).animate(mark),
                        // Shrinks the mark on short screens instead of overflowing.
                        child: LayoutBuilder(
                          builder: (context, box) => FittedBox(
                            fit: BoxFit.scaleDown,
                            child: SizedBox(
                              width: box.maxWidth,
                              child: _Brand(sky: sky),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                FadeTransition(
                  opacity: actions,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.08),
                      end: Offset.zero,
                    ).animate(actions),
                    child: _Actions(
                      opening: widget.opening,
                      error: widget.error,
                      onOpen: widget.onOpen,
                      onOpenGateway: widget.onOpenGateway,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Height of the cloud bank, measured from the bottom safe-area edge.
const _cloudHeight = 330.0;

class _Brand extends StatelessWidget {
  const _Brand({required this.sky});
  final _Sky sky;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 132,
            height: 132,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF6CB2F7), NimbusColors.primary],
              ),
              boxShadow: [
                BoxShadow(
                  color: NimbusColors.primary.withValues(alpha: 0.28),
                  blurRadius: 32,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Image.asset(
              'assets/images/nmbus_mark.png',
              semanticLabel: 'NIMBUS logo',
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'NIMBUS',
            style: TextStyle(
              color: palette.text,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Flood and storm updates for your town,\neven without mobile data.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.muted,
              fontSize: 15,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.opening,
    required this.error,
    required this.onOpen,
    required this.onOpenGateway,
  });

  final bool opening;
  final String? error;
  final ValueChanged<bool> onOpen;
  final VoidCallback onOpenGateway;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    const pill = StadiumBorder();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Continue as',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.muted,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: opening ? null : () => onOpen(false),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(NimbusSizes.primaryButton),
                shape: pill,
                elevation: 0,
              ),
              icon: const Icon(Icons.person_outline),
              label: const Text('Resident'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: opening ? null : () => onOpen(true),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(NimbusSizes.primaryButton),
                shape: pill,
                foregroundColor: palette.text,
                backgroundColor: palette.surface,
                side: BorderSide(color: palette.line, width: 1.5),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              icon: const Icon(Icons.account_balance_outlined),
              label: const Text('LGU staff sign in'),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Center(
              child: TextButton.icon(
                onPressed: opening ? null : onOpenGateway,
                style: TextButton.styleFrom(
                  foregroundColor: palette.muted,
                  minimumSize: const Size(48, NimbusSizes.minTap),
                ),
                icon: const Icon(Icons.cell_tower, size: 18),
                label: const Text(
                  'Use this phone as the SMS gateway',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Colors for the sky and clouds, light and dark.
class _Sky {
  const _Sky({
    required this.top,
    required this.bottom,
    required this.halo,
    required this.cloudBack,
    required this.cloudMid,
    required this.cloudFront,
  });

  final Color top;
  final Color bottom;
  final Color halo;
  final Color cloudBack;
  final Color cloudMid;
  final Color cloudFront;

  static _Sky of(BuildContext context) {
    final palette = context.nimbusPalette;
    if (Theme.of(context).brightness == Brightness.dark) {
      return _Sky(
        top: palette.background,
        bottom: const Color(0xFF13284A),
        halo: Colors.white.withValues(alpha: 0.04),
        cloudBack: const Color(0xFF1D3761),
        cloudMid: const Color(0xFF1A2E4E),
        cloudFront: palette.surface,
      );
    }
    return const _Sky(
      top: Color(0xFFF6F9FF),
      bottom: Color(0xFFD3E5FE),
      halo: Color(0x66FFFFFF),
      cloudBack: Color(0xFFBCD6FA),
      cloudMid: Color(0xFFDDEBFE),
      cloudFront: Colors.white,
    );
  }
}

/// Large, faint rings in the sky, like light through haze.
class _HaloPainter extends CustomPainter {
  const _HaloPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    canvas
      ..drawCircle(Offset(size.width * 1.05, size.height * 0.08), size.width * 0.55, paint)
      ..drawCircle(Offset(size.width * -0.15, size.height * 0.55), size.width * 0.45, paint);
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.color != color;
}

/// Three layers of rounded cloud tops; the front layer fills to the bottom.
class _CloudPainter extends CustomPainter {
  const _CloudPainter(this.sky);
  final _Sky sky;

  // (x as a fraction of width, radius as a fraction of width) for each puff.
  static const _back = [
    (-0.02, 0.16), (0.2, 0.2), (0.45, 0.14), (0.68, 0.19), (0.93, 0.17),
  ];
  static const _mid = [
    (0.04, 0.17), (0.28, 0.13), (0.5, 0.18), (0.74, 0.14), (1.0, 0.19),
  ];
  static const _front = [
    (-0.04, 0.2), (0.22, 0.17), (0.5, 0.22), (0.78, 0.17), (1.04, 0.2),
  ];

  void _layer(
    Canvas canvas,
    Size size,
    List<(double, double)> puffs,
    double baseline,
    Color color,
  ) {
    final paint = Paint()..color = color;
    final w = size.width;
    final path = Path()..addRect(Rect.fromLTRB(0, baseline, w, size.height));
    for (final (x, r) in puffs) {
      path.addOval(Rect.fromCircle(center: Offset(x * w, baseline), radius: r * w));
    }
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // Baselines sit low enough that the front puffs crest near the top edge.
    _layer(canvas, size, _back, w * 0.2, sky.cloudBack);
    _layer(canvas, size, _mid, w * 0.27, sky.cloudMid);
    _layer(canvas, size, _front, w * 0.36, sky.cloudFront);
  }

  @override
  bool shouldRepaint(_CloudPainter old) => old.sky != sky;
}
