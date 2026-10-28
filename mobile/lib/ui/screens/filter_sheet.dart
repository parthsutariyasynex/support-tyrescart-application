import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/repo.dart';
import '../../logic/time.dart';
import '../../state/workspace_data.dart';
import '../widgets/common.dart';

/// "Filter by" (web: FilterMenu): labels, assignees, lifecycle stages, last activity dates and sort order. Within a
/// group any choice matches; across groups all must match (the server applies the same rule).
class FilterSheet extends StatefulWidget {
  const FilterSheet({super.key, required this.query, this.hideStage = false});
  final ConversationQuery query;
  final bool hideStage;
  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late List<String> _labels = [...widget.query.labelIds];
  late List<String> _assignees = [...widget.query.assigneeIds];
  late List<String> _stages = [...widget.query.leadStages];
  late DateTime? _from = widget.query.from;
  late DateTime? _to = widget.query.to;
  late String _sort = widget.query.sort ?? 'newest';

  List<String> _toggle(List<String> list, String id) => list.contains(id) ? (list..remove(id)) : (list..add(id));

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: _from != null && _to != null ? DateTimeRange(start: dubai(_from!), end: dubai(_to!)) : null,
    );
    if (r == null) return;
    setState(() {
      // A Dubai calendar day from its first to its last moment (what the server filters on)
      _from = dubaiInstant(r.start.year, r.start.month, r.start.day);
      _to = dubaiInstant(r.end.year, r.end.month, r.end.day).add(const Duration(hours: 24)).subtract(const Duration(milliseconds: 1));
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WorkspaceData>();
    final stages = data.fieldOptions?.leadStages ?? const [];
    Widget title(String t) => Padding(padding: const EdgeInsets.fromLTRB(0, 16, 0, 8), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)));
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 20), children: [
            Text('Filter by', style: Theme.of(context).textTheme.titleLarge),
            title('Sort'),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'newest', label: Text('Newest first')), ButtonSegment(value: 'oldest', label: Text('Oldest first'))],
              selected: {_sort},
              onSelectionChanged: (s) => setState(() => _sort = s.first),
            ),
            title('Last activity'),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickRange,
                  icon: const Icon(Icons.date_range),
                  label: Text(_from == null ? 'Any time' : '${formatShortDate(_from!)} – ${formatShortDate(_to ?? _from!)}'),
                ),
              ),
              if (_from != null) IconButton(onPressed: () => setState(() => _from = _to = null), icon: const Icon(Icons.close)),
            ]),
            if (!widget.hideStage && stages.isNotEmpty) ...[
              title('Stage'),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final s in stages)
                  FilterChip(
                    avatar: Icon(Icons.circle, size: 12, color: hexColor(s.color, Colors.grey)),
                    label: Text(s.label),
                    selected: _stages.contains(s.value),
                    onSelected: (_) => setState(() => _stages = _toggle(_stages, s.value)),
                  ),
              ]),
            ],
            if (data.labels.isNotEmpty) ...[
              title('Labels'),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final l in data.labels)
                  FilterChip(
                    avatar: Icon(Icons.label, size: 14, color: hexColor(l.color)),
                    label: Text(l.name),
                    selected: _labels.contains(l.id),
                    onSelected: (_) => setState(() => _labels = _toggle(_labels, l.id)),
                  ),
              ]),
            ],
            title('Assigned to'),
            Wrap(spacing: 8, runSpacing: 4, children: [
              FilterChip(label: const Text('Unassigned'), selected: _assignees.contains('unassigned'), onSelected: (_) => setState(() => _assignees = _toggle(_assignees, 'unassigned'))),
              for (final a in data.assignees)
                FilterChip(label: Text(a.name), selected: _assignees.contains(a.id), onSelected: (_) => setState(() => _assignees = _toggle(_assignees, a.id))),
            ]),
            const SizedBox(height: 24),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(children: [
              TextButton(
                onPressed: () => setState(() {
                  _labels = [];
                  _assignees = [];
                  _stages = [];
                  _from = _to = null;
                  _sort = 'newest';
                }),
                child: const Text('Clear all'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  widget.query.copyWith(labelIds: _labels, assigneeIds: _assignees, leadStages: _stages, from: _from, to: _to, clearDates: _from == null, sort: _sort),
                ),
                child: const Text('Apply'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
