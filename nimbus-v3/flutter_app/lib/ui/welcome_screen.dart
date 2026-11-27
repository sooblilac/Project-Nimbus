import 'package:flutter/material.dart';

import 'theme.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    super.key,
    required this.opening,
    required this.error,
    required this.onOpen,
    required this.onOpenGateway,
    required this.onSettings,
  });

  final bool opening;
  final String? error;
  final ValueChanged<bool> onOpen;
  final VoidCallback onOpenGateway;
  final VoidCallback onSettings;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  )..addStatusListener((status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _ready = true);
    }
  });
  late final Animation<double> _scale = CurvedAnimation(
    parent: _intro,
    curve: Curves.easeOutBack,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _intro,
    curve: Curves.easeOut,
  );
  bool _ready = false;
  bool? _selectedRole;

  @override
  void initState() {
    super.initState();
    _intro.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFFDFDFF),
    body: SafeArea(
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _SplashWavesPainter()),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              tooltip: 'Settings',
              onPressed: widget.onSettings,
              icon: Icon(Icons.settings_outlined,
                  color: context.nimbusPalette.text),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FadeTransition(
                      opacity: _fade,
                      child: ScaleTransition(
                        scale: _scale,
                        child: Container(
                          width: 148,
                          height: 148,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F7FD),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF6968C7).withValues(alpha: 0.10),
                                blurRadius: 24,
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(18),
                          child: Image.asset(
                            'assets/images/nmbus_mark.png',
                            semanticLabel: 'NIMBUS rain cloud logo',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'NIMBUS',
                      style: TextStyle(
                        color: context.nimbusPalette.text,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.8,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Local flood and storm updates, wherever you are.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.nimbusPalette.muted,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 24),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      child: !_ready
                          ? const SizedBox(
                              key: ValueKey('intro-progress'), height: 220)
                          : Column(
                              key: const ValueKey('role-prompt'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'How will you use NIMBUS?',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: context.nimbusPalette.text,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _RoleCard(
                                  icon: Icons.person_outline,
                                  title: 'Resident',
                                  subtitle: 'View LGU, weather, storm and map updates',
                                  selected: _selectedRole == false,
                                  prominent: true,
                                  onTap: () => setState(() => _selectedRole = false),
                                ),
                                const SizedBox(height: 10),
                                _RoleCard(
                                  icon: Icons.account_balance_outlined,
                                  title: 'LGU admin',
                                  subtitle: 'Publish town updates',
                                  selected: _selectedRole == true,
                                  prominent: false,
                                  onTap: () => setState(() => _selectedRole = true),
                                ),
                                const SizedBox(height: 14),
                                FilledButton(
                                  onPressed: _selectedRole == null || widget.opening
                                      ? null
                                      : () => widget.onOpen(_selectedRole!),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: NimbusColors.primary,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size.fromHeight(54),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: widget.opening
                                      ? const SizedBox.square(
                                          dimension: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2, color: Colors.white))
                                      : const Text('Open NIMBUS'),
                                ),
                                const SizedBox(height: 6),
                                TextButton.icon(
                                  onPressed: widget.opening ? null : widget.onOpenGateway,
                                  style: TextButton.styleFrom(
                                    foregroundColor: context.nimbusPalette.muted,
                                    minimumSize: const Size.fromHeight(36),
                                  ),
                                  icon: const Icon(Icons.cell_tower, size: 17),
                                  label: const Text(
                                    'Open SMS gateway on this phone',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                    ),
                    if (widget.error != null) ...[
                      const SizedBox(height: 8),
                      Text(widget.error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: NimbusColors.danger)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.prominent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool prominent;

  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: selected ? 1.025 : 1,
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOut,
    child: Material(
      color:
          selected
              ? context.nimbusPalette.primarySoft
              : context.nimbusPalette.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: BoxConstraints(minHeight: prominent ? 148 : 82),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(
              color:
                  selected ? NimbusColors.primary : context.nimbusPalette.line,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: NimbusColors.primary),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  color: context.nimbusPalette.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.nimbusPalette.muted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SplashWavesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bottom = size.height;

    final back = Path()
      ..moveTo(0, bottom * 0.82)
      ..cubicTo(size.width * 0.18, bottom * 0.73, size.width * 0.35,
          bottom * 0.88, size.width * 0.52, bottom * 0.78)
      ..cubicTo(size.width * 0.70, bottom * 0.68, size.width * 0.86,
          bottom * 0.82, size.width, bottom * 0.72)
      ..lineTo(size.width, bottom)
      ..lineTo(0, bottom)
      ..close();
    canvas.drawPath(back, Paint()..color = const Color(0xFFDDE8FB));

    final mid = Path()
      ..moveTo(0, bottom * 0.89)
      ..cubicTo(size.width * 0.16, bottom * 0.79, size.width * 0.34,
          bottom * 0.94, size.width * 0.52, bottom * 0.84)
      ..cubicTo(size.width * 0.71, bottom * 0.74, size.width * 0.86,
          bottom * 0.91, size.width, bottom * 0.82)
      ..lineTo(size.width, bottom)
      ..lineTo(0, bottom)
      ..close();
    canvas.drawPath(mid, Paint()..color = const Color(0xFF93B1E6));

    final front = Path()
      ..moveTo(0, bottom * 0.96)
      ..cubicTo(size.width * 0.18, bottom * 0.86, size.width * 0.38,
          bottom, size.width * 0.55, bottom * 0.91)
      ..cubicTo(size.width * 0.74, bottom * 0.82, size.width * 0.88,
          bottom * 0.96, size.width, bottom * 0.90)
      ..lineTo(size.width, bottom)
      ..lineTo(0, bottom)
      ..close();
    canvas.drawPath(front, Paint()..color = const Color(0xFF2F6FE4));

    final highlight = Path()
      ..moveTo(size.width * 0.26, bottom * 0.91)
      ..cubicTo(size.width * 0.38, bottom * 0.86, size.width * 0.46,
          bottom * 0.96, size.width * 0.62, bottom * 0.89)
      ..cubicTo(size.width * 0.74, bottom * 0.84, size.width * 0.86,
          bottom * 0.92, size.width, bottom * 0.86)
      ..lineTo(size.width, bottom * 0.94)
      ..cubicTo(size.width * 0.86, bottom, size.width * 0.72,
          bottom * 0.91, size.width * 0.60, bottom * 0.97)
      ..cubicTo(size.width * 0.45, bottom, size.width * 0.34,
          bottom * 0.91, size.width * 0.26, bottom * 0.91)
      ..close();
    canvas.drawPath(highlight, Paint()..color = const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
