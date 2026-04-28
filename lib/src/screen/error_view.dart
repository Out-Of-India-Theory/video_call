import 'package:flutter/material.dart';
import '../errors.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.code,
    required this.message,
    this.onRetry,
    this.onOpenSettings,
  });

  final OitVideoCallErrorCode code;
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              children: [
                if (onRetry != null)
                  FilledButton(
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
                if (onOpenSettings != null)
                  OutlinedButton(
                    onPressed: onOpenSettings,
                    child: const Text('Open Settings'),
                  ),
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
