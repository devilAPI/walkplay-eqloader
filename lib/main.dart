import 'package:flutter/material.dart';

import 'app/app.dart';
import 'state/store.dart';

export 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(EqLoaderApp(store: await PrefsStore.open()));
}
