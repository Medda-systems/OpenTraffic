const log = (line) => { document.getElementById("log").textContent = `${line}\n${document.getElementById("log").textContent}`.slice(0, 2000); };
const render = (notes) => {
  document.getElementById("notes").innerHTML = "";
  for (const note of notes) {
    const li = document.createElement("li");
    li.textContent = note.text;
    document.getElementById("notes").append(li);
  }
};

orbit.on("hello", ({ greeting }) => { document.getElementById("greeting").textContent = greeting; });
orbit.on("notes:changed", (count) => log(`notes changed: ${count}`));
orbit.on("pong", (n) => log(`pong ${n}`));
orbit.on("menu:new-note", () => document.getElementById("text").focus());
orbit.on("menu:export", () => document.getElementById("export").click());

document.getElementById("add").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = document.getElementById("text");
  if (!input.value.trim()) return;
  render(await orbit.addNote(input.value.trim()));
  input.value = "";
});
document.getElementById("open").onclick = async () => log(`opened: ${JSON.stringify(await orbit.openFile())}`);
document.getElementById("export").onclick = async () => log(`exported: ${await orbit.exportNotes()}`);
document.getElementById("api").onclick = async () => {
  try { log(`api: ${JSON.stringify(await orbit.apiStatus())}`); } catch (error) { log(`api failed: ${error.message}`); }
};
document.getElementById("link").onclick = () => orbit.openLink("https://opentraffic.dev");
document.getElementById("notify").onclick = () => orbit.notify("Hello from Orbit");

orbit.listNotes().then(render);
orbit.ping(41);
log(`version: ${JSON.stringify(orbit.versionSync())} on ${orbit.platform}`);
