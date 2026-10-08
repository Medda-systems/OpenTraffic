import { Composition, continueRender, delayRender } from "remotion"
import { Demo, DEMO_FRAMES } from "./Demo"
import { fontsReady } from "./theme"

const waitForFonts = delayRender("Loading fonts")
fontsReady.then(() => continueRender(waitForFonts))

export const RemotionRoot = () => (
  <>
    <Composition id="Demo" component={Demo} durationInFrames={DEMO_FRAMES} fps={30} width={1920} height={1080} />
  </>
)
