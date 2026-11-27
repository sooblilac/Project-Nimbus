import 'package:flutter/material.dart';

import '../data/philippine_location.dart';
import 'theme.dart';

class LocationPicker extends StatelessWidget {
  const LocationPicker({
    super.key,
    required this.location,
    required this.locations,
    required this.onSelected,
  });

  final PhilippineLocation location;
  final List<PhilippineLocation> locations;
  final ValueChanged<PhilippineLocation> onSelected;

  Future<void> _open(BuildContext context) async {
    final selected = await showLocationPicker(context, locations, location);
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => _buildCard(context);
}

/// Full-screen town search; returns the chosen town, or null if dismissed.
Future<PhilippineLocation?> showLocationPicker(
  BuildContext context,
  List<PhilippineLocation> locations,
  PhilippineLocation location,
) {
    return showModalBottomSheet<PhilippineLocation>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.nimbusPalette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder:
          (context) =>
              _LocationSearchSheet(locations: locations, selected: location),
    );
}

extension on LocationPicker {
  Widget _buildCard(BuildContext context) => Semantics(
    button: true,
    label: 'Choose town or city. ${location.searchLabel}',
    child: InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.nimbusPalette.surfaceAlt,
          border: Border.all(color: context.nimbusPalette.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.location_on_outlined, color: NimbusColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    location.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${location.contextLabel} · ${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.nimbusPalette.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.search, color: context.nimbusPalette.muted),
          ],
        ),
      ),
    ),
  );
}

class _LocationSearchSheet extends StatefulWidget {
  const _LocationSearchSheet({required this.locations, required this.selected});

  final List<PhilippineLocation> locations;
  final PhilippineLocation selected;

  @override
  State<_LocationSearchSheet> createState() => _LocationSearchSheetState();
}

class _LocationSearchSheetState extends State<_LocationSearchSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final filtered =
        query.isEmpty
            ? widget.locations
            : widget.locations
                .where((location) {
                  final searchable =
                      '${location.name} ${location.province} ${location.region} ${location.code}'
                          .toLowerCase();
                  return searchable.contains(query);
                })
                .toList(growable: false);

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.88,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.nimbusPalette.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Choose a location',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.locations.length} Philippine cities and municipalities · searchable offline',
              style: TextStyle(color: context.nimbusPalette.muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Search town or city',
                hintText: 'Name, province or PSGC code',
                prefixIcon: const Icon(Icons.search),
                suffixIcon:
                    _query.isEmpty
                        ? null
                        : IconButton(
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close),
                        ),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Expanded(
              child:
                  filtered.isEmpty
                      ? const Center(child: Text('No matching town or city.'))
                      : ListView.separated(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: filtered.length,
                        separatorBuilder:
                            (_, __) => Divider(
                              height: 1,
                              color: context.nimbusPalette.line,
                            ),
                        itemBuilder: (context, index) {
                          final candidate = filtered[index];
                          final selected =
                              candidate.code == widget.selected.code;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            title: Text(
                              candidate.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${candidate.contextLabel}\nLat ${candidate.latitude.toStringAsFixed(5)} · Lon ${candidate.longitude.toStringAsFixed(5)}',
                            ),
                            isThreeLine: true,
                            trailing:
                                selected
                                    ? const Icon(
                                      Icons.check,
                                      color: NimbusColors.primary,
                                    )
                                    : null,
                            onTap: () => Navigator.pop(context, candidate),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}
