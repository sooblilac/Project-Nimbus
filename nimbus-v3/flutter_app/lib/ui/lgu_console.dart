import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import '../codec/nimbus_codec.dart' as codec;
import '../data/town_pack.dart';
import '../lgu/lgu_api.dart';
import '../sms/sms_service.dart' show PinSnapshotSender;
import 'theme.dart';

const _classOptions = [
  (0, 'No suspension'),
  (1, 'All levels'),
  (2, 'Preschool to SHS'),
  (3, 'Preschool to grade 10'),
  (4, 'Preschool to grade 6'),
  (5, 'Preschool only'),
];
const _floodLevels = [
  ('H', 'High risk'),
  ('M', 'Medium risk'),
  ('L', 'Low risk'),
];
const _floodStatuses = [
  ('F', 'Flooding now'),
  ('W', 'Water rising / watch'),
  ('C', 'No flooding now'),
];
const _centerStatuses = [('O', 'Open'), ('F', 'Full'), ('X', 'Closed')];
const _roadStatuses = [
  ('O', 'Open to all vehicles'),
  ('L', 'Light vehicles only'),
  ('X', 'Closed'),
];

class LguConsole extends StatefulWidget {
  const LguConsole({
    super.key,
    required this.town,
    required this.api,
    required this.pinSnapshotSender,
    required this.accessToken,
    required this.existingUpdate,
    this.mapPins = const [],
    required this.onMapPinsChanged,
    required this.onRequestPinLocation,
    required this.onCancelPinPlacement,
    this.pinLocationSelection,
    required this.apiLoading,
    required this.apiError,
    required this.onRetry,
    required this.onPublished,
    required this.resetting,
    required this.onReset,
  });

  final Town town;
  final LguApiService api;
  final PinSnapshotSender pinSnapshotSender;
  final String? accessToken;
  final LguUpdate? existingUpdate;
  final List<MapPinUpdate> mapPins;
  final ValueChanged<List<MapPinUpdate>> onMapPinsChanged;
  final ValueChanged<(String category, String label)> onRequestPinLocation;
  final ValueChanged<(String category, String label)> onCancelPinPlacement;
  final MapPinLocationSelection? pinLocationSelection;
  final bool apiLoading;
  final String? apiError;
  final VoidCallback onRetry;
  final ValueChanged<LguUpdate> onPublished;
  final bool resetting;
  final Future<void> Function() onReset;

  @override
  State<LguConsole> createState() => _LguConsoleState();
}

class _LguConsoleState extends State<LguConsole> {
  final _notice = TextEditingController();
  final _newFloodArea = TextEditingController();
  final _newCenter = TextEditingController();
  final _newRoad = TextEditingController();
  late List<_FloodDraft> _floodAreas;
  late List<_CenterDraft> _centers;
  late List<_RoadDraft> _roads;
  int _classes = 0;
  bool _dirty = false;
  bool _publishing = false;
  String? _error;
  String? _success;
  final Set<String> _pendingPinKeys = {};

  @override
  void initState() {
    super.initState();
    _floodAreas = [
      for (final name in widget.town.floodAreas) _FloodDraft(name),
    ];
    _centers = [for (final name in widget.town.sites) _CenterDraft(name)];
    _roads = [for (final name in widget.town.roads) _RoadDraft(name)];
    final update = widget.existingUpdate;
    if (update != null) _applyUpdate(update);
  }

  @override
  void didUpdateWidget(covariant LguConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    final update = widget.existingUpdate;
    if (!_dirty && update != null && update != oldWidget.existingUpdate) {
      _applyUpdate(update);
    }
    for (final pin in widget.mapPins) {
      _pendingPinKeys.remove(_pinKey(pin.category, pin.label));
    }
    final selection = widget.pinLocationSelection;
    if (selection != null &&
        selection.requestId != oldWidget.pinLocationSelection?.requestId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyPinLocationSelection(selection);
      });
    }
  }

  void _applyUpdate(LguUpdate update) {
    _classes = update.classes;
    _notice.text = update.notice;
    _floodAreas = [
      for (final area in update.floodAreas)
        _FloodDraft(
          area.name,
          level: area.level,
          status: area.status,
          custom: !widget.town.floodAreas.contains(area.name),
        ),
    ];
    _centers = [
      for (final center in update.evacuationCenters)
        _CenterDraft(
          center.name,
          status: center.status,
          percentFull: center.percentFull,
          custom: !widget.town.sites.contains(center.name),
        ),
    ];
    _roads =
        update.roadStatuses.isEmpty
            ? [for (final name in widget.town.roads) _RoadDraft(name)]
            : [
              for (final road in update.roadStatuses)
                _RoadDraft(
                  road.name,
                  status: road.status,
                  custom: !widget.town.roads.contains(road.name),
                ),
            ];
  }

  String _pinKey(String category, String label) => '$category|$label';

  MapPinUpdate? _findPin(String category, String label) {
    for (final pin in widget.mapPins) {
      if (pin.category == category && pin.label == label) return pin;
    }
    return null;
  }

  void _setPinEnabled(String category, String label, bool enabled) {
    final key = _pinKey(category, label);
    if (enabled) {
      setState(() {
        _pendingPinKeys.add(key);
        _dirty = true;
      });
      widget.onRequestPinLocation((category, label));
      return;
    }

    setState(() {
      _pendingPinKeys.remove(key);
      _dirty = true;
    });
    widget.onCancelPinPlacement((category, label));
    widget.onMapPinsChanged(
      widget.mapPins
          .where((pin) => pin.category != category || pin.label != label)
          .toList(),
    );
  }

  void _requestPinLocation(String category, String label) {
    widget.onRequestPinLocation((category, label));
  }

  void _updatePinStatus(
    String category,
    String label,
    String status,
    int intensity,
  ) {
    final current = _findPin(category, label);
    if (current == null) return;
    widget.onMapPinsChanged([
      for (final pin in widget.mapPins)
        if (pin.category == category && pin.label == label)
          MapPinUpdate(
            category: category,
            label: label,
            latitude: pin.latitude,
            longitude: pin.longitude,
            status: status,
            intensity: intensity,
          )
        else
          pin,
    ]);
  }

  void _removeMapPin(String category, String label) {
    _pendingPinKeys.remove(_pinKey(category, label));
    widget.onCancelPinPlacement((category, label));
    widget.onMapPinsChanged(
      widget.mapPins
          .where((pin) => pin.category != category || pin.label != label)
          .toList(),
    );
  }

  void _applyPinLocationSelection(MapPinLocationSelection selection) {
    final key = _pinKey(selection.category, selection.label);
    if (!_pendingPinKeys.contains(key) &&
        _findPin(selection.category, selection.label) == null) {
      return;
    }
    final current = _findPin(selection.category, selection.label);
    final status = _pinStatus(selection.category, selection.label);
    if (status == null) {
      _pendingPinKeys.remove(key);
      return;
    }
    widget.onMapPinsChanged([
      for (final pin in widget.mapPins)
        if (pin.category != selection.category || pin.label != selection.label)
          pin,
      MapPinUpdate(
        category: selection.category,
        label: selection.label,
        latitude: selection.latitude,
        longitude: selection.longitude,
        status: status.$1,
        intensity: status.$2,
      ),
    ]);
    if (mounted) {
      setState(() {
        _pendingPinKeys.remove(key);
        _dirty = true;
        _success =
            current == null ? 'Map pin added.' : 'Map pin location updated.';
      });
    }
  }

  (String, int)? _pinStatus(String category, String label) {
    if (category == 'flood') {
      for (final area in _floodAreas) {
        if (area.name == label) {
          final intensity = switch (area.level) {
            'H' => 100,
            'M' => 65,
            _ => 30,
          };
          return (area.status, intensity);
        }
      }
    } else if (category == 'evacuation') {
      for (final center in _centers) {
        if (center.name == label) {
          return (center.status, center.percentFull);
        }
      }
    } else if (category == 'road') {
      for (final road in _roads) {
        if (road.name == label) {
          final intensity = switch (road.status) {
            'X' => 100,
            'L' => 60,
            _ => 15,
          };
          return (road.status, intensity);
        }
      }
    }
    return null;
  }

  Widget _pinControls({required String category, required String label}) {
    final pin = _findPin(category, label);
    final enabled =
        pin != null || _pendingPinKeys.contains(_pinKey(category, label));
    final coordinates =
        pin == null
            ? null
            : '${pin.latitude.toStringAsFixed(5)}, '
                '${pin.longitude.toStringAsFixed(5)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Show on resident map'),
          subtitle: Text(
            coordinates ??
                (enabled ? 'Choose a location on the map' : 'Optional map pin'),
          ),
          value: enabled,
          onChanged:
              _formBlocked
                  ? null
                  : (value) => _setPinEnabled(category, label, value),
        ),
        if (enabled)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed:
                  _formBlocked
                      ? null
                      : () => _requestPinLocation(category, label),
              icon: const Icon(Icons.my_location),
              label: Text(pin == null ? 'Choose map location' : 'Move map pin'),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _notice.dispose();
    _newFloodArea.dispose();
    _newCenter.dispose();
    _newRoad.dispose();
    super.dispose();
  }

  bool get _formBlocked =>
      _publishing ||
      widget.resetting ||
      widget.apiError != null ||
      (widget.apiLoading && widget.existingUpdate == null);

  bool get _publishBlocked => _formBlocked || _publisherSetupMessage != null;

  String? get _publisherSetupMessage => widget.api.publisherSetupMessage(
    widget.town.code,
    accessToken: widget.accessToken,
  );

  void _addFloodArea() {
    final name = _newFloodArea.text.trim();
    if (name.isEmpty || name.length > 60) {
      _showFormError('Enter a flood area name between 1 and 60 characters.');
      return;
    }
    if (_floodAreas.any(
      (area) => area.name.toLowerCase() == name.toLowerCase(),
    )) {
      _showFormError('That flood area is already in the list.');
      return;
    }
    setState(() {
      _floodAreas.add(_FloodDraft(name, level: 'H', status: 'F', custom: true));
      _newFloodArea.clear();
      _dirty = true;
      _error = null;
      _success = null;
    });
  }

  void _addCenter() {
    final name = _newCenter.text.trim();
    if (name.isEmpty || name.length > 60) {
      _showFormError(
        'Enter an evacuation center name between 1 and 60 characters.',
      );
      return;
    }
    if (_centers.any(
      (center) => center.name.toLowerCase() == name.toLowerCase(),
    )) {
      _showFormError('That evacuation center is already in the list.');
      return;
    }
    setState(() {
      _centers.add(_CenterDraft(name, custom: true));
      _newCenter.clear();
      _dirty = true;
      _error = null;
      _success = null;
    });
  }

  void _addRoad() {
    final name = _newRoad.text.trim();
    if (name.isEmpty || name.length > 60) {
      _showFormError('Enter a road name between 1 and 60 characters.');
      return;
    }
    if (_roads.any((road) => road.name.toLowerCase() == name.toLowerCase())) {
      _showFormError('That road is already in the list.');
      return;
    }
    setState(() {
      _roads.add(_RoadDraft(name, custom: true));
      _newRoad.clear();
      _dirty = true;
      _error = null;
      _success = null;
    });
  }

  void _showFormError(String message) {
    setState(() {
      _error = message;
      _success = null;
    });
  }

  Future<void> _publish() async {
    if (_publishBlocked) return;
    setState(() {
      _publishing = true;
      _error = null;
      _success = null;
    });
    final update = LguUpdate(
      townCode: widget.town.code,
      classes: _classes,
      notice: _notice.text.trim(),
      floodAreas: [
        for (final area in _floodAreas)
          FloodAreaUpdate(
            name: area.name,
            level: area.level,
            status: area.status,
          ),
      ],
      evacuationCenters: [
        for (final center in _centers)
          EvacuationCenterUpdate(
            name: center.name,
            status: center.status,
            percentFull: center.percentFull,
          ),
      ],
      roadStatuses: [
        for (final road in _roads)
          RoadStatusUpdate(name: road.name, status: road.status),
      ],
      mapPins: widget.mapPins,
      updatedAt: DateTime.now(),
    );
    try {
      final published = await widget.api.publish(
        widget.town.code,
        update,
        accessToken: widget.accessToken,
      );
      String? pinSyncError;
      try {
        await widget.pinSnapshotSender.sendPinSnapshot(widget.town.code, [
          for (final pin in widget.mapPins)
            codec.MapPin(
              category: pin.category,
              label: pin.label,
              latitude: pin.latitude,
              longitude: pin.longitude,
              status: pin.status,
              intensity: pin.intensity,
            ),
        ]);
      } on StateError catch (error) {
        pinSyncError = error.message.toString();
      } on PlatformException catch (error) {
        pinSyncError = error.message ?? error.code;
      } on DatabaseException catch (error) {
        pinSyncError = error.toString();
      }
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _success =
            pinSyncError == null
                ? 'Update and map-pin snapshot sent for ${widget.town.name}.'
                : 'Update published online for ${widget.town.name}.';
        _error =
            pinSyncError == null
                ? null
                : 'Published online, but SMS pin sync failed: $pinSyncError';
        _dirty = false;
      });
      widget.onPublished(published);
    } on LguApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _error = error.message;
      });
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _error = 'The API returned invalid data: ${error.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'LGU update console',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      Text(
        'Publish current flood, class, evacuation-center and road status for the selected town.',
        style: TextStyle(color: context.nimbusPalette.muted),
      ),
      if (_publisherSetupMessage != null)
        _Message(
          text: _publisherSetupMessage!,
          color: NimbusColors.warning,
          icon: Icons.lock_outline,
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: widget.apiLoading ? null : widget.onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Reload saved town status'),
        ),
      ),
      _CategoryDropdown(
        title: 'Class status',
        subtitle:
            _classOptions.firstWhere((option) => option.$1 == _classes).$2,
        icon: Icons.school_outlined,
        children: [
          DropdownButtonFormField<int>(
            initialValue: _classes,
            decoration: const InputDecoration(labelText: 'Class suspension'),
            items: [
              for (final option in _classOptions)
                DropdownMenuItem(value: option.$1, child: Text(option.$2)),
            ],
            onChanged:
                _formBlocked
                    ? null
                    : (value) => setState(() {
                      _classes = value ?? 0;
                      _dirty = true;
                    }),
          ),
        ],
      ),
      _CategoryDropdown(
        title: 'Flood-prone areas',
        subtitle: '${_floodAreas.length} areas',
        icon: Icons.water_drop_outlined,
        children: [
          _AddRow(
            controller: _newFloodArea,
            label: 'New flood area',
            hint: 'e.g. Purok 3 riverside',
            enabled: !_formBlocked && _floodAreas.length < 30,
            onAdd: _addFloodArea,
          ),
          _EntryListDropdown(
            title: 'Added flood areas',
            count: _floodAreas.length,
            emptyMessage: 'No flood areas have been added for this town.',
            children: [
              for (final area in _floodAreas)
                _StatusCard(
                  key: ValueKey('flood-${area.name}'),
                  title: area.name,
                  summary:
                      '${_floodLevels.firstWhere((item) => item.$1 == area.level).$2} · '
                      '${_floodStatuses.firstWhere((item) => item.$1 == area.status).$2}'
                      '${_pinSummary('flood', area.name)}',
                  action:
                      area.custom
                          ? IconButton(
                            onPressed:
                                _formBlocked
                                    ? null
                                    : () => setState(() {
                                      _floodAreas.remove(area);
                                      _dirty = true;
                                      _removeMapPin('flood', area.name);
                                    }),
                            tooltip: 'Remove ${area.name}',
                            icon: const Icon(Icons.delete_outline),
                          )
                          : null,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: area.level,
                      decoration: const InputDecoration(
                        labelText: 'Risk level',
                      ),
                      items: [
                        for (final option in _floodLevels)
                          DropdownMenuItem(
                            value: option.$1,
                            child: Text(option.$2),
                          ),
                      ],
                      onChanged:
                          _formBlocked
                              ? null
                              : (value) {
                                final level = value ?? 'L';
                                setState(() {
                                  area.level = level;
                                  _dirty = true;
                                });
                                _updatePinStatus(
                                  'flood',
                                  area.name,
                                  area.status,
                                  _floodIntensity(level),
                                );
                              },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: area.status,
                      decoration: const InputDecoration(
                        labelText: 'Current condition',
                      ),
                      items: [
                        for (final option in _floodStatuses)
                          DropdownMenuItem(
                            value: option.$1,
                            child: Text(option.$2),
                          ),
                      ],
                      onChanged:
                          _formBlocked
                              ? null
                              : (value) {
                                final status = value ?? 'C';
                                setState(() {
                                  area.status = status;
                                  _dirty = true;
                                });
                                _updatePinStatus(
                                  'flood',
                                  area.name,
                                  status,
                                  _floodIntensity(area.level),
                                );
                              },
                    ),
                    _pinControls(category: 'flood', label: area.name),
                  ],
                ),
            ],
          ),
        ],
      ),
      _CategoryDropdown(
        title: 'Evacuation centers',
        subtitle: '${_centers.length} centers',
        icon: Icons.home_outlined,
        children: [
          _AddRow(
            controller: _newCenter,
            label: 'New evacuation center',
            hint: 'Enter the center name',
            enabled: !_formBlocked && _centers.length < 20,
            onAdd: _addCenter,
          ),
          _EntryListDropdown(
            title: 'Added evacuation centers',
            count: _centers.length,
            emptyMessage:
                'No evacuation centers have been added for this town.',
            children: [
              for (final center in _centers)
                _StatusCard(
                  key: ValueKey('evacuation-${center.name}'),
                  title: center.name,
                  summary:
                      '${_centerStatuses.firstWhere((item) => item.$1 == center.status).$2} · '
                      '${center.percentFull}% full'
                      '${_pinSummary('evacuation', center.name)}',
                  action:
                      center.custom
                          ? IconButton(
                            onPressed:
                                _formBlocked
                                    ? null
                                    : () => setState(() {
                                      _centers.remove(center);
                                      _dirty = true;
                                      _removeMapPin('evacuation', center.name);
                                    }),
                            tooltip: 'Remove ${center.name}',
                            icon: const Icon(Icons.delete_outline),
                          )
                          : null,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: center.status,
                      decoration: const InputDecoration(
                        labelText: 'Center status',
                      ),
                      items: [
                        for (final option in _centerStatuses)
                          DropdownMenuItem(
                            value: option.$1,
                            child: Text(option.$2),
                          ),
                      ],
                      onChanged:
                          _formBlocked
                              ? null
                              : (value) {
                                setState(() {
                                  center.status = value ?? 'O';
                                  if (center.status == 'F')
                                    center.percentFull = 100;
                                  _dirty = true;
                                });
                                _updatePinStatus(
                                  'evacuation',
                                  center.name,
                                  center.status,
                                  center.percentFull,
                                );
                              },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Occupancy'),
                        Expanded(
                          child: Slider(
                            value: center.percentFull.toDouble(),
                            min: 0,
                            max: 100,
                            divisions: 20,
                            label: '${center.percentFull}%',
                            onChanged:
                                _formBlocked
                                    ? null
                                    : (value) {
                                      setState(() {
                                        center.percentFull = value.round();
                                        _dirty = true;
                                      });
                                      _updatePinStatus(
                                        'evacuation',
                                        center.name,
                                        center.status,
                                        center.percentFull,
                                      );
                                    },
                          ),
                        ),
                        Text('${center.percentFull}%'),
                      ],
                    ),
                    _pinControls(category: 'evacuation', label: center.name),
                  ],
                ),
            ],
          ),
        ],
      ),
      _CategoryDropdown(
        title: 'Road status',
        subtitle: '${_roads.length} roads',
        icon: Icons.add_road,
        children: [
          _AddRow(
            controller: _newRoad,
            label: 'New road',
            hint: 'Enter the road name',
            enabled: !_formBlocked && _roads.length < 30,
            onAdd: _addRoad,
          ),
          _EntryListDropdown(
            title: 'Added roads',
            count: _roads.length,
            emptyMessage: 'No roads have been added for this town.',
            children: [
              for (final road in _roads)
                _StatusCard(
                  key: ValueKey('road-${road.name}'),
                  title: road.name,
                  summary:
                      '${_roadStatuses.firstWhere((item) => item.$1 == road.status).$2}'
                      '${_pinSummary('road', road.name)}',
                  action:
                      road.custom
                          ? IconButton(
                            onPressed:
                                _formBlocked
                                    ? null
                                    : () => setState(() {
                                      _roads.remove(road);
                                      _dirty = true;
                                      _removeMapPin('road', road.name);
                                    }),
                            tooltip: 'Remove ${road.name}',
                            icon: const Icon(Icons.delete_outline),
                          )
                          : null,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: road.status,
                      decoration: const InputDecoration(
                        labelText: 'Road condition',
                      ),
                      items: [
                        for (final option in _roadStatuses)
                          DropdownMenuItem(
                            value: option.$1,
                            child: Text(option.$2),
                          ),
                      ],
                      onChanged:
                          _formBlocked
                              ? null
                              : (value) {
                                final status = value ?? 'O';
                                setState(() {
                                  road.status = status;
                                  _dirty = true;
                                });
                                _updatePinStatus(
                                  'road',
                                  road.name,
                                  status,
                                  _roadIntensity(status),
                                );
                              },
                    ),
                    _pinControls(category: 'road', label: road.name),
                  ],
                ),
            ],
          ),
        ],
      ),
      _CategoryDropdown(
        title: 'Custom advisory',
        subtitle: _notice.text.isEmpty ? 'No advisory' : 'Advisory written',
        icon: Icons.campaign_outlined,
        children: [
          TextField(
            controller: _notice,
            minLines: 2,
            maxLines: 4,
            maxLength: 500,
            enabled: !_formBlocked,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(
              labelText: 'Advisory for residents (optional)',
              hintText: 'Write a public safety advisory for this town',
            ),
          ),
        ],
      ),
      if (widget.apiLoading && widget.existingUpdate == null)
        _Message(
          text: 'Loading the current town report before editing…',
          color: context.nimbusPalette.muted,
          icon: Icons.hourglass_empty,
        ),
      if (widget.apiError != null) ...[
        _Message(
          text: 'Could not load the existing town report: ${widget.apiError}',
          color: NimbusColors.danger,
          icon: Icons.error_outline,
        ),
        OutlinedButton.icon(
          onPressed: widget.apiLoading ? null : widget.onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry loading town report'),
        ),
      ],
      if (_error != null)
        _Message(
          text: _error!,
          color: NimbusColors.danger,
          icon: Icons.error_outline,
        ),
      if (_success != null)
        _Message(
          text: _success!,
          color: NimbusColors.ok,
          icon: Icons.check_circle_outline,
        ),
      FilledButton.icon(
        onPressed: _publishBlocked ? null : _publish,
        icon:
            _publishing
                ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.publish),
        label: Text(_publishing ? 'Publishing…' : 'Publish town update'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _formBlocked ? null : widget.onReset,
        icon:
            widget.resetting
                ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.delete_sweep_outlined),
        label: Text(
          widget.resetting ? 'Resetting town updates…' : 'Reset town updates',
        ),
      ),
    ],
  );

  String _pinSummary(String category, String label) {
    if (_findPin(category, label) != null) return ' · Map pin set';
    if (_pendingPinKeys.contains(_pinKey(category, label))) {
      return ' · Choose map point';
    }
    return '';
  }

  int _floodIntensity(String level) => switch (level) {
    'H' => 100,
    'M' => 65,
    _ => 30,
  };

  int _roadIntensity(String status) => switch (status) {
    'X' => 100,
    'L' => 60,
    _ => 15,
  };
}

class _FloodDraft {
  _FloodDraft(
    this.name, {
    this.level = 'L',
    this.status = 'C',
    this.custom = false,
  });

  final String name;
  String level;
  String status;
  final bool custom;
}

class _CenterDraft {
  _CenterDraft(
    this.name, {
    this.status = 'O',
    this.percentFull = 0,
    this.custom = false,
  });

  final String name;
  String status;
  int percentFull;
  final bool custom;
}

class _RoadDraft {
  _RoadDraft(this.name, {this.status = 'O', this.custom = false});

  final String name;
  String status;
  final bool custom;
}

class _CategoryDropdown extends StatelessWidget {
  const _CategoryDropdown({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.children,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 10),
    color: context.nimbusPalette.surfaceAlt,
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: context.nimbusPalette.muted, fontSize: 12),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      children: children,
    ),
  );
}

class _EntryListDropdown extends StatelessWidget {
  const _EntryListDropdown({
    required this.title,
    required this.count,
    required this.emptyMessage,
    required this.children,
  });

  final String title;
  final int count;
  final String emptyMessage;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text('$title ($count)'),
    subtitle: Text(
      count == 0 ? 'No entries yet' : 'Tap to review, edit or remove',
      style: TextStyle(color: context.nimbusPalette.muted, fontSize: 12),
    ),
    childrenPadding: EdgeInsets.zero,
    children:
        count == 0
            ? [
              Align(alignment: Alignment.centerLeft, child: Text(emptyMessage)),
            ]
            : children,
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    super.key,
    required this.title,
    required this.summary,
    required this.children,
    this.action,
  });

  final String title;
  final String summary;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) => _ExpandableStatusCard(
    title: title,
    summary: summary,
    children: children,
    action: action,
  );
}

class _ExpandableStatusCard extends StatefulWidget {
  const _ExpandableStatusCard({
    required this.title,
    required this.summary,
    required this.children,
    this.action,
  });

  final String title;
  final String summary;
  final List<Widget> children;
  final Widget? action;

  @override
  State<_ExpandableStatusCard> createState() => _ExpandableStatusCardState();
}

class _ExpandableStatusCardState extends State<_ExpandableStatusCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 6),
    color: context.nimbusPalette.surfaceAlt,
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      initiallyExpanded: false,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      title: Text(
        widget.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        widget.summary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.nimbusPalette.muted, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.action != null) widget.action!,
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(Icons.expand_more),
          ),
        ],
      ),
      onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
      children: widget.children,
    ),
  );
}

class _AddRow extends StatelessWidget {
  const _AddRow({
    required this.controller,
    required this.label,
    required this.hint,
    required this.enabled,
    required this.onAdd,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            maxLength: 60,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              counterText: '',
            ),
            onSubmitted: (_) => onAdd(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: enabled ? onAdd : null,
          tooltip: 'Add $label',
          icon: const Icon(Icons.add),
        ),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.color, required this.icon});

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
