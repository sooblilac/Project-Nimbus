import 'dart:async';

import 'package:flutter/material.dart';

import '../codec/nimbus_codec.dart' as codec;
import '../data/town_pack.dart';
import '../sms/sms_service.dart';
import 'storm_map.dart';
import 'theme.dart';

const _tabs = [
  ('Q', 'Storm', Icons.cloud_outlined, 'Storm update', 'Get storm update by SMS'),
  ('F', 'Flood', Icons.waves, 'Flood-prone areas', 'Get flood areas by SMS'),
  ('E', 'Evac', Icons.home_outlined, 'Evacuation centers', 'Get evacuation centers by SMS'),
  ('R', 'Roads', Icons.add_road, 'Road status', 'Get road status by SMS'),
];
const _rain = ['No rain', 'Light rain', 'Moderate rain', 'Heavy rain', 'Intense rain'];
const _classes = ['No suspension', 'All levels', 'Preschool to SHS', 'Preschool to grade 10', 'Preschool to grade 6', 'Preschool only'];
const _level = {'H': 'High flood risk', 'M': 'Medium flood risk', 'L': 'Low flood risk'};
const _now = {'F': 'Flooding reported now', 'W': 'On watch, water rising nearby', 'C': 'No flooding now'};
const _road = {'O': ('Open', 'Open to all vehicles'), 'L': ('Light vehicles only', 'Trucks and buses turned back'), 'X': ('Closed', 'Not passable, use another route')};

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.sms});
  final SmsService sms;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _tab = 'Q';
  Town _town = towns.first;
  bool _waiting = false;
  bool _showRaw = false;
  bool _showSaved = false;
  List<SavedUpdate> _saved = [];
  SavedUpdate? _viewing;
  StreamSubscription<SavedUpdate>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.sms.replies.listen((u) async {
      _saved = await widget.sms.saved();
      if (mounted) setState(() => _waiting = false);
    });
    widget.sms.saved().then((s) => setState(() => _saved = s));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  SavedUpdate? get _latest {
    if (_viewing != null) return _viewing;
    for (final u in _saved) {
      if (u.type == _tab && u.townCode == _town.code) return u;
    }
    return null;
  }

  Future<void> _ask() async {
    setState(() {
      _waiting = true;
      _viewing = null;
      _showSaved = false;
    });
    await widget.sms.ask(_tab, _town.code);
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    final reply = latest == null ? null : codec.decode(latest.sms);
    final warning = _town.warnings[reply?.storm?.warning ?? '2'] ?? ('Storm update', '');
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: StormMap(town: _town, tab: _tab, reply: reply)),
        SafeArea(
          child: Stack(children: [
            Align(alignment: Alignment.topCenter, child: _TopPill(title: warning.$1, subtitle: 'Bagyong Ada (sample) · ${_town.name}')),
            Positioned(left: 12, top: 84, child: _TabRail(selected: _tab, onSelect: (t) => setState(() {
              _tab = t;
              _viewing = null;
            }))),
            Positioned(
              right: 12,
              top: 84,
              child: _RoundButton(
                icon: Icons.code,
                label: 'Show raw SMS',
                selected: _showRaw,
                onTap: () => setState(() => _showRaw = !_showRaw),
              ),
            ),
          ]),
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.54,
          minChildSize: 0.3,
          maxChildSize: 0.88,
          builder: (context, scroll) => _Sheet(
            scroll: scroll,
            title: _tabs.firstWhere((t) => t.$1 == _tab).$4,
            cta: _tabs.firstWhere((t) => t.$1 == _tab).$5,
            town: _town,
            onTown: (t) => setState(() {
              _town = t;
              _viewing = null;
            }),
            showSaved: _showSaved,
            onPane: (saved) => setState(() {
              _showSaved = saved;
              if (!saved) _viewing = null;
            }),
            saved: _saved,
            onOpenSaved: (u) => setState(() {
              _viewing = u;
              _tab = u.type;
              _town = townByCode(u.townCode);
              _showSaved = false;
            }),
            waiting: _waiting,
            latest: latest,
            reply: reply,
            showRaw: _showRaw,
            onAsk: _waiting ? null : _ask,
          ),
        ),
      ]),
    );
  }
}

class _TopPill extends StatelessWidget {
  const _TopPill({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        width: 240,
        decoration: _floating(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          Text(subtitle, style: const TextStyle(fontSize: 12, color: NimbusColors.muted), textAlign: TextAlign.center),
        ]),
      );
}

BoxDecoration _floating(double radius) => BoxDecoration(
      color: NimbusColors.surface,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [BoxShadow(color: NimbusColors.primary.withValues(alpha: 0.14), blurRadius: 14, offset: const Offset(0, 4))],
    );

class _TabRail extends StatelessWidget {
  const _TabRail({required this.selected, required this.onSelect});
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(6),
        decoration: _floating(22),
        child: Column(children: [
          for (final t in _tabs)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Semantics(
                selected: t.$1 == selected,
                button: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onSelect(t.$1),
                  child: Container(
                    width: 58,
                    height: 56,
                    decoration: BoxDecoration(
                      color: t.$1 == selected ? NimbusColors.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(t.$3, size: 22, color: t.$1 == selected ? NimbusColors.onPrimary : NimbusColors.muted),
                      Text(t.$2, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.$1 == selected ? NimbusColors.onPrimary : NimbusColors.muted)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: Material(
          color: selected ? NimbusColors.primary : NimbusColors.surface,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: NimbusColors.primary.withValues(alpha: 0.3),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: NimbusSizes.minTap,
              child: Icon(icon, color: selected ? NimbusColors.onPrimary : NimbusColors.text),
            ),
          ),
        ),
      );
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.scroll,
    required this.title,
    required this.cta,
    required this.town,
    required this.onTown,
    required this.showSaved,
    required this.onPane,
    required this.saved,
    required this.onOpenSaved,
    required this.waiting,
    required this.latest,
    required this.reply,
    required this.showRaw,
    required this.onAsk,
  });

  final ScrollController scroll;
  final String title;
  final String cta;
  final Town town;
  final ValueChanged<Town> onTown;
  final bool showSaved;
  final ValueChanged<bool> onPane;
  final List<SavedUpdate> saved;
  final ValueChanged<SavedUpdate> onOpenSaved;
  final bool waiting;
  final SavedUpdate? latest;
  final codec.Reply? reply;
  final bool showRaw;
  final VoidCallback? onAsk;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: NimbusColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [BoxShadow(color: NimbusColors.primary.withValues(alpha: 0.12), blurRadius: 30, offset: const Offset(0, -10))],
        ),
        child: Column(children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
              children: [
                Center(child: Container(width: 44, height: 5, decoration: BoxDecoration(color: NimbusColors.line, borderRadius: BorderRadius.circular(9)))),
                const SizedBox(height: 12),
                Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: town.code,
                  decoration: const InputDecoration(labelText: 'Your town'),
                  items: [for (final t in towns) DropdownMenuItem(value: t.code, child: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700)))],
                  onChanged: (code) => onTown(townByCode(code!)),
                ),
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  segments: [
                    const ButtonSegment(value: false, label: Text('Latest')),
                    ButtonSegment(value: true, label: Text(saved.isEmpty ? 'Saved' : 'Saved (${saved.length})')),
                  ],
                  selected: {showSaved},
                  onSelectionChanged: (s) => onPane(s.first),
                  style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(NimbusSizes.minTap))),
                ),
                const SizedBox(height: 12),
                ..._content(),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: NimbusColors.surfaceAlt))),
            child: SafeArea(
              top: false,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                FilledButton.icon(onPressed: onAsk, icon: const Icon(Icons.sms_outlined), label: Text(cta)),
                const SizedBox(height: 6),
                const Text('One tap sends one text. No mobile data used.', style: TextStyle(fontSize: 13, color: NimbusColors.muted)),
              ]),
            ),
          ),
        ]),
      );

  List<Widget> _content() {
    if (showSaved) {
      if (saved.isEmpty) return [const _Empty('No saved updates yet', 'Every reply you get is saved here automatically.')];
      return [
        for (final u in saved)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              minTileHeight: 64,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: NimbusColors.line)),
              title: Text('${_tabs.firstWhere((t) => t.$1 == u.type).$4} · ${townByCode(u.townCode).name}', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('Received ${TimeOfDay.fromDateTime(u.received).hour}:${u.received.minute.toString().padLeft(2, '0')}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpenSaved(u),
            ),
          ),
      ];
    }
    final out = <Widget>[];
    if (waiting) out.add(const _Status('Waiting for reply by SMS…', NimbusColors.muted, spinner: true));
    final r = reply;
    if (r == null) {
      if (!waiting) out.add(_Empty('Not requested yet', 'Tap “$cta”. The reply is saved here so you can open it again offline.'));
      return out;
    }
    final t = townByCode(r.townCode);
    final issued = 'Issued ${r.time.substring(0, 2)}:${r.time.substring(2)}';
    switch (r.type) {
      case 'Q':
        final s = r.storm!;
        final w = t.warnings[s.warning] ?? ('Storm update', '');
        out
          ..add(_Row(Icons.warning_amber, NimbusColors.danger, 'Official warning (sample)', w.$1, '${w.$2} · $issued'))
          ..add(const _Row(Icons.air, NimbusColors.primary, 'Storm movement (sample)', 'Moving west-northwest, about 20 km/h', 'Dots show where the storm has been'))
          ..add(_Row(Icons.cloud_outlined, NimbusColors.primary, 'Forecast', '${_rain[s.rain.clamp(0, 4)]}, gusts ${s.gusts} km/h', 'General forecast for ${t.name}'));
        if (s.evacSite > 0 && s.evacSite <= t.sites.length) {
          final site = t.sites[s.evacSite - 1];
          out.add(s.evacStatus == 'O'
              ? _Row(Icons.home_outlined, NimbusColors.ok, 'LGU announcement', 'Evacuate to $site', 'Site open')
              : _Row(Icons.home_outlined, NimbusColors.danger, 'LGU announcement', '$site is ${s.evacStatus == 'F' ? 'full' : 'closed'}', 'Open Evac to find a site with room'));
        }
        if (s.classes > 0) out.add(_Row(Icons.school_outlined, NimbusColors.warning, 'LGU announcement', 'Classes suspended', _classes[s.classes.clamp(0, 5)]));
        if (r.notice.isNotEmpty) out.add(_Row(Icons.campaign_outlined, NimbusColors.primary, 'LGU notice', r.notice, 'From ${t.name} LGU'));
      case 'F':
        for (final i in r.items) {
          final name = i.customName ?? (i.index <= t.floodAreas.length ? t.floodAreas[i.index - 1] : 'Area ${i.index}');
          final color = {'H': NimbusColors.danger, 'M': NimbusColors.warning}[i.level] ?? NimbusColors.ok;
          out.add(_Row(null, color, _level[i.level] ?? '', name, _now[i.now] ?? '', number: i.index));
        }
      case 'E':
        for (final i in r.items) {
          final name = i.index <= t.sites.length ? t.sites[i.index - 1] : 'Site ${i.index}';
          final pct = i.percentFull ?? 0;
          out.add(switch (i.status) {
            'F' => _Row(null, NimbusColors.danger, 'Full', name, 'No room left, go to another site', number: i.index, percent: 100),
            'X' => _Row(null, NimbusColors.muted, 'Closed', name, 'Not taking evacuees', number: i.index),
            _ => _Row(null, pct >= 85 ? NimbusColors.warning : NimbusColors.ok, pct >= 85 ? 'Almost full' : 'Open', name, '$pct% full', number: i.index, percent: pct),
          });
        }
      case 'R':
        for (final i in r.items) {
          final name = i.customName ?? (i.index <= t.roads.length ? t.roads[i.index - 1] : 'Road ${i.index}');
          final s = _road[i.status] ?? ('', '');
          final color = {'X': NimbusColors.danger, 'L': NimbusColors.warning}[i.status] ?? NimbusColors.ok;
          out.add(_Row(null, color, s.$1, name, s.$2, number: i.index));
        }
    }
    out.add(Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(r.valid ? '✓ Signature checked' : '✕ Signature failed, don’t trust this reply',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: r.valid ? NimbusColors.ok : NimbusColors.danger)),
    ));
    if (showRaw && latest != null) {
      out.add(Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: NimbusColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
        child: SelectableText(latest!.sms, style: const TextStyle(fontFamily: 'monospace', color: NimbusColors.primary)),
      ));
    }
    return out;
  }
}

class _Row extends StatelessWidget {
  const _Row(this.icon, this.color, this.tag, this.big, this.sub, {this.number, this.percent});
  final IconData? icon;
  final Color color;
  final String tag;
  final String big;
  final String sub;
  final int? number;
  final int? percent;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: NimbusColors.surfaceAlt, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
            alignment: Alignment.center,
            child: icon != null
                ? Icon(icon, color: NimbusColors.onPrimary)
                : Text('$number', style: const TextStyle(color: NimbusColors.onPrimary, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tag.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: NimbusColors.muted)),
              Text(big, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              Text(sub, style: const TextStyle(fontSize: 13.5, color: NimbusColors.muted)),
              if (percent != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: LinearProgressIndicator(value: percent! / 100, minHeight: 6, color: color, backgroundColor: NimbusColors.surface),
                  ),
                ),
            ]),
          ),
        ]),
      );
}

class _Status extends StatelessWidget {
  const _Status(this.text, this.color, {this.spinner = false});
  final String text;
  final Color color;
  final bool spinner;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: NimbusColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          if (spinner) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          if (spinner) const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
        ]),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.title, this.body);
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(border: Border.all(color: NimbusColors.line, width: 1.5), borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(color: NimbusColors.muted)),
        ]),
      );
}
