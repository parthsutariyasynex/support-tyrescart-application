import 'package:intl/intl.dart';

// Every date and time in the app is shown in Dubai time, like the website (client/lib/time.ts), whatever the
// phone's own time zone is. Dubai has no daylight saving time, so it is always UTC+4.
const dubaiOffset = Duration(hours: 4);

/// The wall-clock time in Dubai, as a UTC DateTime whose fields read as Dubai's (for formatting and day maths)
DateTime dubai(DateTime when) => when.toUtc().add(dubaiOffset);

/// The instant that is [hour]:00 on a Dubai calendar day
DateTime dubaiInstant(int year, int month, int day, [int hour = 0, int minute = 0]) => DateTime.utc(year, month, day, hour, minute).subtract(dubaiOffset);

String dayKey(DateTime when) => DateFormat('yyyy-MM-dd').format(dubai(when));

int daysAgo(DateTime when, DateTime now) {
  final a = dubai(when), b = dubai(now);
  return DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}

/// 14:16
String formatTime(DateTime when) => DateFormat('HH:mm').format(dubai(when));

/// 10 Oct 2026, 14:16
String formatDateTime(DateTime when) => DateFormat('d MMM yyyy, HH:mm').format(dubai(when));

/// 10 Oct (this year) or 10 Oct 2025
String formatShortDate(DateTime when, [DateTime? now]) {
  final n = now ?? DateTime.now();
  return dubai(when).year == dubai(n).year ? DateFormat('d MMM').format(dubai(when)) : DateFormat('d MMM yyyy').format(dubai(when));
}

/// Chat separators, WhatsApp style: Today, Yesterday, Sat, 10 Oct (this year) or Sat, 10 Oct 2025
String dayLabel(DateTime when, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final d = daysAgo(when, n);
  if (d == 0) return 'Today';
  if (d == 1) return 'Yesterday';
  return dubai(when).year == dubai(n).year ? DateFormat('EEE, d MMM').format(dubai(when)) : DateFormat('EEE, d MMM yyyy').format(dubai(when));
}

/// Conversation list: the time for today, "Yesterday", otherwise a short date
String listTimestamp(DateTime when, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final d = daysAgo(when, n);
  if (d == 0) return formatTime(when);
  if (d == 1) return 'Yesterday';
  return formatShortDate(when, n);
}

/// "15 Oct, 14:16"
String snoozedUntilText(DateTime? when) => when == null ? '' : '${DateFormat('d MMM').format(dubai(when))}, ${formatTime(when)}';

class SnoozeChoice {
  SnoozeChoice(this.label, this.until);
  final String label;
  final DateTime until;
}

/// Snooze choices in the chat menu (web: snoozeChoices). Tomorrow and Monday wake at the business day's start hour.
List<SnoozeChoice> snoozeChoices(DateTime now, {int businessDayStartHour = 9}) {
  final today = dubai(now);
  final hour = businessDayStartHour >= 0 && businessDayStartHour <= 23 ? businessDayStartHour : 9;
  DateTime dayPlus(int n) {
    final d = DateTime.utc(today.year, today.month, today.day + n);
    return dubaiInstant(d.year, d.month, d.day, hour);
  }

  final weekday = today.weekday % 7; // 0 = Sunday
  final daysToMonday = ((8 - weekday) % 7) == 0 ? 7 : (8 - weekday) % 7;
  return [
    SnoozeChoice('1 hour', now.add(const Duration(hours: 1))),
    SnoozeChoice('3 hours', now.add(const Duration(hours: 3))),
    SnoozeChoice('Tomorrow', dayPlus(1)),
    SnoozeChoice('Monday', dayPlus(daysToMonday)),
  ];
}
