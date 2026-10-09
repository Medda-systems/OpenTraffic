import { Img, staticFile } from "remotion"
import { Camera, type Shot } from "./Camera"

/** The main window as captured (1180 × 760 pt at 2x): its own pixels are the scene's. */
export const window = { width: 2360, height: 1520 }

/** The zoom that fits the whole window on screen with room around it. */
export const fit = 1640 / window.width

/** A capture laid out in its own pixels (the main window's by default), for the camera to move over. */
export const WindowScene = ({ src, shots, size = window }: { src: string; shots: Shot[]; size?: { width: number; height: number } }) => (
  <Camera shots={shots}>
    <Img
      src={staticFile(src)}
      style={{ display: "block", width: size.width, height: size.height, filter: "drop-shadow(0 30px 60px rgba(15,23,42,.20)) drop-shadow(0 3px 10px rgba(15,23,42,.10))" }}
    />
  </Camera>
)
