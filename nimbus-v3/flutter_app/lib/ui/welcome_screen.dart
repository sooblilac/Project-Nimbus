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
    backgroundColor: context.nimbusPalette.background,
    body: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            context.nimbusPalette.background,
            context.nimbusPalette.surfaceAlt,
          ],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: context.nimbusPalette.surface,
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: context.nimbusPalette.line),
                      boxShadow: [
                        BoxShadow(
                          color: NimbusColors.primary.withValues(alpha: 0.08),
                          blurRadius: 28,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        FadeTransition(
                          opacity: _fade,
                          child: ScaleTransition(
                            scale: _scale,
                            child: Container(
                              width: 184,
                              height: 184,
                              decoration: const BoxDecoration(
                                color: NimbusColors.primary,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(14),
                              child: Image.asset(
                                'assets/images/nmbus_mark.png',
                                semanticLabel: 'NIMBUS rain cloud logo',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'NIMBUS',
                          style: TextStyle(
                            color: context.nimbusPalette.text,
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Local flood and storm updates, wherever you are.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.nimbusPalette.muted,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 30),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          child:
                              !_ready
                                  ? const SizedBox(
                                    key: ValueKey('intro-progress'),
                                    height: 130,
                                  )
                                  : Column(
                                    key: const ValueKey('role-prompt'),
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'How will you use NIMBUS?',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: context.nimbusPalette.text,
                                          fontSize: 20,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _RoleCard(
                                              icon: Icons.person_outline,
                                              title: 'User',
                                              subtitle: 'View local updates',
                                              selected: _selectedRole == false,
                                              onTap:
                                                  () => setState(
                                                    () => _selectedRole = false,
                                                  ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: _RoleCard(
                                              icon:
                                                  Icons
                                                      .account_balance_outlined,
                                              title: 'LGU admin',
                                              subtitle: 'Publish town updates',
                                              selected: _selectedRole == true,
                                              onTap:
                                                  () => setState(
                                                    () => _selectedRole = true,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 18),
                                      FilledButton(
                                        onPressed:
                                            _selectedRole == null ||
                                                    widget.opening
                                                ? null
                                                : () => widget.onOpen(
                                                  _selectedRole!,
                                                ),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: NimbusColors.primary,
                                          foregroundColor: Colors.white,
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                        ),
                                        child:
                                            widget.opening
                                                ? const SizedBox.square(
                                                  dimension: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white,
                                                      ),
                                                )
                                                : const Text('Open NIMBUS'),
                                      ),
                                      const SizedBox(height: 8),
                                      OutlinedButton.icon(
                                        onPressed:
                                            widget.opening
                                                ? null
                                                : widget.onOpenGateway,
                                        icon: const Icon(Icons.cell_tower),
                                        label: const Text(
                                          'Open SMS gateway on this phone',
                                        ),
                                      ),
                                    ],
                                  ),
                        ),
                        if (widget.error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            widget.error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: NimbusColors.danger),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: 'Settings',
                onPressed: widget.onSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ),
          ],
        ),
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
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

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
          constraints: const BoxConstraints(minHeight: 128),
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
