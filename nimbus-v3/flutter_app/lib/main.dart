import 'package:flutter/material.dart';

import 'sms/sms_service.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sms = await SmsService.open();
  await sms.start();
  runApp(NimbusApp(sms: sms));
}

class NimbusApp extends StatelessWidget {
  const NimbusApp({super.key, required this.sms});
  final SmsService sms;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Nimbus',
        debugShowCheckedModeBanner: false,
        theme: nimbusTheme(),
        home: HomeScreen(sms: sms),
      );
}
