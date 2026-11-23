// Runs agents' shell commands without the desktop, and (with a sandbox) in
// smx-ai-sandbox. A session's commands get its client's environment (e.g.
// the terminal's), whatever the server's, so this unsets in them what the
// server runs without (see ../../nixos/ai.nix). The sandbox, given the shell
// they'd have run in, runs them in it (see ../sandbox.sh).
export default {
  id: "smudgenix",
  async setup(ctx) {
    const unset = ctx.options.unsetEnvironment ?? [];
    const sandbox = ctx.options.sandbox ?? null;
    await ctx.shell.hook("create.before", (event) => {
      for (const name of unset) delete event.env[name];
      if (sandbox) {
        event.env.SMX_AI_SHELL = event.shell;
        event.shell = sandbox;
      }
    });
  },
};
