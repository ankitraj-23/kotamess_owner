import 'package:flutter/material.dart';

/// Shared branded shell for the sign in / sign up screens so both look
/// consistent without duplicating layout.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.error,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1D4ED8), Color(0xFF0891B2)],
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.restaurant_menu,
                        color: Colors.white, size: 30),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    style: const TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 15),
                  ),
                  const SizedBox(height: 24),
                  if (error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              color: Colors.red.shade700, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              error!,
                              style: TextStyle(color: Colors.red.shade700),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
