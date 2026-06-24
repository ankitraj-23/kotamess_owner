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
    required this.onDataReset,
  });

  final OwnerProfile profile;
  final OwnerProfileService profileService;
  final DatabaseService databaseService;
  final ValueChanged<OwnerProfile> onProfileUpdated;
  final VoidCallback onSignOut;

  /// Called after "Reset app data" succeeds so the shell can refresh every tab
  /// (including clearing the still-mounted Import screen's local draft).
  final VoidCallback onDataReset;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _ownerName;
  late final TextEditingController _messName;
  late final TextEditingController _phone;
  late final TextEditingController _retention;
  late final TextEditingController _cutoffMinutes;

  // Meal serving times, edited via the native time picker.
  late TimeOfDay _lunchTime;
  late TimeOfDay _dinnerTime;

  bool _saving = false;
  bool _cleaning = false;
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _ownerName = TextEditingController(text: p.ownerName);
    _messName = TextEditingController(text: p.messName);
    _phone = TextEditingController(text: p.phone);
    _retention = TextEditingController(text: '${p.retentionDays}');
    _cutoffMinutes = TextEditingController(text: '${p.requestCutoffMinutes}');
    _lunchTime = _parseTime(p.lunchTime, const TimeOfDay(hour: 13, minute: 0));
    _dinnerTime = _parseTime(p.dinnerTime, const TimeOfDay(hour: 20, minute: 0));
  }

  @override
  void dispose() {
    _ownerName.dispose();
    _messName.dispose();
    _phone.dispose();
    _retention.dispose();
    _cutoffMinutes.dispose();
    super.dispose();
  }

  /// Parse a stored `'HH:mm'` string into a [TimeOfDay], using [fallback] for
  /// null/garbage values.
  TimeOfDay _parseTime(String hhmm, TimeOfDay fallback) {
    final parts = hhmm.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h != null && m != null && h >= 0 && h < 24 && m >= 0 && m < 60) {
        return TimeOfDay(hour: h, minute: m);
      }
    }
    return fallback;
  }

  /// Format a [TimeOfDay] as a 24-hour `'HH:mm'` string for storage.
  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime(TimeOfDay current, ValueChanged<TimeOfDay> onPicked) async {
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked != null) onPicked(picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final updated = widget.profile.copyWith(
      ownerName: _ownerName.text.trim(),
      messName: _messName.text.trim(),
      phone: _phone.text.trim(),
      retentionDays: int.parse(_retention.text.trim()),
      lunchTime: _formatTime(_lunchTime),
      dinnerTime: _formatTime(_dinnerTime),
      requestCutoffMinutes: int.parse(_cutoffMinutes.text.trim()),
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
          'This permanently deletes old import history (imported WhatsApp chat '
          'text) older than $retention days. Your customers, meal requests, '
          'ledger, billing and account are not affected.',
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
        SnackBar(content: Text('Deleted $deleted old import record(s).')),
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

  /// Dangerous: deletes ALL app data for the current signed-in account (but not
  /// the account/email/password itself). Two-step confirm; the final delete is
  /// only enabled after the owner types `RESET`.
  Future<void> _resetData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _ResetDataDialog(),
    );
    if (confirmed != true) return;
    setState(() => _resetting = true);
    try {
      await widget.databaseService.resetCurrentOwnerData();
      // Pull the (preserved) profile back with its operational values reset, so
      // the rest of the app rebuilds against a fresh, empty account.
      final fresh = await widget.profileService.fetchProfile();
      if (!mounted) return;
      if (fresh != null) widget.onProfileUpdated(fresh);
      // Refresh every tab and clear the Import screen's local draft, even
      // though it stays mounted in the bottom-tab shell.
      widget.onDataReset();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All app data was reset for your account.')),
      );
      Navigator.of(context).pop(); // back to a fresh dashboard
    } catch (_) {
      if (!mounted) return;
      setState(() => _resetting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not reset data. Please try again.')),
      );
    }
  }

  String? _notEmpty(String? v, String field) =>
      (v == null || v.trim().isEmpty) ? 'Enter $field' : null;

  String? _retentionValidator(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null) return 'Enter a number';
    if (n < 7 || n > 365) return 'Use 7–365 days';
    return null;
  }

  String? _cutoffValidator(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null) return 'Enter a number';
    if (n < 0 || n > 360) return 'Use 0–360 minutes';
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
            const _SettingsCard(
              title: 'Default daily counts',
              icon: Icons.restaurant_menu,
              children: [
                Text(
                  'The base lunch and dinner count for every day is automatically '
                  'your current number of active customers. Pausing or removing a '
                  'customer lowers it; adding one raises it.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                SizedBox(height: 6),
                Text(
                  'For one-day changes, use Daily → manual adjustments instead.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Meal request cutoff',
              icon: Icons.schedule_outlined,
              children: [
                const Text(
                  'Set when each meal is served and how early students must '
                  'send a change, cancel, add or delay request. Requests that '
                  'arrive later than the cutoff are flagged for your review.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 12),
                _TimeField(
                  label: 'Lunch time',
                  icon: Icons.lunch_dining,
                  time: _lunchTime,
                  onTap: () => _pickTime(
                      _lunchTime, (t) => setState(() => _lunchTime = t)),
                ),
                const SizedBox(height: 12),
                _TimeField(
                  label: 'Dinner time',
                  icon: Icons.dinner_dining,
                  time: _dinnerTime,
                  onTap: () => _pickTime(
                      _dinnerTime, (t) => setState(() => _dinnerTime = t)),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _cutoffMinutes,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Cutoff minutes before meal (0–360)',
                    helperText: 'Default 60 (1 hour before the meal)',
                    prefixIcon: Icon(Icons.timer_outlined),
                  ),
                  validator: _cutoffValidator,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Retention window',
              icon: Icons.auto_delete_outlined,
              children: [
                const Text(
                  'WhatsApp exports keep growing. Set how many days of import '
                  'history (imported chat text) to keep, then clean older ones '
                  'to save space.',
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
                    label: const Text('Clean old import history'),
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
                const _BulletPoint(
                  'Reset app data clears your customers, imports, requests, '
                  'daily adjustments, ledger, payments, meal plans, bills and '
                  'audit logs — but keeps your account so you can start fresh.',
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
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _resetting ? null : _resetData,
                    icon: _resetting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.restart_alt),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                    ),
                    label: const Text('Reset app data'),
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

/// A tappable, read-only field that shows a time and opens the native time
/// picker on tap. Styled like the other [InputDecoration] fields on this screen.
class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.icon,
    required this.time,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final TimeOfDay time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: const Icon(Icons.edit_outlined, size: 18),
        ),
        child: Text(time.format(context)),
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

/// Two-step destructive confirmation for "Reset app data". Explains the
/// consequences, then requires the owner to type `RESET` before the final
/// (visually destructive) button enables. Pops `true` only on confirmation.
class _ResetDataDialog extends StatefulWidget {
  const _ResetDataDialog();

  @override
  State<_ResetDataDialog> createState() => _ResetDataDialogState();
}

class _ResetDataDialogState extends State<_ResetDataDialog> {
  final _controller = TextEditingController();
  static const _phrase = 'RESET';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canReset = _controller.text.trim() == _phrase;
    return AlertDialog(
      scrollable: true,
      title: const Text('Reset app data?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently deletes ALL app data for this account: customers, '
            'imports, requests, daily adjustments, ledger, payments, meal plans, '
            'bills and audit logs. This cannot be undone.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Your account, email and password are NOT deleted — you stay signed '
            'in and can start fresh.',
            style: TextStyle(color: Colors.black54, fontSize: 13),
          ),
          const SizedBox(height: 14),
          const Text('Type RESET to confirm:',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              hintText: _phrase,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canReset ? () => Navigator.pop(context, true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFDC2626),
          ),
          child: const Text('Delete everything'),
        ),
      ],
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
