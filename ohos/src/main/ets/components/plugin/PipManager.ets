import { PiPWindow } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

const TAG = 'PipManager';

/**
 * Dimensions class for aspect ratio conversion results
 */
export class Dimensions {
  width: number;
  height: number;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

/**
 * PipManager - Singleton class for managing Picture-in-Picture functionality
 * on HarmonyOS for the Flutter floating plugin.
 */
export class PipManager {
  private static instance: PipManager = new PipManager();
  private pipController?: PiPWindow.PiPController = undefined;
  private _isInPipMode: boolean = false;
  private onStateChangeCallback?: (isInPip: boolean) => void = undefined;
  private context: common.Context = getContext();
  private contentWidth: number = 1920;
  private contentHeight: number = 1080;

  private constructor() {
  }

  /**
   * Get the singleton instance of PipManager
   */
  public static getInstance(): PipManager {
    return PipManager.instance;
  }

  /**
   * Check if PiP is enabled on the device
   */
  public isPipEnabled(): boolean {
    return PiPWindow.isPiPEnabled();
  }

  /**
   * Get current PiP mode state
   */
  public get isInPipMode(): boolean {
    return this._isInPipMode;
  }

  /**
   * Initialize the PipManager with context and state change callback
   * @param ctx - The application context
   * @param onStateChange - Callback invoked when PiP state changes
   * @returns Promise resolving to true if initialization successful, false otherwise
   */
  public async init(onStateChange: (isInPip: boolean) => void): Promise<boolean> {
    // Store callback and context
    this.onStateChangeCallback = onStateChange;

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
      console.info(TAG, 'try create PiPController');
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
      this._isInPipMode = false;
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
    let newIsInPipMode: boolean = this._isInPipMode;

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

    // Update internal state and notify callback if state changed
    if (this._isInPipMode !== newIsInPipMode) {
      this._isInPipMode = newIsInPipMode;
      if (this.onStateChangeCallback) {
        this.onStateChangeCallback(this._isInPipMode);
      }
    }
  }

  /**
   * Start PiP mode
   * @returns Promise resolving to true if successful, false otherwise
   */
  public async startPip(): Promise<boolean> {
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
  public setAutoStart(enabled: boolean): boolean {
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
  public setContentSize(width: number, height: number): void {
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
  public static aspectRatioToDimensions(numerator: number, denominator: number): Dimensions {
    const baseHeight = 1080;
    const width = Math.round((baseHeight * numerator) / denominator);
    return new Dimensions(width, baseHeight);
  }

  /**
   * Set content size from aspect ratio
   * @param numerator - Aspect ratio numerator
   * @param denominator - Aspect ratio denominator
   */
  public setContentSizeFromAspectRatio(numerator: number, denominator: number): void {
    const dimensions = PipManager.aspectRatioToDimensions(numerator, denominator);
    this.setContentSize(dimensions.width, dimensions.height);
  }

  /**
   * Clean up PiP resources
   */
  public destroy(): void {
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
    this._isInPipMode = false;
    this.onStateChangeCallback = undefined;
    // this.context = undefined;
  }

  /**
   * Check if PipManager is initialized with a valid controller
   * @returns true if controller is initialized, false otherwise
   */
  public isInitialized(): boolean {
    return this.pipController !== undefined;
  }
}
