import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';

/// One legal text: the "En bref" summary first, then the full text in sections you can open.
class LegalDocScreen extends ConsumerWidget {
  const LegalDocScreen({super.key, required this.slug, this.title});

  final String slug;

  /// Shown in the header while the text loads.
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(legalDocProvider(slug));
    return Scaffold(
      appBar: FlarianeHeader(subtitle: doc.valueOrNull?.title ?? title ?? 'Infos et légal'),
      body: doc.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(legalDocProvider(slug))),
        data: (d) => ListView(padding: const EdgeInsets.all(16), children: [
          _Brief(d.summary),
          const SizedBox(height: 12),
          for (final (i, s) in d.sections.indexed) _SectionTile(s, initiallyExpanded: i == 0),
          const SizedBox(height: 12),
          Text('Dernière mise à jour : ${d.updatedLabel}', style: TextStyle(color: context.pal.muted, fontSize: 13), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

/// The 3 lines most people actually read.
class _Brief extends StatelessWidget {
  const _Brief(this.lines);

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: context.pal.lilac, borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.bolt_rounded, color: context.pal.accent),
            const SizedBox(width: 6),
            Text('En bref', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: context.pal.accent)),
          ]),
          const SizedBox(height: 8),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.check_circle_rounded, size: 18, color: context.pal.accent)),
                const SizedBox(width: 8),
                Expanded(child: Text(l, style: const TextStyle(fontSize: 15, height: 1.35))),
              ]),
            ),
        ]),
      );
}

class _SectionTile extends StatelessWidget {
  const _SectionTile(this.section, {required this.initiallyExpanded});

  final LegalSection section;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: initiallyExpanded,
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            title: Text(section.heading, style: const TextStyle(fontWeight: FontWeight.w700)),
            children: [
              for (final p in section.paragraphs)
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(p, style: const TextStyle(height: 1.45))),
              for (final b in section.bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('•  '),
                    Expanded(child: Text(b, style: const TextStyle(height: 1.4))),
                  ]),
                ),
            ],
          ),
        ),
      );
}
