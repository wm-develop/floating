# Requirements Document

## Introduction

This document specifies the requirements for adapting the Flutter floating (Picture-in-Picture) plugin to support HarmonyOS (OpenHarmony). The plugin currently supports Android and needs to be extended to provide equivalent PiP functionality on HarmonyOS devices using the HarmonyOS PiPWindow API.

## Glossary

- **PiP (Picture-in-Picture)**: A display mode that allows an application to show a small floating window over other applications
- **Floating Plugin**: The Flutter plugin that provides PiP functionality across platforms
- **HarmonyOS**: Huawei's operating system, also known as OpenHarmony
- **PiPWindow**: The HarmonyOS API module for Picture-in-Picture functionality
- **PiPController**: The HarmonyOS controller instance that manages PiP lifecycle and operations
- **MethodChannel**: Flutter's mechanism for communication between Dart and native platform code
- **FlutterPlugin**: The HarmonyOS interface for implementing Flutter plugins
- **Aspect Ratio**: The proportional relationship between width and height of the PiP window

## Requirements

### Requirement 1

**User Story:** As a Flutter developer, I want to check if PiP is available on the HarmonyOS device, so that I can provide appropriate UI feedback to users.

#### Acceptance Criteria

1. WHEN a Flutter app calls the `pipAvailable` method on HarmonyOS THEN the FloatingPlugin SHALL return `true` if PiPWindow.isPiPEnabled() returns true, otherwise return `false`
2. WHEN PiP is disabled at the system level THEN the FloatingPlugin SHALL return `false` for availability checks

### Requirement 2

**User Story:** As a Flutter developer, I want to enable PiP mode manually on HarmonyOS, so that users can continue viewing content in a floating window.

#### Acceptance Criteria

1. WHEN a Flutter app calls `enablePip` with `autoEnable` set to `false` THEN the FloatingPlugin SHALL create a PiPController and call `startPiP()` to enter PiP mode immediately
2. WHEN `enablePip` is called with aspect ratio parameters (numerator and denominator) THEN the FloatingPlugin SHALL configure the PiP window with the specified content dimensions
3. WHEN `startPiP()` succeeds THEN the FloatingPlugin SHALL return `true` to the Flutter layer
4. WHEN `startPiP()` fails THEN the FloatingPlugin SHALL return `false` to the Flutter layer

### Requirement 3

**User Story:** As a Flutter developer, I want to enable automatic PiP mode on HarmonyOS, so that the app enters PiP when the user navigates away.

#### Acceptance Criteria

1. WHEN a Flutter app calls `enablePip` with `autoEnable` set to `true` THEN the FloatingPlugin SHALL call `setAutoStartEnabled(true)` on the PiPController
2. WHEN auto-enable is configured THEN the FloatingPlugin SHALL return `true` without immediately entering PiP mode
3. WHEN the user navigates away from the app with auto-enable configured THEN the HarmonyOS system SHALL automatically enter PiP mode

### Requirement 4

**User Story:** As a Flutter developer, I want to check if the app is currently in PiP mode on HarmonyOS, so that I can adjust the UI accordingly.

#### Acceptance Criteria

1. WHEN a Flutter app calls `inPipAlready` THEN the FloatingPlugin SHALL track and return the current PiP state based on PiPController state change callbacks
2. WHEN the PiP state changes to STARTED THEN the FloatingPlugin SHALL update internal state to indicate PiP is active
3. WHEN the PiP state changes to STOPPED THEN the FloatingPlugin SHALL update internal state to indicate PiP is inactive

### Requirement 5

**User Story:** As a Flutter developer, I want the plugin to properly initialize and clean up HarmonyOS PiP resources, so that the app behaves correctly throughout its lifecycle.

#### Acceptance Criteria

1. WHEN the FloatingPlugin is attached to the Flutter engine THEN the FloatingPlugin SHALL register the MethodChannel with the name "floating"
2. WHEN the FloatingPlugin is detached from the Flutter engine THEN the FloatingPlugin SHALL unregister state change and control event listeners from the PiPController
3. WHEN the PiPController encounters an error state THEN the FloatingPlugin SHALL log the error and handle it gracefully without crashing

### Requirement 6

**User Story:** As a Flutter developer, I want PiP state changes to be communicated back to Flutter, so that I can update the app UI in response to PiP events.

#### Acceptance Criteria

1. WHEN the PiP state changes on HarmonyOS THEN the FloatingPlugin SHALL invoke the `onPipChanged` method on the Flutter MethodChannel with the current state
2. WHEN PiP enters STARTED state THEN the FloatingPlugin SHALL send `true` to the Flutter layer via `onPipChanged`
3. WHEN PiP enters STOPPED state THEN the FloatingPlugin SHALL send `false` to the Flutter layer via `onPipChanged`
