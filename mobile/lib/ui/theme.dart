import 'package:flutter/material.dart';

/// WhatsApp-style colours, light and dark
class ChatColors extends ThemeExtension<ChatColors> {
  const ChatColors({
    required this.chatBackground,
    required this.outgoing,
    required this.incoming,
    required this.note,
    required this.noteBorder,
    required this.meta,
    required this.tickRead,
    required this.system,
    required this.unreadBadge,
    required this.mention,
    required this.homeBar,
    required this.homeTitle,
    required this.searchFill,
    required this.chipFill,
    required this.chipSelected,
    required this.chipSelectedText,
  });

  final Color chatBackground, outgoing, incoming, note, noteBorder, meta, tickRead, system, unreadBadge, mention;
  /// Home screen (WhatsApp's main tabs): bar, title, search field, filter chips
  final Color homeBar, homeTitle, searchFill, chipFill, chipSelected, chipSelectedText;

  static const light = ChatColors(
    chatBackground: Color(0xFFEFEAE2),
    outgoing: Color(0xFFD9FDD3),
    incoming: Colors.white,
    note: Color(0xFFFFF4C2),
    noteBorder: Color(0xFFF2D675),
    meta: Color(0xFF667781),
    tickRead: Color(0xFF53BDEB),
    system: Color(0xFFFFFFFF),
    unreadBadge: Color(0xFF25D366),
    mention: Color(0xFF027EB5),
    homeBar: Colors.white,
    homeTitle: Color(0xFF1DAA61),
    searchFill: Color(0xFFF0F2F5),
    chipFill: Color(0xFFF0F2F5),
    chipSelected: Color(0xFFD8FDD2),
    chipSelectedText: Color(0xFF15603E),
  );

  static const dark = ChatColors(
    chatBackground: Color(0xFF0B141A),
    outgoing: Color(0xFF005C4B),
    incoming: Color(0xFF202C33),
    note: Color(0xFF3B3314),
    noteBorder: Color(0xFF7A6420),
    meta: Color(0xFF8696A0),
    tickRead: Color(0xFF53BDEB),
    system: Color(0xFF182229),
    unreadBadge: Color(0xFF00A884),
    mention: Color(0xFF53BDEB),
    homeBar: Color(0xFF0B141A),
    homeTitle: Color(0xFFE9EDEF),
    searchFill: Color(0xFF1F272A),
    chipFill: Color(0xFF1F272A),
    chipSelected: Color(0xFF103629),
    chipSelectedText: Color(0xFFD9FDD3),
  );

  @override
  ChatColors copyWith() => this;

  @override
  ChatColors lerp(ChatColors? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension ChatColorsX on BuildContext {
  ChatColors get chat => Theme.of(this).extension<ChatColors>()!;
}

const waGreen = Color(0xFF008069);
const waAccent = Color(0xFF25D366);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: waGreen,
    brightness: b,
    primary: dark ? const Color(0xFF00A884) : waGreen,
    surface: dark ? const Color(0xFF0B141A) : Colors.white,
  );
  final chat = dark ? ChatColors.dark : ChatColors.light;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF0B141A) : Colors.white,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF202C33) : waGreen,
      foregroundColor: dark ? const Color(0xFFE9EDEF) : Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: dark ? const Color(0xFF00A884) : waAccent,
      foregroundColor: dark ? const Color(0xFF111B21) : Colors.white,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: chat.homeBar,
      indicatorColor: chat.chipSelected,
      surfaceTintColor: Colors.transparent,
      height: 68,
      iconTheme: WidgetStateProperty.resolveWith((s) =>
          IconThemeData(color: s.contains(WidgetState.selected) ? chat.chipSelectedText : (dark ? const Color(0xFFE9EDEF) : const Color(0xFF3B4A54)))),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontSize: 12.5,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: dark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21))),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: chat.chipFill,
      selectedColor: chat.chipSelected, 
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(color: dark ? const Color(0xFF8696A0) : const Color(0xFF54656F), fontWeight: FontWeight.w500),
      secondaryLabelStyle: TextStyle(color: chat.chipSelectedText, fontWeight: FontWeight.w600),
      showCheckmark: false,
    ),
    dividerTheme: DividerThemeData(color: dark ? const Color(0xFF222D34) : const Color(0xFFE9EDEF), space: 1, thickness: 1),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    extensions: [chat],
  );
}
