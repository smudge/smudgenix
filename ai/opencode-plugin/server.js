// smudgenix's OpenCode plugin.
//
// - Runs agents' shell commands without the desktop, and (with a sandbox) in
//   smx-ai-sandbox. A session's commands get its client's environment (e.g.
//   the terminal's), whatever the server's, so this unsets in them what the
//   server runs without (see ../../nixos/ai.nix). The sandbox, given the
//   shell they'd have run in, runs them in it (see ../sandbox.sh).
// - Gives agents the decision log: what stands for their project and thread
//   (`smx ai log --for-agent`), in their context on every request; and two
//   tools, to ask you (`smx ai ask`) and to make a small call provisionally
//   (`smx ai decide --by-agent`). smx ai does the work; this only connects
//   it to OpenCode. (Agents' own commands can't write the log: their sandbox
//   can't.)
import { execFile } from "node:child_process";
import { statSync } from "node:fs";

const run = (smxAi, args, cwd) =>
  new Promise((resolve, reject) => {
    execFile(smxAi, args, { cwd, timeout: 15000, env: { ...process.env, NO_COLOR: "1" } },
      (error, stdout, stderr) => (error ? reject(new Error((stderr || error.message).trim())) : resolve(stdout)));
  });

const mtime = (path) => {
  try { return statSync(path).mtimeMs; } catch { return 0; }
};

export default {
  id: "smudgenix",
  async setup(ctx) {
    const unset = ctx.options.unsetEnvironment ?? [];
    const sandbox = ctx.options.sandbox ?? null;
    const smxAi = ctx.options.smxAi ?? null;
    // (Where smx ai keeps the log: only to notice it changing.)
    const store = `${process.env.XDG_DATA_HOME || `${process.env.HOME}/.local/share`}/smudgenix`;

    await ctx.shell.hook("create.before", (event) => {
      for (const name of unset) delete event.env[name];
      if (sandbox) {
        event.env.SMX_AI_SHELL = event.shell;
        event.shell = sandbox;
      }
    });

    if (!smxAi) return;

    // A session's folder, and its thread (its top-level session).
    const where = async (sessionID) => {
      let session = await ctx.session.get({ sessionID });
      session = session?.data ?? session;
      const dir = session?.location?.directory ?? session?.directory;
      let thread = session;
      for (let i = 0; thread?.parentID && i < 20; i++) {
        const parent = await ctx.session.get({ sessionID: thread.parentID });
        thread = parent?.data ?? parent;
      }
      return { dir, thread: thread?.id ?? sessionID };
    };

    // What stands, for a session's project and thread, as agents get it.
    // (Again only when the log changes.)
    const cache = new Map();
    const log = `${store}/decisions.jsonl`, briefs = `${store}/briefs.jsonl`;
    await ctx.session.hook("context", async (event) => {
      try {
        const { dir, thread } = await where(event.sessionID);
        if (!dir) return;
        const key = `${dir}\0${thread}\0${mtime(log)}\0${mtime(briefs)}`;
        if (!cache.has(event.sessionID) || cache.get(event.sessionID).key !== key) {
          const text = await run(smxAi, ["log", "--for-agent", "--thread", thread], dir);
          cache.set(event.sessionID, { key, text });
        }
        event.system.push({ type: "text", text: cache.get(event.sessionID).text });
      } catch (error) {
        console.error(`smudgenix: couldn't add the decision log: ${error.message}`);
      }
    });

    await ctx.tool.transform((editor) => {
      editor.namespace({ name: "smudgenix", description: "The person's decision log (smudgenix)" });
      editor.add({
        name: "ask",
        description:
          "Ask the person to decide a judgment call: a tradeoff they'd care about, something hard to reverse, " +
          "or a choice nothing in the decision log covers. Give one question, two or three one-line options, and " +
          "your pick. Then stop and end your turn: their answer comes back to you as a message.",
        input: {
          type: "object",
          properties: {
            question: { type: "string", description: "One line" },
            options: { type: "array", items: { type: "string", description: "One line" }, minItems: 2, maxItems: 4 },
            pick: { type: "integer", description: "Your recommendation: its number, from 1" },
            serves: { type: "string", description: "The id of the direction or decision it's for, if any" },
          },
          required: ["question", "options", "pick"],
          additionalProperties: false,
        },
        options: { namespace: "smudgenix" },
        execute: async (input, context) => {
          const { dir, thread } = await where(context.sessionID);
          const args = ["ask", "--session", context.sessionID, "--thread", thread, "--question", input.question,
            ...input.options.flatMap((o) => ["--option", o]), "--pick", String(input.pick)];
          if (input.serves) args.push("--serves", input.serves);
          const brief = JSON.parse(await run(smxAi, args, dir));
          return { content: `Asked (${brief.id}). Stop here and end your turn: the person's answer will come back to you.` };
        },
      });
      editor.add({
        name: "decide",
        description:
          "Record a small, reversible call you made within the direction and constraints in the decision log, " +
          "so the person can confirm or overturn it. One line, and why in a few words. Not for judgment calls " +
          "(ask), nor for anything that would break a constraint.",
        input: {
          type: "object",
          properties: {
            line: { type: "string", description: "The decision, one line" },
            why: { type: "string", description: "A few words" },
          },
          required: ["line"],
          additionalProperties: false,
        },
        options: { namespace: "smudgenix" },
        execute: async (input, context) => {
          const { dir, thread } = await where(context.sessionID);
          const args = ["decide", input.line, "--by-agent", context.sessionID, "--thread", thread, "--json"];
          if (input.why) args.push("--why", input.why);
          const entry = JSON.parse(await run(smxAi, args, dir));
          return { content: `Recorded (${entry.id}), provisionally: the person may confirm or overturn it.` };
        },
      });
    });
  },
};
