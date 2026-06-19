import 'package:flutter/material.dart';

import '../models/student.dart';
import '../profile/owner_profile.dart';
import '../profile/owner_profile_service.dart';
import '../services/database_service.dart';
import 'meal_plans_screen.dart';

/// Owner settings: profile + base counts, retention window with cleanup,
/// logout and app info. Pushed as its own route from the app bar.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.profile,
    required this.profileService,
    required this.databaseService,
    required this.onProfileUpdated,
    required this.onSignOut,
  });

  final OwnerProfile profile;
  final OwnerProfileService profileService;
  final DatabaseService databaseService;
  final ValueChanged<OwnerProfile> onProfileUpdated;
  final VoidCallback onSignOut;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _ownerName;
  late final TextEditingController _messName;
  late final TextEditingController _phone;
  late final TextEditingController _lunch;
  late final TextEditingController _dinner;
  late final TextEditingController _retention;

  bool _saving = false;
  bool _cleaning = false;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _ownerName = TextEditingController(text: p.ownerName);
    _messName = TextEditingController(text: p.messName);
    _phone = TextEditingController(text: p.phone);
    _lunch = TextEditingController(text: '${p.defaultLunchCount}');
    _dinner = TextEditingController(text: '${p.defaultDinnerCount}');
    _retention = TextEditingController(text: '${p.retentionDays}');
  }

  @override
  void dispose() {
    _ownerName.dispose();
    _messName.dispose();
    _phone.dispose();
    _lunch.dispose();
    _dinner.dispose();
    _retention.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final updated = widget.profile.copyWith(
      ownerName: _ownerName.text.trim(),
      messName: _messName.text.trim(),
      phone: _phone.text.trim(),
      defaultLunchCount: int.parse(_lunch.text.trim()),
      defaultDinnerCount: int.parse(_dinner.text.trim()),
      retentionDays: int.parse(_retention.text.trim()),
    );
    try {
      final saved = await widget.profileService.updateProfile(updated);
      widget.onProfileUpdated(saved);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save settings. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cleanup() async {
    final retention =
        int.tryParse(_retention.text.trim()) ?? widget.profile.retentionDays;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clean old imports?'),
        content: Text(
          'This permanently deletes imported WhatsApp chats older than '
          '$retention days. Your students, meal requests, ledger and account '
          'are not affected.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clean now')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _cleaning = true);
    try {
      final deleted =
          await widget.databaseService.cleanupOldImportedMessages(retention);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted $deleted old imported message(s).')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cleanup failed. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  Future<void> _openMealPlans() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            MealPlansScreen(databaseService: widget.databaseService),
      ),
    );
  }

  Future<void> _openMergeStudents() async {
    final merged = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _MergeStudentsSheet(databaseService: widget.databaseService),
    );
    if (merged == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Students merged.')),
      );
    }
  }

  Future<void> _confirmSignOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again to continue.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) {
      if (mounted) Navigator.pop(context); // close settings first
      widget.onSignOut();
    }
  }

  Future<void> _requestAccountDeletion() async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Request account deletion'),
        content: const Text(
          'Account deletion is not automated yet. To delete your account and '
          'all associated data (imports, requests, customers, billing and '
          'payments), please contact support / your admin and it will be '
          'removed for you.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String? _notEmpty(String? v, String field) =>
      (v == null || v.trim().isEmpty) ? 'Enter $field' : null;

  String? _count(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null) return 'Enter a number';
    if (n < 0) return 'Cannot be negative';
    if (n > 100000) return 'Too large';
    return null;
  }

  String? _retentionValidator(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null) return 'Enter a number';
    if (n < 7 || n > 365) return 'Use 7–365 days';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SettingsCard(
              title: 'Profile',
              icon: Icons.storefront_outlined,
              children: [
                TextFormField(
                  controller: _messName,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Mess name',
                    prefixIcon: Icon(Icons.storefront_outlined),
                  ),
                  validator: (v) => _notEmpty(v, 'a mess name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _ownerName,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Owner name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) => _notEmpty(v, 'your name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone (optional)',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Default daily counts',
              icon: Icons.restaurant_menu,
              children: [
                const Text(
                  'Used as the base count for every day. These default counts '
                  'are used every day until you change them.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Change this only when your regular mess strength changes. '
                  'For one-day changes, use Daily → manual adjustments instead.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _lunch,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Base lunch',
                          prefixIcon: Icon(Icons.lunch_dining),
                        ),
                        validator: _count,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _dinner,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Base dinner',
                          prefixIcon: Icon(Icons.dinner_dining),
                        ),
                        validator: _count,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Retention window',
              icon: Icons.auto_delete_outlined,
              children: [
                const Text(
                  'WhatsApp exports keep growing. Set how many days of imported '
                  'chats to keep, then clean older ones to save space.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _retention,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Retention days (7–365)',
                    prefixIcon: Icon(Icons.history_toggle_off),
                  ),
                  validator: _retentionValidator,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _cleaning ? null : _cleanup,
                    icon: _cleaning
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cleaning_services_outlined),
                    label: const Text('Clean old imported messages'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined),
                label: const Text('Save settings'),
              ),
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Meal plans',
              icon: Icons.restaurant_outlined,
              children: [
                const Text(
                  'Create subscription plans (e.g. "Lunch only", "Full day") '
                  'and assign them to customers. Plans drive the expected '
                  'kitchen counts on your dashboard.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openMealPlans,
                    icon: const Icon(Icons.restaurant_menu_outlined),
                    label: const Text('Manage meal plans'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Students',
              icon: Icons.group_outlined,
              children: [
                const Text(
                  'If the same student appears twice (e.g. "Amit" and '
                  '"Amit Sharma"), merge them. Requests and ledger entries move '
                  'to the student you keep, and the other name becomes an alias.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openMergeStudents,
                    icon: const Icon(Icons.merge_type),
                    label: const Text('Merge duplicate students'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Account',
              icon: Icons.account_circle_outlined,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Signed in as'),
                  subtitle: Text(widget.profile.email.isEmpty
                      ? 'Unknown'
                      : widget.profile.email),
                ),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _confirmSignOut,
                    icon: const Icon(Icons.logout),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFDC2626),
                    ),
                    label: const Text('Log out'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Privacy & Data',
              icon: Icons.privacy_tip_outlined,
              children: [
                const _BulletPoint(
                  'Imported chat text is used only to extract meal requests — '
                  'nothing else.',
                ),
                const _BulletPoint(
                  'Chat imports, extracted requests, customers, billing records '
                  'and payments are stored in your own Supabase account data.',
                ),
                const _BulletPoint(
                  'The Gemini / AI key stays server-side as a Supabase Edge '
                  'Function secret — it is never shipped in the app.',
                ),
                const _BulletPoint(
                  'You can export your records any time using the CSV export '
                  'options on the Requests and Ledger screens.',
                ),
                const _BulletPoint(
                  'You can request deletion of your account and all associated '
                  'data at any time.',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _requestAccountDeletion,
                    icon: const Icon(Icons.delete_forever_outlined),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFDC2626),
                    ),
                    label: const Text('Request account deletion'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'KotaMess Owner · v1.0.0',
                style: TextStyle(color: Colors.black45, fontSize: 12),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon,
                    size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A single plain-language bullet line, styled like the other helper text in
/// the settings cards.
class _BulletPoint extends StatelessWidget {
  const _BulletPoint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  ',
              style: TextStyle(color: Colors.black54, fontSize: 13)),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Merge one student (source, removed) into another (target, kept). Moves the
/// source's meal requests and ledger entries to the target, saves the source's
/// name as an alias, and deletes the source. Requires explicit confirmation.
class _MergeStudentsSheet extends StatefulWidget {
  const _MergeStudentsSheet({required this.databaseService});
  final DatabaseService databaseService;

  @override
  State<_MergeStudentsSheet> createState() => _MergeStudentsSheetState();
}

class _MergeStudentsSheetState extends State<_MergeStudentsSheet> {
  List<Student> _students = [];
  String? _sourceId;
  String? _targetId;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final students = await widget.databaseService.fetchStudents();
      if (!mounted) return;
      setState(() {
        _students = students;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load students.';
      });
    }
  }

  String _nameOf(String? id) {
    for (final s in _students) {
      if (s.id == id) return s.name;
    }
    return '';
  }

  Future<void> _merge() async {
    final source = _sourceId;
    final target = _targetId;
    if (source == null || target == null) {
      setState(() => _error = 'Pick both students.');
      return;
    }
    if (source == target) {
      setState(() => _error = 'Pick two different students.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Merge students?'),
        content: Text(
          'This will move requests and ledger entries from '
          '${_nameOf(source)} to ${_nameOf(target)}. This cannot be easily '
          'undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Merge')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.databaseService
          .mergeStudents(sourceId: source, targetId: target);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not merge. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Merge duplicate students',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_students.length < 2)
              const Text('You need at least two students to merge.')
            else ...[
              DropdownButtonFormField<String>(
                initialValue: _sourceId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Duplicate to remove',
                  prefixIcon: Icon(Icons.person_remove_alt_1_outlined),
                ),
                items: _students
                    .map((s) => DropdownMenuItem(
                        value: s.id,
                        child: Text(s.name, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: _busy ? null : (v) => setState(() => _sourceId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _targetId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Keep this student',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                items: _students
                    .map((s) => DropdownMenuItem(
                        value: s.id,
                        child: Text(s.name, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: _busy ? null : (v) => setState(() => _targetId = v),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _merge,
                  icon: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.merge_type),
                  label: const Text('Merge students'),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
            ],
          ],
        ),
      ),
    );
  }
}
