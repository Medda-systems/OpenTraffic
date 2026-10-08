const releasesRepo = "https://github.com/Medda-systems/OpenTraffic-releases"

export const links = {
  installCommand: "curl -fsSL https://opentraffic.dev/install | sh",
  installScript: `${releasesRepo}/releases/latest/download/install.sh`,
  dmg: `${releasesRepo}/releases/latest/download/OpenTraffic.dmg`,
  releases: `${releasesRepo}/releases`,
  latestRelease: `${releasesRepo}/releases/latest`,
  homebrewTap: "https://github.com/Medda-systems/homebrew-tap",
  medda: "https://medda.se",
  cloudflared: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/",
}

export const homebrewCommands = [
  "brew tap medda-systems/tap",
  "brew trust --cask medda-systems/tap/opentraffic",
  "brew install --cask opentraffic",
]

/** The newest version, from GitHub's API (shown when it answers). */
export async function latestVersion(): Promise<string | null> {
  try {
    const response = await fetch("https://api.github.com/repos/Medda-systems/OpenTraffic-releases/releases/latest")
    if (!response.ok) return null
    const release = (await response.json()) as { tag_name?: string }
    return release.tag_name?.replace(/^v/, "") ?? null
  } catch {
    return null
  }
}
