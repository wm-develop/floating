import { FlutterManager, FlutterPage } from '@ohos/flutter_ohos';
import { NodeController, BuilderNode, FrameNode, UIContext } from '@kit.ArkUI';

declare class Params {
  text: string
}

@Builder
function builder(params: Params) {
  FlutterPage()
}


class MyNodeController extends NodeController {
  private rootNode: BuilderNode<[Params]> | null = null;
  private wrapBuilder: WrappedBuilder<[Params]> = wrapBuilder(builder);

  makeNode(uiContext: UIContext): FrameNode | null {
    if (this.rootNode === null) {
      this.rootNode = new BuilderNode(uiContext);
      this.rootNode.build(this.wrapBuilder, { text: "This is a Text" })
    }
    return this.rootNode.getFrameNode();
  }

  t() {
    FlutterManager.getInstance()
  }
}