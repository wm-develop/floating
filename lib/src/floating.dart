part of '../floating.dart';

enum PiPStatus {
  /// App is currently shrank to PiP.
  enabled,

  /// App is currently not floating over others.
  disabled,

  /// App will shrink once the user will try to minimize the app.
  automatic,

  /// PiP mode is not available on this device.
  unavailable,
}

/// Have to be shared between all [Floating] instances to understand
/// if the [PiPStatus.automatic] was configured.
@visibleForTesting
EnableArguments? lastEnableArguments;

/// Manages app picture in picture mode.
///
/// PiP mode is available on Android and HarmonyOS.
/// Support for other platforms is not planned.
class Floating {
  final _channel = const MethodChannel('floating');

  static final _singleton = Floating._internal();

  factory Floating() => _singleton;

  Floating._internal() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipChanged') {
        isPipMode = call.arguments;
      } else if (call.method == 'onPipAction') {
        final args = call.arguments as Map?;
        final event = args?['event'];
        if (event is String) {
          onPipAction?.call(event, args?['status'] as int?);
        }
      }
    });
  }

  bool? _isPipAvailable;

  late bool isPipMode = false;

  /// Called when the user taps a button on the HarmonyOS PiP window's
  /// control panel. Never called on Android.
  ///
  /// [event] is one of `playbackStateChanged`, `nextVideo`, `previousVideo`
  /// (VIDEO_PLAY template). For `playbackStateChanged`, [status] is the
  /// requested state: `1` = play, `0` = pause.
  void Function(String event, int? status)? onPipAction;

  /// Confirms or denies PiP availability.
  ///
  /// PiP may be unavailable because of system settings managed
  /// by admin or device manufacturer. Also, the device may
  /// have Android version that was released without this feature.
  Future<bool> get isPipAvailable async {
    _isPipAvailable ??= await _channel.invokeMethod('pipAvailable');
    return _isPipAvailable ?? false;
  }

  /// Checks current app PiP status.
  ///
  /// When `false` the app can call [enable] method.
  /// When the app is already in PiP mode user will have an option
  /// to bring the app to it's original size via system UI.
  ///
  /// PiP may be unavailable because of system settings managed
  /// by admin or device manufacturer. Also, the device may
  /// have Android version that was released without this feature.
  Future<PiPStatus> get pipStatus async {
    if (!await isPipAvailable) {
      return PiPStatus.unavailable;
    }

    final bool? inPipAlready = await _channel.invokeMethod('inPipAlready');
    if (inPipAlready ?? false) {
      return PiPStatus.enabled;
    }

    final isAutoEnabled = lastEnableArguments is AutoEnable;

    return isAutoEnabled ? PiPStatus.automatic : PiPStatus.disabled;
  }

  // Notifies about changes of the PiP mode.
  //
  // PiP state is probed, by default in the 100 milliseconds interval.
  // The probing interval can be configured in the constructor.
  //
  // This stream will call listeners only when the value changed.
  // Stream<PiPStatus> get pipStatusStream {
  //   _stream ??= _controller.stream.asBroadcastStream();
  //   return _stream!.distinct();
  // }

  // void onPipChanged(bool isInPipMode) {
  //   if (!_controller.isClosed) {
  //     _controller.add(isInPipMode ? PiPStatus.enabled : PiPStatus.disabled);
  //   }
  // }

  /// Turns on PiP mode.
  ///
  /// When enabled, PiP mode can be ended by the user via system UI.
  ///
  /// PiP may be unavailable because of system settings managed
  /// by admin or device manufacturer. Also, the device may
  /// have Android version that was released without this feature.
  ///
  /// See [EnableManual] and [AutoEnable] to understand available [arguments].
  ///
  /// Note: this will not make any effect on Android SDK older than 26.
  Future<PiPStatus> enable(EnableArguments arguments) async {
    lastEnableArguments = arguments;
    final (aspectRatio, sourceRectHint, autoEnable) = switch (arguments) {
      EnableManual(:final aspectRatio, :final sourceRectHint) => (
          aspectRatio,
          sourceRectHint,
          false,
        ),
      AutoEnable(:final aspectRatio, :final sourceRectHint) => (
          aspectRatio,
          sourceRectHint,
          true,
        ),
    };

    if (!aspectRatio.fitsInAndroidRequirements) {
      throw RationalNotMatchingAndroidRequirementsException(aspectRatio);
    }

    final bool? enabledSuccessfully = await _channel.invokeMethod(
      'enablePip',
      {
        ...aspectRatio.toMap(),
        if (sourceRectHint != null)
          'sourceRectHintLTRB': [
            sourceRectHint.left,
            sourceRectHint.top,
            sourceRectHint.right,
            sourceRectHint.bottom,
          ],
        'autoEnable': autoEnable,
      },
    );

    // AutoEnable only schedules the system to enter PiP later; it must not
    // change whether the app is in PiP right now. Forcing `false` here would
    // clobber the state set by `onPipChanged` when the app re-arms auto-PiP
    // while already inside the PiP window (e.g. playback resuming there).
    isPipMode = autoEnable ? isPipMode : enabledSuccessfully ?? false;

    return isPipMode ? PiPStatus.enabled : PiPStatus.unavailable;
  }

  // 暂时在鸿蒙实现
  Future<PiPStatus> setAutoPip(bool auto) async {
    final success = await _channel.invokeMethod('setAutoPip', {
      'auto': auto,
    });
    return success == true
        ? auto
            ? PiPStatus.automatic
            : PiPStatus.disabled
        : PiPStatus.unavailable;
  }

  /// Syncs the play/pause icon on the HarmonyOS PiP window's control panel
  /// with the app's playback state. No-op on Android.
  ///
  /// Call whenever playback starts or pauses so the PiP button shows the
  /// correct icon; the plugin caches the value and re-applies it when a PiP
  /// session starts.
  Future<bool> updatePipControlStatus({required bool playing}) async {
    try {
      final success = await _channel.invokeMethod(
        'updatePipControlStatus',
        {'playing': playing},
      );
      return success == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  // Disposes internal components used to update the [isInPipMode$] stream.
  // void dispose() {
  //   _controller.close();
  // }
}

/// Represents rational in [numerator]/[denominator] notation.
class Rational {
  final int numerator;
  final int denominator;
  double get aspectRatio => numerator / denominator;

  const Rational(this.numerator, this.denominator);

  const Rational.square()
      : numerator = 1,
        denominator = 1;

  const Rational.landscape()
      : numerator = 16,
        denominator = 9;

  const Rational.vertical()
      : numerator = 9,
        denominator = 16;

  @override
  String toString() =>
      'Rational(numerator: $numerator, denominator: $denominator)';

  Map<String, dynamic> toMap() => {
        'numerator': numerator,
        'denominator': denominator,
      };
}

/// Extension for [Rational] to confirm whether Android aspect ration
/// requirements are met or not.
extension on Rational {
  /// Checks whether given [Rational] instance fits into Android requirements
  /// or not.
  ///
  /// Android docs specified boundaries as inclusive.
  bool get fitsInAndroidRequirements {
    final aspectRatio = numerator / denominator;
    final min = 1 / 2.39;
    final max = 2.39;
    return (min <= aspectRatio) && (aspectRatio <= max);
  }
}

/// Provides details about Android requirements and compares current
/// [rational] value to those.
class RationalNotMatchingAndroidRequirementsException implements Exception {
  final Rational rational;

  RationalNotMatchingAndroidRequirementsException(this.rational);

  @override
  String toString() => 'RationalNotMatchingAndroidRequirementsException('
      '${rational.numerator}/${rational.denominator} does not fit into '
      'Android-supported aspect ratios. Boundaries: '
      'min: 1/2.39, max: 2.39/1. '
      ')';
}
