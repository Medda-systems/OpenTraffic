import { Composition, continueRender, delayRender } from "remotion"
import { Demo, demoFrames } from "./Demo"
import { Promo, PROMO_FRAMES } from "./promo/Promo"
import { loadSession, type Session } from "./session"
import { fontsReady } from "./theme"

const waitForFonts = delayRender("Loading fonts")
fontsReady.then(() => continueRender(waitForFonts))

const withSession = async ({ props }: { props: { session: Session; captions?: boolean } }) => {
  const session = await loadSession()
  return { durationInFrames: demoFrames(session), props: { ...props, session } }
}

export const RemotionRoot = () => (
  <>
    <Composition id="Demo" component={Demo} calculateMetadata={withSession} defaultProps={{ session: null as unknown as Session }} durationInFrames={1} fps={30} width={1920} height={1080} />
    <Composition id="Stills" component={Demo} calculateMetadata={withSession} defaultProps={{ session: null as unknown as Session, captions: false }} durationInFrames={1} fps={30} width={1920} height={1080} />
    <Composition
      id="Promo"
      component={Promo}
      calculateMetadata={async () => ({ props: { session: await loadSession() } })}
      defaultProps={{ session: null as unknown as Session }}
      durationInFrames={PROMO_FRAMES}
      fps={30}
      width={1920}
      height={1080}
    />
  </>
)
