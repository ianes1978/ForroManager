import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/api_level.dart';
import '../../state/providers.dart';

/// Pagina predefinita da cui scaricare l'APK, se il server non ne indica una.
const _defaultDownloadUrl = 'https://github.com/ianes1978/ForroManager/releases';

/// Avviso quando app e server non sono allineati:
/// - app più vecchia del server: va scaricato e installato l'APK aggiornato;
/// - server più vecchio dell'app: va fatto il deploy.
class VersionBanner extends ConsumerStatefulWidget {
  const VersionBanner({super.key});
  @override
  ConsumerState<VersionBanner> createState() => _VersionBannerState();
}

class _VersionBannerState extends ConsumerState<VersionBanner> {
  int? _dismissedFor;

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(versionInfoProvider);
    final server = ref.watch(serverApiLevelProvider);
    if (server == null || server == kApiLevel || _dismissedFor == server) return const SizedBox.shrink();
    final appIsOld = server > kApiLevel;
    final theme = Theme.of(context);
    final url = info.value?.appDownloadUrl ?? _defaultDownloadUrl;
    final text = appIsOld
        ? (kIsWeb
            ? 'È disponibile una versione più nuova: ricarica la pagina.'
            : 'È uscita una versione più nuova dell\'app: scaricala e installala sopra questa. Finché non la aggiorni alcune funzioni potrebbero non andare.')
        : 'Il server non è ancora aggiornato a questa versione dell\'app: alcune funzioni nuove non andranno. '
            'Chi gestisce l\'app deve avviare il deploy (GitHub → Actions → Cloudflare - deploy).';
    return Material(
      color: appIsOld ? theme.colorScheme.primaryContainer : theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(children: [
            Icon(appIsOld ? Icons.system_update : Icons.cloud_off_outlined),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
            if (appIsOld && !kIsWeb)
              TextButton(
                onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                child: const Text('Scarica'),
              ),
            // Niente tooltip: l'avviso sta sopra il Navigator, dove non c'è un Overlay.
            IconButton(icon: const Icon(Icons.close, semanticLabel: 'Chiudi'), onPressed: () => setState(() => _dismissedFor = server)),
          ]),
        ),
      ),
    );
  }
}
