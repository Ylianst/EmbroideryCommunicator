import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const String projectUrl = 'https://github.com/Ylianst/EmbroideryCommunicator';

/// Shows the standard about dialog with the app version, license and project link.
Future<void> showAppAbout(BuildContext context) async {
  final info = await PackageInfo.fromPlatform();
  if (!context.mounted) return;
  showAboutDialog(
    context: context,
    applicationName: 'Embroidery Communicator',
    applicationVersion: 'Version ${info.version} (build ${info.buildNumber})',
    applicationIcon: const Icon(Icons.memory, size: 48),
    applicationLegalese: '© 2025 Ylian Saint-Hilaire · Apache License 2.0',
    children: [
      const SizedBox(height: 12),
      const Text(
        'Cross-platform tool to upload, download and manage embroidery '
        'patterns on Bernina Artista machines over serial or network.',
      ),
      const SizedBox(height: 12),
      InkWell(
        onTap: () => launchUrl(Uri.parse(projectUrl)),
        child: Text(
          projectUrl,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    ],
  );
}
