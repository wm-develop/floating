import 'dart:math';

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:floating/floating.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final floating = Floating();

  Future<void> enablePip(
    BuildContext context, {
    bool autoEnable = false,
  }) async {
    final rational = Rational.landscape();
    final screenSize =
        MediaQuery.of(context).size * MediaQuery.of(context).devicePixelRatio;
    final height = screenSize.width ~/ rational.aspectRatio;

    final arguments = autoEnable
        ? AutoEnable(
            aspectRatio: rational,
            sourceRectHint: Rectangle<int>(
              0,
              (screenSize.height ~/ 2) - (height ~/ 2),
              screenSize.width.toInt(),
              height,
            ),
          )
        : EnableManual(
            aspectRatio: rational,
            sourceRectHint: Rectangle<int>(
              0,
              (screenSize.height ~/ 2) - (height ~/ 2),
              screenSize.width.toInt(),
              height,
            ),
          );

    final status = await floating.enable(arguments);
    debugPrint('PiP enabled? $status');
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: ThemeData.dark(),
        home: PiPSwitcher(
          childWhenDisabled: Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset('assets/image.jpg', width: 300, height: 200, fit: BoxFit.cover),
                  const SizedBox(height: 20),
                  const Text(
                    'PiP Demo',
                    style: TextStyle(fontSize: 18),
                  ),
                ],
              ),
            ),
            floatingActionButtonLocation:
                FloatingActionButtonLocation.centerFloat,
            floatingActionButton: FutureBuilder<bool>(
              future: floating.isPipAvailable,
              initialData: false,
              builder: (context, snapshot) => snapshot.data ?? false
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingActionButton.extended(
                          onPressed: () => enablePip(context),
                          label: const Text('Enable PiP'),
                          icon: const Icon(Icons.picture_in_picture),
                        ),
                        const SizedBox(height: 12),
                        FloatingActionButton.extended(
                          onPressed: () => enablePip(context, autoEnable: true),
                          label: const Text('Enable PiP on app minimize'),
                          icon: const Icon(Icons.auto_awesome),
                        ),
                        const SizedBox(height: 12),
                        FloatingActionButton.extended(
                          onPressed: () => floating.setAutoPip(false),
                          label: const Text('Disable PiP on app minimize'),
                          icon: const Icon(Icons.disabled_by_default),
                        ),
                      ],
                    )
                  : const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('PiP unavailable'),
                      ),
                    ),
            ),
          ),
          childWhenEnabled: Image.asset('assets/image.jpg'),
        ),
      );
}

/// Simple PiPSwitcher widget that switches between different UI based on PiP status
class PiPSwitcher extends StatefulWidget {
  final Widget childWhenDisabled;
  final Widget childWhenEnabled;

  const PiPSwitcher({
    Key? key,
    required this.childWhenDisabled,
    required this.childWhenEnabled,
  }) : super(key: key);

  @override
  _PiPSwitcherState createState() => _PiPSwitcherState();
}

class _PiPSwitcherState extends State<PiPSwitcher> {
  final floating = Floating();
  bool isPipMode = false;

  @override
  void initState() {
    super.initState();
    _checkPipStatus();
  }

  void _checkPipStatus() async {
    // Check initial PiP status
    final status = await floating.pipStatus;
    setState(() {
      isPipMode = status == PiPStatus.enabled;
    });
  }

  @override
  Widget build(BuildContext context) {
    return isPipMode ? widget.childWhenEnabled : widget.childWhenDisabled;
  }
}
