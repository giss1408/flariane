import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Network image cached on disk. Screenshot links are signed (their query string changes), so the
/// cache key is the address without the query: the same image is downloaded once, not at every visit.
class CachedImage extends StatelessWidget {
  const CachedImage(this.url, {super.key, this.width, this.height, this.fit, this.alignment = Alignment.center, this.errorText});

  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Alignment alignment;
  final String? errorText;

  static String keyFor(String url) => Uri.parse(url).replace(query: '').toString();

  @override
  Widget build(BuildContext context) => CachedNetworkImage(
        imageUrl: url,
        cacheKey: keyFor(url),
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        // Decode at display size: less memory, no full-size decode for a thumbnail.
        memCacheHeight: height == null ? null : (height! * MediaQuery.devicePixelRatioOf(context)).round(),
        placeholder: (_, __) => SizedBox(height: height, width: width, child: const Center(child: CircularProgressIndicator())),
        errorWidget: (_, __, ___) => SizedBox(
          height: height == null ? 120 : height! / 2,
          child: Center(child: Text(errorText ?? 'Image indisponible, tire pour rafraîchir', textAlign: TextAlign.center)),
        ),
      );
}
