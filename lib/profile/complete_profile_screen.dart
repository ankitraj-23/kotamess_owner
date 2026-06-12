import 'package:flutter/material.dart';

import '../auth/auth_scaffold.dart';
import 'owner_profile.dart';
import 'owner_profile_service.dart';

/// Fallback shown only when an authenticated user has no `owner_profiles` row
/// AND no usable owner/mess name in their sign-up metadata to build one from
/// (e.g. an account created outside the normal sign-up screen). The normal
/// sign-up path creates the profile from metadata, so this never appears for it.
class CompleteProfileScreen extends StatefulWidget {
  const CompleteProfileScreen({
    super.key,
    required this.profileService,
    required this.onCompleted,
    required this.onSignOut,
  });

  final OwnerProfileService profileService;
  final ValueChanged<OwnerProfile> onCompleted;
  final VoidCallback onSignOut;

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ownerName = TextEditingController();
  final _messName = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ownerName.dispose();
    _messName.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = await widget.profileService.upsertProfile(
        ownerName: _ownerName.text,
        messName: _messName.text,
        phone: _phone.text,
      );
      widget.onCompleted(profile);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save profile. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Finish your profile',
      subtitle: 'A couple of details before you start.',
      error: _error,
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            TextFormField(
              controller: _ownerName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your name',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _messName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Mess name',
                prefixIcon: Icon(Icons.storefront_outlined),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Enter your mess name'
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone (optional)',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save and continue'),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : widget.onSignOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
