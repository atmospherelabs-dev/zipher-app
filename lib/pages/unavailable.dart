import 'package:flutter/material.dart';

/// Keeps old links understandable without exposing unfinished wallet actions.
class UnavailablePage extends StatelessWidget {
  final String feature;
  const UnavailablePage(this.feature, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(feature)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '$feature is unavailable in this version. No wallet action was performed.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}
