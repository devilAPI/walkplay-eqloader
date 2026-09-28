import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../platform/links.dart';
import '../theme.dart';
import '../widgets/section.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    Widget link(IconData icon, String title, String subtitle, String url) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => openLink(context, url),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _header(),
              const SizedBox(height: 12),
              Section(
                title: 'Links',
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    link(
                      Icons.code,
                      'Source code on GitHub',
                      'devilAPI/walkplay-eqloader',
                      repoUrl,
                    ),
                    link(
                      Icons.download_outlined,
                      'Downloads',
                      'Latest releases for every platform',
                      releasesUrl,
                    ),
                    link(
                      Icons.bug_report_outlined,
                      'Report a problem',
                      'Bugs, and whether your dongle works: include the '
                          'diagnostics from Settings → Log',
                      issuesUrl,
                    ),
                    if (!kIsWeb)
                      link(
                        Icons.language,
                        'Web app',
                        'Runs in Chrome, Edge or Opera, no install',
                        webAppUrl,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Section(
                title: 'Credits',
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    link(
                      Icons.headphones_outlined,
                      'AutoEq by Jaakko Pasanen',
                      'Headphone measurements, targets and pre-computed '
                          'profiles',
                      autoEqUrl,
                    ),
                    ListTile(
                      leading: const Icon(Icons.gavel_outlined),
                      title: const Text('Open-source licenses'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: appName,
                        applicationVersion: appVersion,
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'An independent project, not affiliated with Walkplay or '
                  'Crinear. Pushing an EQ writes to your dongle\'s flash.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Palette.muted, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Section(
    title: 'About',
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              appName,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: Palette.accent),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                appVersion,
                style: monoStyle(size: 11, color: Palette.accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Edit parametric EQ and push it to Walkplay-based USB DAC '
          'dongles, like the Crinear Protocol Micro, without the '
          'vendor\'s app. Generates EQ from headphone measurements '
          'with AutoEQ.',
          style: TextStyle(color: Palette.muted),
        ),
      ],
    ),
  );
}
