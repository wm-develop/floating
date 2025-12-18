import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { PipManager } from './PipManager';

const TAG = 'FloatingPlugin';

/** FloatingPlugin **/
export default class FloatingPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;
  private isInPipMode: boolean = false;

  constructor() {
  }

  getUniqueClassName(): string {
    return "FloatingPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "floating");
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    PipManager.getInstance().destroy();
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case "pipAvailable":
        this.handlePipAvailable(result);
        break;
      case "enablePip":
        this.handleEnablePip(call, result);
        break;
      case "inPipAlready":
        this.handleInPipAlready(result);
        break;
      case "getPlatformVersion":
        result.success("OpenHarmony ^ ^ ");
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /**
   * Handle pipAvailable method call
   * Returns true if PiP is enabled on the device
   * Handles edge case: PiP not supported on device (Requirements 1.2)
   */
  private handlePipAvailable(result: MethodResult): void {
    try {
      const isAvailable = PipManager.getInstance().isPipEnabled();
      console.info(TAG, `pipAvailable: ${isAvailable}`);
      result.success(isAvailable);
    } catch (err) {
      console.error(TAG, `Error checking PiP availability: ${err}`);
      result.success(false);
    }
  }

  /**
   * Handle enablePip method call
   * Enables PiP mode with the specified configuration
   * 
   * Edge cases handled (Requirements 1.2, 2.4):
   * - enablePip called before context is available
   * - PiP not supported on device
   * - Repeated enablePip calls (handled gracefully by init returning true if already initialized)
   */
  private async handleEnablePip(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      // Check if context is available (edge case: enablePip called before context is available)
      if (this.context === null) {
        console.error(TAG, 'Cannot enable PiP: context not available. Plugin may not be attached to engine.');
        result.success(false);
        return;
      }

      // Check if PiP is supported on device (edge case: PiP not supported)
      if (!PipManager.getInstance().isPipEnabled()) {
        console.error(TAG, 'Cannot enable PiP: PiP not supported or disabled on this device');
        result.success(false);
        return;
      }

      // Extract arguments with defaults
      const args = call.args as Record<string, Object>;
      const numerator: number = (args['numerator'] as number) ?? 16;
      const denominator: number = (args['denominator'] as number) ?? 9;
      const autoEnable: boolean = (args['autoEnable'] as boolean) ?? false;

      console.info(TAG, `enablePip: numerator=${numerator}, denominator=${denominator}, autoEnable=${autoEnable}`);

      const pipManager = PipManager.getInstance();

      // Configure content size from aspect ratio before initialization
      pipManager.setContentSizeFromAspectRatio(numerator, denominator);

      // Initialize PipManager with context and state change callback
      // Handle repeated enablePip calls gracefully - init will return true if already initialized
      const initSuccess = await pipManager.init((isInPip: boolean) => {
        this.onPipStateChanged(isInPip);
      });

      if (!initSuccess) {
        console.error(TAG, 'Failed to initialize PipManager');
        result.success(false);
        return;
      }

      if (autoEnable) {
        // Auto-enable mode: set auto-start and return result
        const autoStartSuccess = pipManager.setAutoStart(true);
        result.success(autoStartSuccess);
      } else {
        // Manual mode: start PiP immediately
        const startSuccess = await pipManager.startPip();
        result.success(startSuccess);
      }
    } catch (err) {
      console.error(TAG, `Unexpected error in enablePip: ${err}`);
      result.success(false);
    }
  }

  /**
   * Handle inPipAlready method call
   * Returns the current PiP state
   */
  private handleInPipAlready(result: MethodResult): void {
    try {
      console.info(TAG, `inPipAlready: ${this.isInPipMode}`);
      result.success(this.isInPipMode);
    } catch (err) {
      console.error(TAG, `Error checking PiP state: ${err}`);
      result.success(false);
    }
  }

  /**
   * Callback invoked when PiP state changes
   * Updates internal state and notifies Flutter
   */
  private onPipStateChanged(isInPip: boolean): void {
    this.isInPipMode = isInPip;
    console.info(TAG, `onPipStateChanged: ${isInPip}`);

    // Notify Flutter of the state change
    if (this.channel !== null) {
      this.channel.invokeMethod('onPipChanged', isInPip);
    }
  }
}