import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { PiPWindow } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'FloatingPlugin';

/**
 * Dimensions class for aspect ratio conversion results
 */
class Dimensions {
  width: number;
  height: number;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

/** FloatingPlugin **/
export default class FloatingPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private isInPipMode: boolean = false;
  private pipController?: PiPWindow.PiPController = undefined;
  private contentWidth: number = 1920;
  private contentHeight: number = 1080;

  constructor() {
  }

  getUniqueClassName(): string {
    return "FloatingPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "floating");
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.destroy();
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
   * Check if PiP is enabled on the device
   */
  private isPipEnabled(): boolean {
    return PiPWindow.isPiPEnabled();
  }

  /**
   * Handle pipAvailable method call
   * Returns true if PiP is enabled on the device
   * Handles edge case: PiP not supported on device (Requirements 1.2)
   */
  private handlePipAvailable(result: MethodResult): void {
    try {
      const isAvailable = this.isPipEnabled();
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
   * - PiP not supported on device
   * - Repeated enablePip calls (handled gracefully by init returning true if already initialized)
   */
  private async handleEnablePip(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      // Check if PiP is supported on device (edge case: PiP not supported)
      if (!this.isPipEnabled()) {
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

      // Configure content size from aspect ratio before initialization
      this.setContentSizeFromAspectRatio(numerator, denominator);

      // Initialize PiP controller with state change callback
      // Handle repeated enablePip calls gracefully - init will return true if already initialized
      const initSuccess = await this.init();

      if (!initSuccess) {
        console.error(TAG, 'Failed to initialize PiP controller');
        result.success(false);
        return;
      }

      if (autoEnable) {
        // Auto-enable mode: set auto-start and return result
        const autoStartSuccess = this.setAutoStart(true);
        result.success(autoStartSuccess);
      } else {
        // Manual mode: start PiP immediately
        const startSuccess = await this.startPip();
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
   * Initialize the PiP controller with state change callback
   * @returns Promise resolving to true if initialization successful, false otherwise
   */
  private async init(): Promise<boolean> {
    // Check if PiP is enabled before proceeding
    if (!PiPWindow.isPiPEnabled()) {
      console.error(TAG, 'Picture-in-Picture is disabled for current OS');
      return false;
    }

    // If controller already exists, skip creation
    if (this.pipController !== undefined) {
      console.info(TAG, 'PiPController already initialized');
      return true;
    }

    // Create PiP configuration
    // Note: componentController is required by PiPConfiguration but for Flutter plugins
    // we create a minimal XComponentController since Flutter manages its own rendering
    const xComponentController = new XComponentController();
    const config: PiPWindow.PiPConfiguration = {
      context: getContext(),
      componentController: xComponentController,
      templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
      contentWidth: this.contentWidth,
      contentHeight: this.contentHeight,
    };

    // Create PiP controller with comprehensive error handling
    try {
      console.info(TAG, 'Creating PiPController');
      const controller = await PiPWindow.create(config);
      this.pipController = controller;
      console.info(TAG, 'PiPController created successfully');

      // Register state change listener
      this.pipController.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        this.handleStateChange(state, reason);
      });
      return true;
    } catch (err) {
      const error = err as BusinessError;
      console.error(TAG, `Failed to create PiP controller. Code: ${error.code}, Message: ${error.message}`);
      // Reset state on failure
      this.pipController = undefined;
      this.isInPipMode = false;
      return false;
    }
  }

  /**
   * Handle PiP state changes
   * @param state - The new PiP state
   * @param reason - The reason for the state change
   */
  private handleStateChange(state: PiPWindow.PiPState, reason: string): void {
    let stateName: string = '';
    let newIsInPipMode: boolean = this.isInPipMode;

    switch (state) {
      case PiPWindow.PiPState.ABOUT_TO_START:
        stateName = 'ABOUT_TO_START';
        break;
      case PiPWindow.PiPState.STARTED:
        stateName = 'STARTED';
        newIsInPipMode = true;
        break;
      case PiPWindow.PiPState.ABOUT_TO_STOP:
        stateName = 'ABOUT_TO_STOP';
        break;
      case PiPWindow.PiPState.STOPPED:
        stateName = 'STOPPED';
        newIsInPipMode = false;
        break;
      case PiPWindow.PiPState.ABOUT_TO_RESTORE:
        stateName = 'ABOUT_TO_RESTORE';
        break;
      case PiPWindow.PiPState.ERROR:
        stateName = 'ERROR';
        newIsInPipMode = false;
        break;
      default:
        stateName = 'UNKNOWN';
        break;
    }

    console.info(TAG, `onStateChange: ${stateName}, reason: ${reason}`);

    // Update internal state and notify Flutter if state changed
    if (this.isInPipMode !== newIsInPipMode) {
      this.isInPipMode = newIsInPipMode;
      this.onPipStateChanged(this.isInPipMode);
    }
  }

  /**
   * Start PiP mode
   * @returns Promise resolving to true if successful, false otherwise
   */
  private async startPip(): Promise<boolean> {
    if (!this.pipController) {
      console.error(TAG, 'Cannot start PiP: controller not initialized');
      return false;
    }

    // Check if PiP is still enabled at system level
    if (!PiPWindow.isPiPEnabled()) {
      console.error(TAG, 'Cannot start PiP: PiP is disabled at system level');
      return false;
    }

    try {
      await this.pipController.startPiP();
      console.info(TAG, 'Successfully started PiP');
      return true;
    } catch (err) {
      const error = err as BusinessError;
      console.error(TAG, `Failed to start PiP. Code: ${error.code}, Message: ${error.message}`);
      // Do not update internal PiP state on failure (as per design doc)
      return false;
    }
  }

  /**
   * Set auto-start enabled for PiP
   * @param enabled - Whether to enable auto-start
   * @returns true if auto-start was set successfully, false otherwise
   */
  private setAutoStart(enabled: boolean): boolean {
    if (!this.pipController) {
      console.error(TAG, 'Cannot set auto-start: controller not initialized');
      return false;
    }

    try {
      this.pipController.setAutoStartEnabled(enabled);
      console.info(TAG, `Auto-start set to: ${enabled}`);
      return true;
    } catch (err) {
      const error = err as BusinessError;
      console.error(TAG, `Failed to set auto-start. Code: ${error.code}, Message: ${error.message}`);
      return false;
    }
  }

  /**
   * Set content size for PiP window
   * @param width - Content width
   * @param height - Content height
   */
  private setContentSize(width: number, height: number): void {
    this.contentWidth = width;
    this.contentHeight = height;
    if (this.pipController) {
      try {
        this.pipController.updateContentSize(width, height);
        console.info(TAG, `Content size updated to: ${width}x${height}`);
      } catch (err) {
        const error = err as BusinessError;
        console.error(TAG, `Failed to update content size. Code: ${error.code}, Message: ${error.message}`);
      }
    }
  }

  /**
   * Convert aspect ratio to content dimensions
   * Uses a base height of 1080 and calculates width to maintain aspect ratio
   * @param numerator - Aspect ratio numerator (e.g., 16 for 16:9)
   * @param denominator - Aspect ratio denominator (e.g., 9 for 16:9)
   * @returns Dimensions object containing calculated width and height
   */
  private static aspectRatioToDimensions(numerator: number, denominator: number): Dimensions {
    const baseHeight = 1080;
    const width = Math.round((baseHeight * numerator) / denominator);
    return new Dimensions(width, baseHeight);
  }

  /**
   * Set content size from aspect ratio
   * @param numerator - Aspect ratio numerator
   * @param denominator - Aspect ratio denominator
   */
  private setContentSizeFromAspectRatio(numerator: number, denominator: number): void {
    const dimensions = FloatingPlugin.aspectRatioToDimensions(numerator, denominator);
    this.setContentSize(dimensions.width, dimensions.height);
  }

  /**
   * Clean up PiP resources
   */
  private destroy(): void {
    if (this.pipController) {
      try {
        this.pipController.off('stateChange');
        console.info(TAG, 'PiPController state change listener unregistered');
      } catch (err) {
        const error = err as BusinessError;
        console.error(TAG, `Failed to unregister state change listener. Code: ${error.code}, Message: ${error.message}`);
      }
      this.pipController = undefined;
      console.info(TAG, 'PiPController destroyed');
    }
    this.isInPipMode = false;
  }

  /**
   * Callback invoked when PiP state changes
   * Updates internal state and notifies Flutter
   */
  private onPipStateChanged(isInPip: boolean): void {
    console.info(TAG, `onPipStateChanged: ${isInPip}`);

    // Notify Flutter of the state change
    if (this.channel !== null) {
      this.channel.invokeMethod('onPipChanged', isInPip);
    }
  }
}