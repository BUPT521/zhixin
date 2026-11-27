part of 'theme.dart';

/// 一套完整的外观：中性色板，加上由主题色生成的主色家族与提醒色。
///
/// 带色相的只有主色 [brand] 一族与提醒色 [attention] 一族，它们只用在按钮、
/// 链接、选中态与状态标签上，不参与页面与卡片的底色。
class _Palette {
  const _Palette({
    required this.neutral,
    required this.brand,
    required this.brandLight,
    required this.brandContainer,
    required this.onBrandContainer,
    required this.onAccent,
    required this.attention,
    required this.attentionLight,
    required this.onAttentionLight,
  });

  final _NeutralPalette neutral;

  /// 主色，用在链接、选中状态与可操作的元素上。
  final Color brand;

  /// 主色的浅底，用在用户气泡、标签、导航指示块与 Markdown 表头上。
  final Color brandLight;

  /// 主色的容器底色，用在选中芯片与次要按钮上。
  final Color brandContainer;

  /// 压在 [brandContainer] 上的文字颜色。
  final Color onBrandContainer;

  /// 压在主色上的文字或图标颜色。
  final Color onAccent;

  /// 提醒色，用在需要留意的状态与链接的悬停上。
  final Color attention;

  /// 提醒色的浅底，用在草稿与优先这类需要留意的标签上。
  final Color attentionLight;

  /// 压在 [attentionLight] 上的文字颜色。
  final Color onAttentionLight;

  Brightness get brightness => neutral.brightness;
  Color get ink => neutral.ink;
  Color get muted => neutral.muted;
  Color get paper => neutral.paper;
  Color get card => neutral.card;
  Color get code => neutral.code;
  Color get border => neutral.border;
  Color get inputBorder => neutral.inputBorder;
  Color get raised => neutral.raised;
  Color get selectedSurface => neutral.selectedSurface;
  Color get error => neutral.error;
  Color get onError => neutral.onError;
}

/// 主色家族的派生规则。色值全部在 OKLCH 里算：混色只改明度与彩度、保留
/// 主色的色相，调明度时也保留色相，换成别的主题色不会串到邻近的色相上。
///
/// 浅色：主色浅底取主色在白色上的 8%，主色容器取 15%；容器上的文字把主色
/// 压暗 0.10 的明度，压在主色上的文字是白色。
///
/// 深色：主色浅底取主色在黑色上的 15%，主色容器取 30%，明度都不低于抬高的
/// 表面，浅底在纯黑页面与深灰卡片上都看得出来；容器上的文字把主色提亮 0.10，
/// 压在主色上的文字把主色压暗 0.10，压暗之后不足 4.5:1 时继续压暗到够为止，
/// 深色主色的明度低于 0.40 时会压到接近黑色，颜色向黑靠拢。所以明度低于 0.40
/// 的深色主色改用深灰的容器承载浅底，容器上的文字提亮到主色与黑之间。
///
/// 石墨是无彩色，主色家族直接取中性灰：浅色用抬高的表面与容器上的正文色，
/// 深色用抬高的表面与卡片。
///
/// 提醒色默认用琥珀，主题色为橙时改用紫色，避免草稿标签与主按钮同色；这条
/// 规则写在这里，页面不判断。
_Palette _palette(_NeutralPalette neutral, ZhixinAccent accent) {
  final light = neutral.brightness == Brightness.light;
  final primary = accent.primaryFor(neutral.brightness);
  final brand = _Oklch.of(primary);
  final Color brandLight;
  final Color brandContainer;
  final Color onBrandContainer;
  final Color onAccent;
  if (accent._achromatic) {
    // 中性灰的主色家族不按色相生成，直接用表面与卡片两档。
    brandLight = neutral.raised;
    brandContainer = neutral.card;
    onBrandContainer = primary;
    onAccent = light ? const Color(0xFFFFFFFF) : neutral.card;
  } else if (light) {
    brandLight = _place(brand, 0.08, const Color(0xFFFFFFFF));
    brandContainer = _place(brand, 0.15, const Color(0xFFFFFFFF));
    onBrandContainer = _withLightness(brand, brand.lightness - 0.10);
    onAccent = const Color(0xFFFFFFFF);
  } else if (brand.lightness >= 0.40) {
    // 主色在纯黑页面上的 15% 与在深灰卡片上的 15% 取亮的一侧，浅底在这两种
    // 底上都分得出来。
    const darkFloor = 0.33;
    final floor = math.max(darkFloor, _Oklch.of(neutral.raised).lightness);
    brandLight = _place(brand, 0.15, const Color(0xFF000000), floor: floor);
    brandContainer = _place(brand, 0.30, const Color(0xFF000000), floor: floor);
    onBrandContainer = _withLightness(brand, brand.lightness + 0.10);
    onAccent = _onDarkPrimary(brand);
  } else {
    // 深色主色偏暗：浅底与容器同为深灰，文字取亮的一侧。
    brandLight = _place(
      _Oklch(math.max(brand.lightness + 0.08, 0.45), brand.chroma, brand.hue),
      0.35,
      neutral.card,
    );
    brandContainer = brandLight;
    onBrandContainer = _withLightness(brand, brand.lightness + 0.45);
    onAccent = _withLightness(brand, brand.lightness - 0.10);
  }
  final attention = accent == ZhixinAccent.orange
      ? (light ? _violetAttentionLight : _violetAttentionDark)
      : (light ? _amberAttentionLight : _amberAttentionDark);
  return _Palette(
    neutral: neutral,
    brand: primary,
    brandLight: brandLight,
    brandContainer: brandContainer,
    onBrandContainer: onBrandContainer,
    onAccent: onAccent,
    attention: attention.$1,
    attentionLight: attention.$2,
    onAttentionLight: attention.$3,
  );
}

/// 提醒色的三档，依次是提醒色本身、浅底与压在浅底上的文字。
const (Color, Color, Color) _amberAttentionLight = (
  Color(0xFFB45309),
  Color(0xFFFEF1DF),
  Color(0xFF7A3A06),
);
const (Color, Color, Color) _amberAttentionDark = (
  Color(0xFFF0B070),
  Color(0xFF3A2A14),
  Color(0xFFFFDDB8),
);
const (Color, Color, Color) _violetAttentionLight = (
  Color(0xFF7C3AED),
  Color(0xFFF1EAFE),
  Color(0xFF4C1D95),
);
const (Color, Color, Color) _violetAttentionDark = (
  Color(0xFFA78BFA),
  Color(0xFF2A1F4D),
  Color(0xFFE4DAFF),
);

/// [color] 的 [amount] 份与其余 [base] 混色：只混明度与彩度，色相仍取
/// [color]，因为 [base] 是纯白或纯黑，不带色相。[floor] 给出明度下限，
/// 深色下的混色不会暗到与页面分不出。
Color _place(_Oklch color, double amount, Color base, {double floor = 0}) {
  final target = _Oklch.of(base);
  final lightness =
      target.lightness + (color.lightness - target.lightness) * amount;
  return _Oklch(
    math.max(lightness, floor),
    color.chroma * amount,
    color.hue,
  ).toColor();
}

/// 只换明度，色相与彩度照旧；明度超出 0–1 时取到端点上。
Color _withLightness(_Oklch color, double lightness) =>
    _Oklch(lightness.clamp(0, 1), color.chroma, color.hue).toColor();

/// 深色主色上的文字：主色明度减去 0.10 仍能压出 4.5:1 时取这一档，否则一路
/// 压暗到满足 4.5:1 为止。主色越暗，字与主色的间距就越大，最暗到黑色。
Color _onDarkPrimary(_Oklch brand) {
  final primary = brand.toColor();
  Color at(double lightness) => _withLightness(brand, lightness);
  if (_contrastOf(at(brand.lightness - 0.10), primary) >= 4.5) {
    return at(brand.lightness - 0.10);
  }
  var low = 0.0;
  var high = brand.lightness - 0.10;
  for (var i = 0; i < 20; i++) {
    final middle = (low + high) / 2;
    if (_contrastOf(at(middle), primary) >= 4.5) {
      high = middle;
    } else {
      low = middle;
    }
  }
  return at(high);
}

/// 两个颜色的 WCAG 对比度，亮的一方作分子。
double _contrastOf(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}

/// OKLCH 颜色：明度 0–1、彩度与非负、色相按度。用 sRGB 与线性 RGB 之间的
/// 标准换算，超出色域时按端点截断。
class _Oklch {
  const _Oklch(this.lightness, this.chroma, this.hue);

  factory _Oklch.of(Color color) {
    final rgb = color.toARGB32();
    double channel(int shift) {
      final value = ((rgb >> shift) & 0xFF) / 255;
      return value <= 0.04045
          ? value / 12.92
          : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
    }

    final r = channel(16);
    final g = channel(8);
    final b = channel(0);
    final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    final lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
    final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    final bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    final chroma = math.sqrt(a * a + bb * bb);
    return _Oklch(
      lightness,
      chroma,
      chroma < 1e-6 ? 0 : (math.atan2(bb, a) * 180 / math.pi + 360) % 360,
    );
  }

  final double lightness;
  final double chroma;
  final double hue;

  Color toColor() {
    final radians = hue * math.pi / 180;
    final a = chroma * math.cos(radians);
    final b = chroma * math.sin(radians);
    final l = lightness + 0.3963377774 * a + 0.2158037573 * b;
    final m = lightness - 0.1055613458 * a - 0.0638541728 * b;
    final s = lightness - 0.0894841775 * a - 1.2914855480 * b;
    final red =
        4.0767416621 * l * l * l -
        3.3077115913 * m * m * m +
        0.2309699292 * s * s * s;
    final green =
        -1.2684380046 * l * l * l +
        2.6097574011 * m * m * m -
        0.3413193965 * s * s * s;
    final blue =
        -0.0041960863 * l * l * l -
        0.7034186147 * m * m * m +
        1.7076147010 * s * s * s;
    double encode(double value) {
      final clamped = value.clamp(0.0, 1.0);
      final encoded = clamped <= 0.0031308
          ? 12.92 * clamped
          : 1.055 * math.pow(clamped, 1 / 2.4) - 0.055;
      return encoded.clamp(0.0, 1.0);
    }

    return Color.from(
      alpha: 1,
      red: encode(red),
      green: encode(green),
      blue: encode(blue),
    );
  }
}

double _cbrt(double value) => value < 0
    ? -math.pow(-value, 1 / 3).toDouble()
    : math.pow(value, 1 / 3).toDouble();
