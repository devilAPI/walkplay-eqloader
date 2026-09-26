import 'package:flutter/material.dart';

import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  runApp(const EqLoaderApp());
}

class EqLoaderApp extends StatelessWidget {
  const EqLoaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Walkplay PEQ Loader',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomePage(),
    );
  }
}
