// Runs agents' shell commands without the desktop. A session's commands get
// its client's environment (e.g. the terminal's), whatever the server's, so
// this unsets in them what the server runs without (see ../../nixos/ai.nix).
export default {
  id: "smudgenix",
  async setup(ctx) {
    const unset = ctx.options.unsetEnvironment ?? [];
    await ctx.shell.hook("create.before", (event) => {
      for (const name of unset) delete event.env[name];
    });
  },
};
