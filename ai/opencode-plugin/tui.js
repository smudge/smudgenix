// smudgenix's OpenCode plugin (its TUI part): does what smx ai asks of the
// TUIs in this one's folder (see ./rpc.js): opens a session's tab (focusing
// it), or a new session, or closes a session's tab.
import { Smudgenix } from "./rpc.js";

export default {
  id: "smudgenix.tui",
  setup(context) {
    const here = (context.location ?? context.data.location.default())?.directory;
    const events = context.client.rpc(Smudgenix).events;
    const mine = (event) => here && event.location?.directory === here;
    const stops = [
      events.on("open", (event) => {
        if (!mine(event)) return;
        const session = event.data.session;
        if (!session) context.keymap.dispatch("session.new");
        else if (context.ui.tabs.enabled()) context.ui.tabs.focus(session);
        else context.ui.router.navigate({ type: "session", sessionID: session });
      }),
      events.on("close", (event) => {
        if (mine(event) && event.data.session && context.ui.tabs.enabled()) context.ui.tabs.close(event.data.session);
      }),
    ];
    return () => stops.forEach((stop) => stop());
  },
};
