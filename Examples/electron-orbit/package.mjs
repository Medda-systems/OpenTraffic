// Builds dist/Orbit.app, a finished app like electron-builder or Forge make: Electron with the app's
// code packed into Contents/Resources/app.asar. `--no-run-as-node` turns off the RunAsNode fuse,
// as Forge's template does, so OpenTraffic has to bring its own copy of the same Electron.
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createPackage } from "@electron/asar";
import { flipFuses, FuseVersion, FuseV1Options } from "@electron/fuses";

const here = import.meta.dirname;
const app = join(here, "dist", "Orbit.app");
const stage = join(here, "dist", "stage");
rmSync(join(here, "dist"), { recursive: true, force: true });
mkdirSync(stage, { recursive: true });
execFileSync("ditto", [join(here, "node_modules/electron/dist/Electron.app"), app]);

for (const file of ["main.js", "preload.js", "package.json"]) cpSync(join(here, file), join(stage, file));
cpSync(join(here, "renderer"), join(stage, "renderer"), { recursive: true });
await createPackage(stage, join(app, "Contents/Resources/app.asar"));
rmSync(join(app, "Contents/Resources/default_app.asar"), { force: true });
rmSync(stage, { recursive: true });

const plist = join(app, "Contents/Info.plist");
let info = readFileSync(plist, "utf8");
for (const [key, value] of [["CFBundleName", "Orbit"], ["CFBundleDisplayName", "Orbit"], ["CFBundleIdentifier", "dev.opentraffic.orbit"]]) {
  info = info.replace(new RegExp(`(<key>${key}</key>\\s*<string>)[^<]*(</string>)`), `$1${value}$2`);
}
writeFileSync(plist, info);

if (process.argv.includes("--no-run-as-node")) {
  await flipFuses(app, { version: FuseVersion.V1, resetAdHocDarwinSignature: true, [FuseV1Options.RunAsNode]: false });
}
execFileSync("codesign", ["--force", "--deep", "--sign", "-", app], { stdio: "ignore" });
console.log(`Built ${app}`);
