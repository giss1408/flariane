"""Builds the launcher icons from the PNGs rendered by tool/render_logo_test.dart.

    flutter test tool/render_logo_test.dart && python3 tool/make_icons.py     (needs Pillow)

Android: legacy icons, adaptive icon (gradient background + foreground + themed monochrome) for the prod flavor,
and the same files with an orange TEST marking for the integration flavor (src/integration/res overrides main).
iOS: the full AppIcon set (square, no transparency). Run `flutter_native_splash` separately for the splash screen.
"""

import json
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
LOGO = ROOT / "assets" / "logo"
RES = ROOT / "android" / "app" / "src" / "main" / "res"
RES_INTEGRATION = ROOT / "android" / "app" / "src" / "integration" / "res"
IOS = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
ORANGE = (245, 158, 11, 255)
FONTS = ["/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/Library/Fonts/Arial Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]

LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def font(size: int) -> ImageFont.FreeTypeFont:
    for f in FONTS:
        if Path(f).exists():
            return ImageFont.truetype(f, size)
    raise SystemExit("No bold font found: edit FONTS in tool/make_icons.py")


def rounded(img: Image.Image, radius_ratio: float = 0.22) -> Image.Image:
    img = img.convert("RGBA")
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=int(img.width * radius_ratio), fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, mask=mask)
    return out


def with_test_band(tile: Image.Image) -> Image.Image:
    """Orange band across the bottom of the legacy icon."""
    img = tile.convert("RGBA")
    d = ImageDraw.Draw(img)
    w = img.width
    top = int(w * 0.72)
    d.rectangle((0, top, w, w), fill=ORANGE)
    f = font(int(w * 0.2))
    text = "TEST"
    box = d.textbbox((0, 0), text, font=f)
    d.text(((w - (box[2] - box[0])) / 2 - box[0], top + (w - top - (box[3] - box[1])) / 2 - box[1]), text, font=f, fill=(255, 255, 255, 255))
    return img


def with_test_pill(foreground: Image.Image) -> Image.Image:
    """Orange pill inside the adaptive icon's safe circle (the mask crops the rest)."""
    img = foreground.convert("RGBA")
    d = ImageDraw.Draw(img)
    w = img.width  # 108 dp
    pw, ph, cy = w * 32 / 108, w * 12 / 108, w * (54 + 26) / 108
    d.rounded_rectangle((w / 2 - pw / 2, cy - ph / 2, w / 2 + pw / 2, cy + ph / 2), radius=ph / 2, fill=ORANGE)
    f = font(int(ph * 0.72))
    box = d.textbbox((0, 0), "TEST", font=f)
    d.text((w / 2 - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]), "TEST", font=f, fill=(255, 255, 255, 255))
    return img


def save(img: Image.Image, path: Path, px: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.resize((px, px), Image.LANCZOS).save(path)


def main() -> None:
    tile = Image.open(LOGO / "tile_full.png").convert("RGBA")
    fg = Image.open(LOGO / "foreground.png").convert("RGBA")

    for res, with_test in ((RES, False), (RES_INTEGRATION, True)):
        legacy = rounded(with_test_band(tile) if with_test else tile)
        foreground = with_test_pill(fg) if with_test else fg
        for density, px in LEGACY.items():
            save(legacy, res / f"mipmap-{density}" / "ic_launcher.png", px)
        for density, px in ADAPTIVE.items():
            save(foreground, res / f"drawable-{density}" / "ic_launcher_foreground.png", px)

    (RES / "drawable").mkdir(parents=True, exist_ok=True)
    (RES / "drawable" / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">\n'
        '    <gradient android:angle="315" android:startColor="#063B39" android:centerColor="#0F5F5C" android:endColor="#2FA39A"/>\n'
        "</shape>\n"
    )
    (RES / "mipmap-anydpi-v26").mkdir(parents=True, exist_ok=True)
    (RES / "mipmap-anydpi-v26" / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@drawable/ic_launcher_foreground"/>\n'
        "</adaptive-icon>\n"
    )

    square = tile.convert("RGB")  # iOS: opaque square, the system rounds it
    for image in json.loads((IOS / "Contents.json").read_text())["images"]:
        m = re.match(r"(\d+(?:\.\d+)?)x\1@(\d)x", f"{image['size']}@{image['scale']}")
        px = round(float(m.group(1)) * int(m.group(2)))
        square.resize((px, px), Image.LANCZOS).save(IOS / image["filename"])
    # Android 12+ crops the splash icon to a circle (middle 2/3): a smaller copy keeps the whole tile and the star visible.
    round_tile = Image.open(LOGO / "tile_round.png").convert("RGBA")
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    size = round(1024 * 0.56)
    canvas.paste(round_tile.resize((size, size), Image.LANCZOS), ((1024 - size) // 2, (1024 - size) // 2))
    canvas.save(LOGO / "splash_android12.png")
    print("icons written")


if __name__ == "__main__":
    main()
