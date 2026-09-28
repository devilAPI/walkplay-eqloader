import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/eq_model.dart';
import '../state/settings.dart';
import 'dialogs.dart';

/// What commands need from the page they run on: a context for dialogs, the
/// EQ, and a way to run fallible work.
abstract interface class TaskHost {
  BuildContext get context;
  EqModel get model;
  Settings get settings;

  /// Run [work]; returns its result, or null after a failure (which is
  /// logged, and shown as [error] (title, message) if given, else as a
  /// snackbar). [busy] (title, message) shows a spinner meanwhile.
  Future<T?> runTask<T>(
    Future<T> Function() work, {
    (String, String)? busy,
    (String, String)? error,
  });
}

/// [TaskHost.runTask] for a page's [State].
mixin TaskRunner<W extends StatefulWidget> on State<W> implements TaskHost {
  @override
  Future<T?> runTask<T>(
    Future<T> Function() work, {
    (String, String)? busy,
    (String, String)? error,
  }) async {
    final close = busy != null ? showBusy(context, busy.$1, busy.$2) : null;
    try {
      return await work();
    } catch (e) {
      final text = errorText(e);
      model.log('ERROR: $text');
      close?.call();
      if (!mounted) return null;
      if (error != null) {
        await showInfo(context, error.$1, '${error.$2}:\n$text');
      } else {
        // Styled by the theme's snackBarTheme.
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(text)));
      }
      return null;
    } finally {
      close?.call();
    }
  }
}

String errorText(Object e) => switch (e) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  PlatformException(:final code, :final message) => message ?? code,
  FileSystemException(:final message, :final path, :final osError) =>
    '$message${path != null ? ' ($path)' : ''}'
        '${osError != null ? ': ${osError.message}' : ''}',
  SocketException(:final message) => 'Network error: $message',
  _ => e.toString(),
};
