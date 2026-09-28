/// Short human-readable formatting shared by panels and dialogs.
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "14:03" today, else "28 Sep 14:03" (no intl dependency for this).
String formatWhen(DateTime t, {DateTime? now}) {
  now ??= DateTime.now();
  t = t.toLocal();
  final time =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return time;
  }
  final date = '${t.day} ${_months[t.month - 1]}';
  return t.year == now.year ? '$date $time' : '$date ${t.year}';
}
