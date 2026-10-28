import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../logic/countries.dart';
import '../../logic/rules.dart';
import '../widgets/common.dart';

/// "New chat": country code + number (and a name for a new contact). A number that already has a chat opens that chat
/// instead of a duplicate (the server decides). The first message must be a template, as WhatsApp requires.
class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key});
  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  PhoneCountry _country = phoneCountries.first;
  final _number = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _problem;

  Future<void> _start() async {
    final national = _number.text.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp(r'^0+'), '');
    final p = phoneProblem(_country.dial, national);
    if (p != null) {
      setState(() => _problem = p);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final c = await context.read<Session>().repo.startConversation('${_country.dial}$national', name: _name.text);
      if (mounted) Navigator.pop(context, c);
    } catch (e) {
      if (mounted) setState(() => _problem = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<PhoneCountry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const CountryPicker(),
    );
    if (picked != null) setState(() => _country = picked);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('New chat', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('The first message to a new number must be an approved template.', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 16),
        Row(children: [
          OutlinedButton(
            onPressed: _pickCountry,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
            child: Text('${_country.flag} +${_country.dial}', style: const TextStyle(fontSize: 16)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _number,
              autofocus: true,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
              onChanged: (_) => setState(() => _problem = null),
              onSubmitted: (_) => _start(),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name (optional, for a new contact)')),
        if (_problem != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: _busy ? null : _start,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Start chat'),
        ),
      ]),
    );
  }
}

class CountryPicker extends StatefulWidget {
  const CountryPicker({super.key});
  @override
  State<CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<CountryPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase().replaceAll('+', '');
    final list = phoneCountries.where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || c.dial.startsWith(q) || c.code.toLowerCase() == q).toList();
    return SheetBody(
      fraction: 0.75,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(autofocus: true, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Country or code'), onChanged: (v) => setState(() => _q = v)),
        ),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(icon: Icons.public_off, title: 'No country matches')
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: Text(list[i].flag, style: const TextStyle(fontSize: 24)),
                    title: Text(list[i].name),
                    trailing: Text('+${list[i].dial}'),
                    onTap: () => Navigator.pop(context, list[i]),
                  ),
                ),
        ),
      ]),
    );
  }
}
