import 'package:flutter/material.dart';

/// The look of the app: flat ink on paper, with one loud colour that is only
/// ever used as a highlighter, to mark what is done.
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.paper,
    required this.surface,
    required this.ink,
    required this.muted,
    required this.line,
    required this.highlight,
    required this.onHighlight,
    required this.danger,
  });

  /// The page.
  final Color paper;

  /// Things that sit on the page: dialogs, fields, the navigation bar.
  final Color surface;

  /// Text, and every control drawn in the text's colour.
  final Color ink;

  /// Secondary text.
  final Color muted;

  /// Hairlines and the outlines of empty controls.
  final Color line;

  /// The highlighter.
  final Color highlight;
  final Color onHighlight;
  final Color danger;

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(AppPalette? other, double t) => t < 0.5 || other == null ? this : other;

  static AppPalette of(BuildContext context) => Theme.of(context).extension<AppPalette>()!;
}

/// Blue ink and a yellow highlighter on off-white stock, after two-colour
/// risograph prints.
const _riso = (
  light: AppPalette(
    paper: Color(0xFFF2EEE3),
    surface: Color(0xFFFBF8F0),
    ink: Color(0xFF1E2C74),
    muted: Color(0xFF666C8E),
    line: Color(0xFFD6D0BF),
    highlight: Color(0xFFFFD23F),
    onHighlight: Color(0xFF17225C),
    danger: Color(0xFFC83A27),
  ),
  dark: AppPalette(
    paper: Color(0xFF0E1330),
    surface: Color(0xFF161C40),
    ink: Color(0xFFEDE8DA),
    muted: Color(0xFF9A9FC0),
    line: Color(0xFF2B3263),
    highlight: Color(0xFFFFD23F),
    onHighlight: Color(0xFF17225C),
    danger: Color(0xFFFF8A75),
  ),
);

/// Graphite on cool grey with an acid-lime marker.
const _graphite = (
  light: AppPalette(
    paper: Color(0xFFE9EBE6),
    surface: Color(0xFFF5F6F2),
    ink: Color(0xFF191C19),
    muted: Color(0xFF666B64),
    line: Color(0xFFC9CDC4),
    highlight: Color(0xFFC8F03C),
    onHighlight: Color(0xFF191C19),
    danger: Color(0xFFC2331F),
  ),
  dark: AppPalette(
    paper: Color(0xFF111311),
    surface: Color(0xFF1A1D1A),
    ink: Color(0xFFE8EBE3),
    muted: Color(0xFF979C93),
    line: Color(0xFF2E322D),
    highlight: Color(0xFFC8F03C),
    onHighlight: Color(0xFF191C19),
    danger: Color(0xFFFF8A75),
  ),
);

/// Bottle-green ink on cream with a coral marker, after an account ledger.
const _ledger = (
  light: AppPalette(
    paper: Color(0xFFF0ECDD),
    surface: Color(0xFFF9F6EB),
    ink: Color(0xFF173A2C),
    muted: Color(0xFF61756A),
    line: Color(0xFFD3CEB9),
    highlight: Color(0xFFFF8A65),
    onHighlight: Color(0xFF2A130B),
    danger: Color(0xFFB3261E),
  ),
  dark: AppPalette(
    paper: Color(0xFF0D1F18),
    surface: Color(0xFF142B22),
    ink: Color(0xFFECE7D6),
    muted: Color(0xFF94AB9F),
    line: Color(0xFF244336),
    highlight: Color(0xFFFF8A65),
    onHighlight: Color(0xFF2A130B),
    danger: Color(0xFFFF9C8F),
  ),
);

/// Chosen at build time with `--dart-define=PALETTE=...`.
const _paletteName = String.fromEnvironment('PALETTE', defaultValue: 'riso');

({AppPalette light, AppPalette dark}) get _palettes => switch (_paletteName) {
  'graphite' => _graphite,
  'ledger' => _ledger,
  _ => _riso,
};

const displayFont = 'Bricolage Grotesque';
const bodyFont = 'Instrument Sans';
const monoFont = 'DM Mono';

/// The fonts are variable, so a weight has to be given as an axis value too.
TextStyle _font(String family, double size, int weight, {double? height, double? spacing}) =>
    TextStyle(
      fontFamily: family,
      fontSize: size,
      height: height,
      letterSpacing: spacing,
      fontWeight: FontWeight.values[(weight ~/ 100) - 1],
      fontVariations: [FontVariation('wght', weight.toDouble())],
    );

/// Numbers that line up: counts and progress.
TextStyle monoStyle(BuildContext context, {double size = 14, bool medium = false}) => TextStyle(
  fontFamily: monoFont,
  fontSize: size,
  fontWeight: medium ? FontWeight.w500 : FontWeight.w400,
  color: AppPalette.of(context).ink,
);

const _radius = BorderRadius.all(Radius.circular(6));
const _shape = RoundedRectangleBorder(borderRadius: _radius);

ThemeData appTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? _palettes.dark : _palettes.light;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.ink,
    onPrimary: p.paper,
    secondary: p.highlight,
    onSecondary: p.onHighlight,
    secondaryContainer: p.highlight,
    onSecondaryContainer: p.onHighlight,
    error: p.danger,
    onError: p.paper,
    surface: p.paper,
    onSurface: p.ink,
    onSurfaceVariant: p.muted,
    outline: p.line,
    outlineVariant: p.line,
    surfaceContainerLowest: p.surface,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surface,
    surfaceContainerHighest: p.line,
    surfaceTint: Colors.transparent,
    shadow: Colors.transparent,
  );

  final text = TextTheme(
    displaySmall: _font(displayFont, 40, 700, height: 1.0, spacing: -1.2),
    headlineMedium: _font(displayFont, 30, 700, height: 1.05, spacing: -0.8),
    headlineSmall: _font(displayFont, 24, 700, height: 1.1, spacing: -0.5),
    titleLarge: _font(displayFont, 21, 600, height: 1.15, spacing: -0.3),
    titleMedium: _font(bodyFont, 17, 500, height: 1.25),
    titleSmall: _font(bodyFont, 13, 600, height: 1.2, spacing: 0.9),
    bodyLarge: _font(bodyFont, 17, 400, height: 1.35),
    bodyMedium: _font(bodyFont, 15, 400, height: 1.4),
    bodySmall: _font(bodyFont, 13, 400, height: 1.35),
    labelLarge: _font(bodyFont, 15, 600, height: 1.2),
    labelMedium: _font(bodyFont, 13, 500, height: 1.2),
    labelSmall: _font(bodyFont, 11, 500, height: 1.2, spacing: 0.3),
  ).apply(bodyColor: p.ink, displayColor: p.ink);

  final hairline = BorderSide(color: p.line);
  final inkLine = BorderSide(color: p.ink, width: 1.5);

  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    extensions: [p],
    fontFamily: bodyFont,
    textTheme: text,
    scaffoldBackgroundColor: p.paper,
    canvasColor: p.paper,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.ink.withValues(alpha: 0.06),
    hoverColor: p.ink.withValues(alpha: 0.04),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: p.paper,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
      shape: Border(bottom: hairline),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      elevation: 0,
      height: 64,
      indicatorColor: p.highlight,
      indicatorShape: _shape,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected) ? p.onHighlight : p.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelSmall!.copyWith(
          color: states.contains(WidgetState.selected) ? p.ink : p.muted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.surface,
      indicatorColor: p.highlight,
      indicatorShape: _shape,
      selectedIconTheme: IconThemeData(color: p.onHighlight, size: 22),
      unselectedIconTheme: IconThemeData(color: p.muted, size: 22),
      selectedLabelTextStyle: text.labelSmall,
      unselectedLabelTextStyle: text.labelSmall!.copyWith(color: p.muted),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.ink,
      foregroundColor: p.paper,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: _shape,
      extendedTextStyle: text.labelLarge,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.ink,
        foregroundColor: p.paper,
        disabledBackgroundColor: p.line,
        disabledForegroundColor: p.muted,
        minimumSize: const Size(64, 48),
        shape: _shape,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: const Size(64, 48),
        side: inkLine,
        shape: _shape,
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        shape: _shape,
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.ink, shape: _shape),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      labelStyle: text.bodyMedium!.copyWith(color: p.muted),
      floatingLabelStyle: text.bodyMedium!.copyWith(color: p.ink),
      hintStyle: text.bodyLarge!.copyWith(color: p.muted.withValues(alpha: 0.7)),
      border: OutlineInputBorder(borderRadius: _radius, borderSide: hairline),
      enabledBorder: OutlineInputBorder(borderRadius: _radius, borderSide: hairline),
      focusedBorder: OutlineInputBorder(borderRadius: _radius, borderSide: inkLine),
      errorBorder: OutlineInputBorder(
        borderRadius: _radius,
        borderSide: BorderSide(color: p.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: _radius,
        borderSide: BorderSide(color: p.danger, width: 1.5),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(_shape),
        side: WidgetStatePropertyAll(inkLine),
        textStyle: WidgetStatePropertyAll(text.labelMedium),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.ink : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return p.paper;
          return states.contains(WidgetState.disabled) ? p.muted : p.ink;
        }),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: p.ink,
      checkmarkColor: p.paper,
      side: inkLine,
      shape: _shape,
      labelStyle: text.labelMedium,
      secondaryLabelStyle: text.labelMedium!.copyWith(color: p.paper),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
      side: inkLine,
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.highlight : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(p.onHighlight),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStatePropertyAll(p.ink),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.highlight : Colors.transparent,
      ),
      thumbColor: WidgetStatePropertyAll(p.ink),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.ink,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodySmall!.copyWith(color: p.muted),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        side: inkLine,
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: _radius, side: inkLine),
      textStyle: text.bodyMedium,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(textStyle: text.bodyMedium),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.ink,
      contentTextStyle: text.bodyMedium!.copyWith(color: p.paper),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: _shape,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.ink, borderRadius: _radius),
      textStyle: text.labelSmall!.copyWith(color: p.paper),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.ink, linearTrackColor: p.line),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: p.muted,
      collapsedIconColor: p.muted,
      textColor: p.muted,
      collapsedTextColor: p.muted,
    ),
  );
}
