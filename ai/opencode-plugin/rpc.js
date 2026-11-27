// smudgenix's RPC: smx ai asks the TUIs in a project's folder (the call's
// location) to open a session's tab, or a new session (no session given), or
// to close a session's tab. The server only passes it on, as an event; each
// TUI acts on those for its own folder (see ./tui.js).
import { Rpc } from "@opencode/plugin/rpc";

const request = {
  type: "object",
  properties: { session: { type: "string" } },
  additionalProperties: false,
};

export const Smudgenix = Rpc.define({
  id: "smudgenix",
  methods: {
    open: { input: request, output: { type: "object" } },
    close: { input: request, output: { type: "object" } },
  },
  events: {
    open: { schema: request },
    close: { schema: request },
  },
});
