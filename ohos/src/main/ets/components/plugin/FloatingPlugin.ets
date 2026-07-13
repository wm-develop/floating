import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  Any,
  FlutterEngine,
  FlutterManager,
  FlutterNapi,
  FlutterView,
} from '@ohos/flutter_ohos';
import { PiPWindow, NodeController, BuilderNode, FrameNode, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';

const TAG = 'FloatingPlugin';

/**
 * Parameters passed into the PiP surface builder.
 */
class PipSurfaceParams {
  xcId: string = '';
  onLoaded?: () => void;
  onSizeChanged?: (size: SizeOptions) => void;
}

/**
 * Classic XComponent hosting the Flutter engine output inside the PiP window.
 *
 * This must be a regular component built through a BuilderNode: only the
 * classic component instantiation path loads the `libraryname` native module
 * (libflutter) and registers the surface with the engine's XComponentAdapter.
 * A typeNode.XComponent created via typeNode.createNode never triggers the
 * napi module export, so its surface stays invisible to the engine.
 */
@Component
struct PipFlutterSurface {
  params: PipSurfaceParams = new PipSurfaceParams();

  build() {
    XComponent({ id: this.params.xcId, type: XComponentType.SURFACE, libraryname: 'flutter' })
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .onLoad(() => {
        console.info(TAG, `PiP XComponent loaded: ${this.params.xcId}`);
        if (this.params.onLoaded) {
          this.params.onLoaded();
        }
      })
      .onDestroy(() => {
        console.info(TAG, `PiP XComponent destroyed: ${this.params.xcId}`);
      })
      .onSizeChange((oldValue: SizeOptions, newValue: SizeOptions) => {
        if (this.params.onSizeChanged) {
          this.params.onSizeChanged(newValue);
        }
      })
  }
}

@Builder
function buildPipFlutterSurface(params: PipSurfaceParams) {
  PipFlutterSurface({ params: params })
}

/**
 * NodeController handed to PiPConfiguration.customUIController; the system
 * calls makeNode with the PiP window's UIContext and lays the returned node
 * over the (empty) PiP content area.
 */
class PipSurfaceNodeController extends NodeController {
  private rootNode: BuilderNode<[PipSurfaceParams]> | null = null;
  private uiContext: UIContext | null = null;
  private params: PipSurfaceParams;

  constructor(params: PipSurfaceParams) {
    super();
    this.params = params;
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    this.uiContext = uiContext;
    if (this.rootNode === null) {
      this.rootNode = new BuilderNode(uiContext);
      this.rootNode.build(wrapBuilder<[PipSurfaceParams]>(buildPipFlutterSurface), this.params);
    }
    return this.rootNode.getFrameNode();
  }

  /**
   * Measured size of the hosted node in vp, or null if not laid out yet.
   * Fallback source for the viewport push when no onSizeChange event is
   * available (e.g. it fired before the session flags were set).
   */
  getContentSizeVp(): SizeOptions | null {
    if (this.rootNode === null || this.uiContext === null) {
      return null;
    }
    const frameNode = this.rootNode.getFrameNode();
    if (frameNode === null) {
      return null;
    }
    const measured = frameNode.getMeasuredSize();
    if (measured.width <= 0 || measured.height <= 0) {
      return null;
    }
    const result: SizeOptions = {
      width: this.uiContext.px2vp(measured.width),
      height: this.uiContext.px2vp(measured.height),
    };
    return result;
  }

  destroyNode(): void {
    if (this.rootNode !== null) {
      this.rootNode.dispose();
      this.rootNode = null;
    }
  }
}

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

/**
 * FloatingPlugin
 *
 * How PiP content rendering works here:
 * The PiP window content is a programmatically created XComponent node
 * (typeNode.XComponent) with `libraryname: 'flutter'`, passed to
 * `PiPWindow.create(config, contentNode)`. When the PiP window starts, the
 * Flutter engine is attached to that XComponent's surface
 * (FlutterNapi.xComponentAttachFlutterEngine), so the engine presents the
 * whole Flutter UI into the PiP window. While PiP is active the viewport
 * metrics are pushed with the PiP window size (FlutterView.onAreaChange) so
 * Flutter lays out at the small size instead of being cropped. When PiP
 * stops, rendering and metrics are switched back to the main FlutterView
 * surface.
 *
 * The engine side of this (keeping the raster pipeline alive while the app
 * is backgrounded but a PiP window is visible) is handled by the embedding
 * itself (PiPVisibilityBridge / nativeSetPipVisible in @ohos/flutter_ohos).
 **/
export default class FloatingPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private flutterEngine: FlutterEngine | null = null;
  private flutterNapi: FlutterNapi | null = null;
  private isInPipMode: boolean = false;
  private pipController?: PiPWindow.PiPController = undefined;
  private pipNodeController?: PipSurfaceNodeController = undefined;
  private pipXComponentId: string = '';
  private pipNodeSeq: number = 0;
  // True between ABOUT_TO_START and STOPPED/ERROR; gates PiP-size viewport pushes.
  private pipSessionActive: boolean = false;
  // True while the session is already winding down (ABOUT_TO_STOP/RESTORE);
  // prevents a redundant stopPiP from the main-window-shown handler.
  private pipStopping: boolean = false;
  // Guards restoreMainSurfaceAndMetrics so the early call at
  // ABOUT_TO_STOP/ABOUT_TO_RESTORE and the one at STOPPED don't both run it.
  private mainSurfaceRestored: boolean = false;
  // The pip state travels over the method channel while viewport metrics go
  // through the engine's own pipeline; their arrival order in Dart is not
  // guaranteed. The app reads the pip state during the rebuild triggered by
  // the metrics change, so metrics must only be pushed after Dart has
  // acknowledged onPipChanged — otherwise the PiP window intermittently
  // freezes on the full-page layout (and the restore path on the video-only
  // layout). These fields gate the pushes until the acknowledgement.
  private pipStateDelivered: boolean = false;
  private pendingPipContentSize: SizeOptions | null = null;
  // Whether pip-size viewport metrics reached the engine this session.
  private pipMetricsPushed: boolean = false;
  private windowStageForEvents: window.WindowStage | null = null;
  private windowStageEventCallback: ((event: window.WindowStageEventType) => void) | null = null;
  // The auto-start state requested via setAutoPip / enablePip(autoEnable: true).
  // Re-applied when the controller is rebuilt after a PiP session ends, which
  // also restores the original setting after a manual (emulated) enable.
  private autoStartRequested: boolean = false;
  // Last playback state reported by Dart (updatePipControlStatus). Cached so
  // it can be re-applied when a PiP session starts or the controller is
  // rebuilt — updatePiPControlStatus only sticks on a live controller.
  private lastPlaybackPlaying: boolean | null = null;
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
    this.flutterEngine = binding.getFlutterEngine();
    this.flutterNapi = this.flutterEngine.getFlutterNapi();
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.destroy();
    this.flutterNapi = null;
    this.flutterEngine = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    console.info(TAG, `Method called: ${call.method}`);
    switch (call.method) {
      case "pipAvailable":
        this.handlePipAvailable(result);
        break;
      case "setAutoPip":
        this.handleSetAutoPip(call, result);
        break;
      case "enablePip":
        this.handleEnablePip(call, result);
        break;
      case "inPipAlready":
        this.handleInPipAlready(result);
        break;
      case "updatePipControlStatus":
        this.handleUpdatePipControlStatus(call, result);
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

  private async handleSetAutoPip(call: MethodCall, result: MethodResult): Promise<void> {
    const auto: boolean = call.argument('auto') ?? false;
    try {
      this.autoStartRequested = auto;
      if (auto) {
        const initSuccess = await this.init();
        if (!initSuccess || this.pipController === undefined) {
          result.success(false);
          return;
        }
        this.pipController.setAutoStartEnabled(true);
      } else {
        this.pipController?.setAutoStartEnabled(false);
      }
      result.success(true);
    } catch (err) {
      console.error(TAG, `setAutoPip failed: ${err}`);
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

      // Extract arguments - HarmonyOS Flutter plugin style
      const numerator: number = call.argument('numerator') ?? 16;
      const denominator: number = call.argument('denominator') ?? 9;
      const autoEnable: boolean = call.argument('autoEnable') ?? false;

      console.info(TAG,
        `enablePip params: numerator=${numerator}, denominator=${denominator}, autoEnable=${autoEnable}`);


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
      if (!this.pipController) {
        console.error(TAG, 'Cannot set auto-start: controller not initialized');
        result.success(false);
        return;
      }
      this.autoStartRequested = autoEnable;
      this.pipController.setAutoStartEnabled(true);
      // 不自动启用就是当场启用
      // 通过临时设置自动启用并手动返回桌面从而触发当场启用
      // 之前的自动启用设置会在本次画中画结束、控制器重建时恢复(见 scheduleControllerRebuild)
      if (!autoEnable) {
        const uiContext = getContext() as common.UIAbilityContext
        await uiContext.moveAbilityToBackground()
      }
      result.success(true);
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

    // The PiP window content is a classic XComponent (libraryname 'flutter')
    // hosted via customUIController: the Flutter engine attaches to its
    // surface when it loads, so the PiP window mirrors the Flutter UI
    // instead of staying blank.
    const nodeController = this.createPipNodeController();
    if (nodeController === null) {
      return false;
    }

    // componentController is required by PiPConfiguration but unused here:
    // the actual content is the customUIController overlay.
    const config: PiPWindow.PiPConfiguration = {
      context: getContext(),
      componentController: new XComponentController(),
      templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
      contentWidth: this.contentWidth,
      contentHeight: this.contentHeight,
      customUIController: nodeController,
    };

    // Create PiP controller with comprehensive error handling
    try {
      console.info(TAG, 'Creating PiPController');
      const controller = await PiPWindow.create(config);
      this.pipController = controller;
      this.pipNodeController = nodeController;
      console.info(TAG, 'PiPController created successfully');
      this.registerMainWindowShownListener();

      // Register state change listener
      this.pipController.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        this.handleStateChange(state, reason);
      });
      // Register active status listener (true = PiP window onscreen, false = offscreen)
      this.pipController.on('activeStatusChange', (active: boolean) => {
        this.handleActiveStatusChange(active);
      });
      // Register control panel button listener (play/pause, next/previous on
      // the VIDEO_PLAY template). Events are forwarded to Dart as onPipAction.
      this.pipController.on('controlPanelActionEvent',
        (event: PiPWindow.PiPActionEventType, status?: number) => {
          this.handleControlPanelAction(event, status);
        });
      return true;
    } catch (err) {
      const error = err as BusinessError;
      console.error(TAG, `Failed to create PiP controller. Code: ${error.code}, Message: ${error.message}`);
      // Reset state on failure
      this.disposePipNodeController();
      this.pipController = undefined;
      this.isInPipMode = false;
      return false;
    }
  }

  /**
   * Create the NodeController hosting the PiP Flutter surface.
   *
   * A fresh controller with a fresh XComponent id is created for every PiP
   * session: the engine drops its surface record when the surface is
   * destroyed, so the node cannot be reused across sessions.
   */
  private createPipNodeController(): PipSurfaceNodeController | null {
    try {
      this.pipNodeSeq += 1;
      this.pipXComponentId = `floating_pip_${this.pipNodeSeq}`;
      const params = new PipSurfaceParams();
      params.xcId = this.pipXComponentId;
      params.onLoaded = () => {
        // The surface exists from this point on; make the engine present to
        // it even if the state callbacks race with the ability going hidden.
        this.pipSessionActive = true;
        this.attachPipSurface();
        this.keepRenderingForPip();
      };
      params.onSizeChanged = (size: SizeOptions) => {
        this.onPipContentSizeChange(size);
      };
      return new PipSurfaceNodeController(params);
    } catch (err) {
      console.error(TAG, `Failed to create PiP node controller: ${err}`);
      this.pipXComponentId = '';
      return null;
    }
  }

  /**
   * HarmonyOS does not stop the PiP window when the user re-enters the app
   * (e.g. by tapping its icon); the engine would keep presenting into the PiP
   * surface and the main window would stay frozen on its last frame. Mirror
   * Android's behavior instead: stop the PiP session as soon as the main
   * window becomes visible again.
   */
  private registerMainWindowShownListener(): void {
    if (this.windowStageForEvents !== null) {
      return;
    }
    try {
      const manager = FlutterManager.getInstance();
      const uiAbility = manager.getUIAbility(getContext());
      const windowStage = manager.getWindowStage(uiAbility);
      const callback = (event: window.WindowStageEventType) => {
        if (event === window.WindowStageEventType.SHOWN) {
          this.onMainWindowShown();
        }
      };
      windowStage.on('windowStageEvent', callback);
      this.windowStageForEvents = windowStage;
      this.windowStageEventCallback = callback;
      console.info(TAG, 'Main window shown listener registered');
    } catch (err) {
      console.error(TAG, `Failed to register window stage listener: ${err}`);
    }
  }

  private unregisterMainWindowShownListener(): void {
    if (this.windowStageForEvents !== null && this.windowStageEventCallback !== null) {
      try {
        this.windowStageForEvents.off('windowStageEvent', this.windowStageEventCallback);
      } catch (err) {
        console.error(TAG, `Failed to unregister window stage listener: ${err}`);
      }
    }
    this.windowStageForEvents = null;
    this.windowStageEventCallback = null;
  }

  private onMainWindowShown(): void {
    if (!this.pipSessionActive || this.pipStopping) {
      return;
    }
    console.info(TAG, 'Main window shown while PiP active; stopping PiP');
    this.pipStopping = true;
    this.pipController?.stopPiP().catch((err: BusinessError) => {
      console.error(TAG, `stopPiP on main window shown failed. Code: ${err.code}, Message: ${err.message}`);
    });
  }

  /**
   * Attach the Flutter engine to the PiP XComponent surface so the engine
   * presents into the PiP window. Called on ABOUT_TO_START; attach order vs
   * surface creation does not matter (the adapter handles both orders).
   */
  private attachPipSurface(): void {
    if (this.flutterNapi === null || this.pipXComponentId === '') {
      console.error(TAG, 'Cannot attach PiP surface: engine napi or node id missing');
      return;
    }
    console.info(TAG, `Attaching Flutter engine to PiP surface: ${this.pipXComponentId}`);
    this.flutterNapi.xComponentAttachFlutterEngine(this.pipXComponentId);
  }

  /**
   * Keep the engine producing frames while the app is backgrounded but the
   * PiP window is visible. Two things normally stop rendering on background:
   * - the engine reclaims GPU resources (the embedding's PiPVisibilityBridge
   *   would prevent this, but it depends on window.getGlobalWindowMode which
   *   is API 20+, so on older devices it never reports the PiP as visible);
   * - the embedding sends AppLifecycleState.paused to Dart, which stops the
   *   framework from scheduling frames.
   * Counter both: force the engine's pip-visible flag, and report `inactive`
   * (the state Android uses while in PiP) instead of `paused` to Dart.
   */
  private keepRenderingForPip(): void {
    if (!this.pipSessionActive) {
      return;
    }
    this.flutterNapi?.setPipVisible(true);
    this.flutterEngine?.getLifecycleChannel()?.appIsInactive();
  }

  /**
   * While PiP is active, push the PiP window size as Flutter's viewport
   * metrics, otherwise the engine keeps the main-window layout and the PiP
   * window would only show a top-left crop of it. Also fires when the user
   * resizes the PiP window.
   */
  private onPipContentSizeChange(size: SizeOptions): void {
    if (this.pipStopping) {
      return;
    }
    const width = (size.width ?? 0) as number;
    const height = (size.height ?? 0) as number;
    if (width <= 0 || height <= 0) {
      return;
    }
    if (!this.pipStateDelivered || !this.pipSessionActive) {
      // Not ready to push yet (Dart has not confirmed the pip state, or the
      // event fired before the session flags were set). Never drop the event
      // — it may be the only size report of the whole session.
      this.pendingPipContentSize = size;
      return;
    }
    const view = this.getActiveFlutterView();
    if (view === null) {
      return;
    }
    console.info(TAG, `PiP content size: ${width}x${height} (vp)`);
    const area: Area = {
      width: width,
      height: height,
      position: { x: 0, y: 0 },
      globalPosition: { x: 0, y: 0 },
    };
    view.onAreaChange(area, false);
    this.pipMetricsPushed = true;
  }

  /**
   * Ensure pip-size metrics reach the engine even when no usable
   * onSizeChange event exists: measure the content node directly.
   */
  private ensurePipMetricsPushed(): void {
    if (this.pipMetricsPushed || !this.pipSessionActive || this.pipStopping || !this.pipStateDelivered) {
      return;
    }
    const pending = this.pendingPipContentSize;
    if (pending !== null) {
      this.pendingPipContentSize = null;
      this.onPipContentSizeChange(pending);
      if (this.pipMetricsPushed) {
        return;
      }
    }
    const measured = this.pipNodeController?.getContentSizeVp();
    if (measured !== undefined && measured !== null) {
      console.info(TAG, 'Pushing PiP metrics from measured node size (fallback)');
      this.onPipContentSizeChange(measured);
    }
  }

  /**
   * Switch rendering back to the main FlutterView surface and restore the
   * main window viewport metrics. Called when the PiP session ends.
   */
  private onPipSessionEnded(): void {
    this.pipSessionActive = false;
    this.flutterNapi?.setPipVisible(false);
    this.syncDartLifecycle();
    this.restoreMainSurfaceAndMetrics();
    this.scheduleControllerRebuild();
  }

  /**
   * Switch rendering back to the main FlutterView surface and push the main
   * window viewport metrics.
   *
   * Called already at ABOUT_TO_STOP/ABOUT_TO_RESTORE (not just STOPPED) so
   * the switch-over and the full-size relayout run in parallel with the
   * system's restore animation; deferring them to STOPPED shows up as ~1s of
   * frozen frame after the animation. The PiP window keeps showing its last
   * frame during the animation, which is acceptable for a transition.
   */
  private restoreMainSurfaceAndMetrics(): void {
    if (this.mainSurfaceRestored) {
      return;
    }
    this.mainSurfaceRestored = true;
    if (this.flutterNapi === null) {
      return;
    }
    if (this.pipXComponentId !== '') {
      // Safe even if the PiP surface was already destroyed natively:
      // the adapter ignores detach calls for unknown ids.
      this.flutterNapi.xComponentDetachFlutterEngine(this.pipXComponentId);
    }
    const mainView = this.getActiveFlutterView();
    if (mainView !== null) {
      console.info(TAG, `Re-attaching Flutter engine to main view: ${mainView.getId()}`);
      this.flutterNapi.xComponentAttachFlutterEngine(mainView.getId());
      // The main-window viewport metrics are pushed in onPipStateDelivered
      // once Dart has acknowledged leaving PiP, so the relayout the metrics
      // trigger already renders the normal (non-PiP) layout.
    } else {
      console.error(TAG, 'No FlutterView found to restore rendering to');
    }
  }

  /**
   * After a PiP session we may have overridden the Dart lifecycle with
   * `inactive`; bring it back in line with the real ability state (resumed
   * when the main window is showing again, paused when the PiP window was
   * closed while the app stays in background).
   */
  private syncDartLifecycle(): void {
    try {
      const manager = FlutterManager.getInstance();
      const uiAbility = manager.getUIAbility(getContext());
      const mainWindow = manager.getWindowStage(uiAbility).getMainWindowSync();
      if (mainWindow.isWindowShowing()) {
        this.flutterEngine?.getLifecycleChannel()?.appIsResumed();
      } else {
        this.flutterEngine?.getLifecycleChannel()?.appIsPaused();
      }
    } catch (err) {
      console.error(TAG, `Failed to sync Dart lifecycle: ${err}`);
    }
  }

  /**
   * Push the main window size back as viewport metrics after PiP ends.
   */
  private restoreMainViewportMetrics(view: FlutterView): void {
    try {
      const manager = FlutterManager.getInstance();
      const uiAbility = manager.getUIAbility(getContext());
      const mainWindow = manager.getWindowStage(uiAbility).getMainWindowSync();
      const rect = mainWindow.getWindowProperties().windowRect;
      const uiContext = mainWindow.getUIContext();
      const area: Area = {
        width: uiContext.px2vp(rect.width),
        height: uiContext.px2vp(rect.height),
        position: { x: 0, y: 0 },
        globalPosition: { x: 0, y: 0 },
      };
      view.onAreaChange(area, true);
    } catch (err) {
      const error = err as BusinessError;
      console.error(TAG, `Failed to restore main viewport metrics. Code: ${error.code}, Message: ${error.message}`);
    }
  }

  /**
   * The content node and its surface cannot survive a PiP session (see
   * createPipContentNode), so dispose the controller and, if auto-start is
   * still requested, rebuild it with a fresh node so the next minimize
   * triggers PiP again. For manual sessions this also restores the
   * auto-start setting to off.
   */
  private scheduleControllerRebuild(): void {
    // Rebuild outside the stateChange callback of the controller being disposed.
    setTimeout(() => {
      // 手动小窗时 handleEnablePip 临时调了 setAutoStartEnabled(true) 来模拟
      // 立即进入小窗，现在需要把 auto-start 关掉，否则系统残留的设置会导致下次
      // 返回桌面时自动创建一个没有 surface 的黑屏小窗。
      if (this.pipController) {
        this.pipController.setAutoStartEnabled(false);
      }
      this.disposePipController();
      if (this.autoStartRequested) {
        this.init().then((initSuccess: boolean) => {
          if (initSuccess) {
            this.pipController?.setAutoStartEnabled(true);
          } else {
            console.error(TAG, 'Failed to rebuild PiP controller for auto-start');
          }
        });
      }
    }, 0);
  }

  /**
   * Returns the FlutterView that should receive rendering after PiP ends.
   * Plugins cannot reach the FlutterView through the binding, so take the
   * most recently registered one (single-view apps have exactly one).
   */
  private getActiveFlutterView(): FlutterView | null {
    let result: FlutterView | null = null;
    FlutterManager.getInstance().getFlutterViewList().forEach((view: FlutterView) => {
      result = view;
    });
    return result;
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
        this.pipSessionActive = true;
        this.pipStopping = false;
        this.mainSurfaceRestored = false;
        this.pipStateDelivered = false;
        this.pendingPipContentSize = null;
        this.pipMetricsPushed = false;
        // Report the PiP state to Dart already here, before the PiP window
        // lays out: the app reads it when the viewport-size change triggers
        // a rebuild, and must already see "in PiP" to switch to its compact
        // (video-only) layout instead of squeezing the whole page.
        newIsInPipMode = true;
        this.attachPipSurface();
        this.keepRenderingForPip();
        break;
      case PiPWindow.PiPState.STARTED:
        stateName = 'STARTED';
        newIsInPipMode = true;
        // Re-assert now and shortly after: the embedding sends `paused` to
        // Dart when the ability finishes hiding, which can land after
        // ABOUT_TO_START and would stop frame production again.
        this.keepRenderingForPip();
        this.ensurePipMetricsPushed();
        // Sync the control panel play/pause icon with the app's playback
        // state now that the panel exists.
        this.applyPipControlStatus();
        setTimeout(() => {
          this.keepRenderingForPip();
          this.ensurePipMetricsPushed();
        }, 500);
        break;
      case PiPWindow.PiPState.ABOUT_TO_STOP:
        stateName = 'ABOUT_TO_STOP';
        this.pipStopping = true;
        // Start the switch-over already during the closing/restore animation;
        // see restoreMainSurfaceAndMetrics.
        newIsInPipMode = false;
        this.restoreMainSurfaceAndMetrics();
        break;
      case PiPWindow.PiPState.STOPPED:
        stateName = 'STOPPED';
        newIsInPipMode = false;
        this.pipStopping = false;
        this.onPipSessionEnded();
        break;
      case PiPWindow.PiPState.ABOUT_TO_RESTORE:
        stateName = 'ABOUT_TO_RESTORE';
        this.pipStopping = true;
        newIsInPipMode = false;
        this.restoreMainSurfaceAndMetrics();
        break;
      case PiPWindow.PiPState.ERROR:
        stateName = 'ERROR';
        newIsInPipMode = false;
        this.pipStopping = false;
        this.onPipSessionEnded();
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
   * Dispose the PiP surface node controller and forget its id.
   */
  private disposePipNodeController(): void {
    if (this.pipNodeController !== undefined) {
      try {
        this.pipNodeController.destroyNode();
      } catch (err) {
        console.error(TAG, `Failed to dispose PiP node controller: ${err}`);
      }
      this.pipNodeController = undefined;
    }
    this.pipXComponentId = '';
  }

  /**
   * Handle PiP active status changes.
   * true = PiP window is onscreen, false = offscreen.
   */
  private handleActiveStatusChange(active: boolean): void {
    console.info(TAG, `activeStatusChange: ${active}`);
  }

  /**
   * Forward a PiP control panel button press to Dart.
   * For the VIDEO_PLAY template `event` is one of 'playbackStateChanged',
   * 'nextVideo', 'previousVideo'; for 'playbackStateChanged' `status` is the
   * requested state (1 = play, 0 = pause).
   */
  private handleControlPanelAction(event: PiPWindow.PiPActionEventType, status?: number): void {
    console.info(TAG, `controlPanelActionEvent: ${event}, status: ${status}`);
    if (this.channel === null) {
      return;
    }
    const args = new Map<string, string | number | null>();
    args.set('event', event as string);
    args.set('status', status ?? null);
    this.channel.invokeMethod('onPipAction', args);
  }

  /**
   * Handle updatePipControlStatus method call (Dart → native): sync the
   * play/pause icon on the PiP control panel with the app's playback state.
   */
  private handleUpdatePipControlStatus(call: MethodCall, result: MethodResult): void {
    const playing: boolean = call.argument('playing') ?? false;
    this.lastPlaybackPlaying = playing;
    this.applyPipControlStatus();
    result.success(true);
  }

  /**
   * Apply the cached playback state to the current controller's control
   * panel. No-op until Dart has reported a state at least once.
   */
  private applyPipControlStatus(): void {
    if (this.pipController === undefined || this.lastPlaybackPlaying === null) {
      return;
    }
    try {
      this.pipController.updatePiPControlStatus(
        PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        this.lastPlaybackPlaying ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE);
    } catch (err) {
      const error = err as BusinessError;
      console.error(TAG, `updatePiPControlStatus failed. Code: ${error.code}, Message: ${error.message}`);
    }
  }

  /**
   * Dispose the PiP controller and its content node.
   */
  private disposePipController(): void {
    if (this.pipController !== undefined) {
      try {
        this.pipController.off('stateChange');
        console.info(TAG, 'PiPController state change listener unregistered');
      } catch (err) {
        const error = err as BusinessError;
        console.error(TAG,
          `Failed to unregister state change listener. Code: ${error.code}, Message: ${error.message}`);
      }
      try {
        this.pipController.off('activeStatusChange');
      } catch (err) {
        console.error(TAG, `Failed to unregister active status listener: ${err}`);
      }
      try {
        this.pipController.off('controlPanelActionEvent');
      } catch (err) {
        console.error(TAG, `Failed to unregister control panel listener: ${err}`);
      }
      this.pipController = undefined;
      console.info(TAG, 'PiPController destroyed');
    }
    this.disposePipNodeController();
  }

  /**
   * Clean up PiP resources
   */
  private destroy(): void {
    if (this.pipController !== undefined && this.isInPipMode) {
      try {
        this.pipController.stopPiP();
      } catch (err) {
        console.error(TAG, `Failed to stop PiP on destroy: ${err}`);
      }
    }
    this.unregisterMainWindowShownListener();
    this.disposePipController();
    this.isInPipMode = false;
    this.pipSessionActive = false;
    this.pipStopping = false;
    this.pipStateDelivered = false;
    this.pendingPipContentSize = null;
    this.pipMetricsPushed = false;
    this.autoStartRequested = false;
  }

  /**
   * Callback invoked when PiP state changes.
   * Notifies Flutter and, once Dart has acknowledged the message, releases
   * the viewport-metrics push that matches the new state (see the
   * pipStateDelivered field comment for why the ordering matters).
   */
  private onPipStateChanged(isInPip: boolean): void {
    console.info(TAG, `onPipStateChanged: ${isInPip}`);
    if (this.channel === null) {
      this.onPipStateDelivered(isInPip);
      return;
    }
    this.channel.invokeMethod('onPipChanged', isInPip, {
      success: (result: Any) => {
        this.onPipStateDelivered(isInPip);
      },
      error: (errorCode: string, errorMessage: string, errorDetails: Any) => {
        console.error(TAG, `onPipChanged delivery error: ${errorCode} ${errorMessage}`);
        this.onPipStateDelivered(isInPip);
      },
      notImplemented: () => {
        this.onPipStateDelivered(isInPip);
      },
    } as MethodResult);
  }

  private onPipStateDelivered(isInPip: boolean): void {
    console.info(TAG, `onPipChanged(${isInPip}) acknowledged by Dart`);
    if (isInPip) {
      this.pipStateDelivered = true;
      this.ensurePipMetricsPushed();
    } else {
      this.pushMainViewportMetrics();
    }
  }

  private pushMainViewportMetrics(): void {
    const view = this.getActiveFlutterView();
    if (view !== null) {
      this.restoreMainViewportMetrics(view);
    }
  }
}
