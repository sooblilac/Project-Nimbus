import 'package:flutter/material.dart';

import '../sms/sms_service.dart';
import 'theme.dart';

class GatewayScreen extends StatelessWidget {
  const GatewayScreen({super.key, required this.sms, required this.onStop});

  final SmsService sms;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: 'Back to NIMBUS',
        onPressed: onStop,
        icon: const Icon(Icons.arrow_back),
      ),
      title: const Text('NIMBUS · SMS gateway'),
      actions: [TextButton(onPressed: onStop, child: const Text('Stop'))],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.cell_tower,
                size: 56,
                color: NimbusColors.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Pin relay is active',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'This phone stores trusted LGU pin snapshots and replies to '
                'resident “Get map pins” SMS requests. Keep its SIM active and '
                'leave NIMBUS installed; do not force-stop the app.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.nimbusPalette.muted),
              ),
              const SizedBox(height: 20),
              FutureBuilder<String>(
                future: sms.getTrustedLguNumber(),
                builder:
                    (context, snapshot) => Text(
                      snapshot.hasError
                          ? 'Could not load trusted LGU number: ${snapshot.error}'
                          : snapshot.hasData
                          ? 'Accepting pin updates from ${snapshot.data}'
                          : 'Loading trusted LGU number…',
                      textAlign: TextAlign.center,
                    ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop gateway'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
