// smudgenix's OpenCode plugin.
//
// - Runs agents' shell commands without the desktop, and (with a sandbox) in
//   smx-ai-sandbox. A session's commands get its client's environment (e.g.
//   the terminal's), whatever the server's, so this unsets in them what the
//   server runs without (see ../../nixos/ai.nix). The sandbox, given the
//   shell they'd have run in, runs them in it (see ../sandbox.sh).
// - Gives agents the decision log: what stands for their project and thread
//   (`smx ai log --for-agent`), in their context on every request; a tool to
//   make a small call provisionally (`smx ai decide --by-agent`); and what you
//   answer to OpenCode's own question tool, recorded as your decision. smx ai
//   does the work; this only connects it to OpenCode. (Agents' own commands
//   can't write the log: their sandbox can't.)
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

    // What you answer an agent's question (OpenCode's question tool) is your
    // decision, in its thread: recorded as yours, not by the agent.
    await ctx.tool.hook("execute.after", async (event) => {
      if (event.tool !== "question" || event.status !== "completed") return;
      try {
        const questions = event.input?.questions ?? [];
        const answers = event.result?.output?.answers ?? event.result?.metadata?.answers ?? [];
        const { dir, thread } = await where(event.sessionID);
        for (const [i, q] of questions.entries()) {
          const said = (answers[i] ?? []).map((a) => String(a).replace(/\s*\(Recommended\)\s*$/i, "")).filter(Boolean);
          if (!said.length) continue;
          const line = `${q.header || q.question}: ${said.join(", ")}`.replace(/\s+/g, " ").slice(0, 200);
          await run(smxAi, ["decide", line, "--why", `Asked: ${q.question}`.replace(/\s+/g, " ").slice(0, 300), "--thread", thread], dir);
        }
      } catch (error) {
        console.error(`smudgenix: couldn't record an answer: ${error.message}`);
      }
    });

    await ctx.tool.transform((editor) => {
      editor.namespace({ name: "smudgenix", description: "The person's decision log (smudgenix)" });
      // A thread's stack (smx ai stack): its agent commits and revises layers
      // through these, never with git or jj itself.
      editor.add({
        name: "commit",
        description:
          "Commit what you've changed as the next layer of your stack, with its purpose as a short commit title " +
          "(72 characters at most, no attribution). One purpose per layer, each safe to land on its own. While " +
          "revising a layer (smudgenix_revise), it goes into that layer instead (purpose optional: it keeps its own).",
        input: {
          type: "object",
          properties: { purpose: { type: "string", description: "A commit title: what the layer is for" } },
          additionalProperties: false,
        },
        options: { namespace: "smudgenix" },
        execute: async (input, context) => {
          const { dir, thread } = await where(context.sessionID);
          const args = ["stack", "commit", "--session", thread];
          if (input.purpose) args.push(input.purpose);
          return { content: await run(smxAi, args, dir) };
        },
      });
      editor.add({
        name: "revise",
        description:
          "Start changing a layer of your stack, approved or not (by its number, or change id): change the " +
          "files, then smudgenix_commit puts the change into it, and the layers above restack on it.",
        input: {
          type: "object",
          properties: { layer: { type: "string", description: "Its number (from the bottom, 1) or change id" } },
          required: ["layer"],
          additionalProperties: false,
        },
        options: { namespace: "smudgenix" },
        execute: async (input, context) => {
          const { dir, thread } = await where(context.sessionID);
          return { content: await run(smxAi, ["stack", "revise", "--session", thread, input.layer], dir) };
        },
      });
      editor.add({
        name: "stack",
        description: "Show your stack: its layers, bottom first, and whether there are changes not committed yet.",
        input: { type: "object", properties: {}, additionalProperties: false },
        options: { namespace: "smudgenix" },
        execute: async (_input, context) => {
          const { dir, thread } = await where(context.sessionID);
          return { content: await run(smxAi, ["stack", thread], dir) };
        },
      });
      editor.add({
        name: "pause",
        description:
          "Say why you're stopping, as the last thing in every turn: decision (you need the person to decide something), " +
          "uncertain (unsure how to go on), conflict (what you were told conflicts with what stands), failing " +
          "(a check or build fails and you can't fix it), lead (as many layers wait for approval as you may get " +
          "ahead), appetite (it's costing more than it's worth) or done (all of it is done). Then end your turn.",
        input: {
          type: "object",
          properties: {
            reason: { type: "string", enum: ["decision", "uncertain", "conflict", "failing", "lead", "appetite", "done"] },
            line: { type: "string", description: "One line on it, for the person" },
          },
          required: ["reason", "line"],
          additionalProperties: false,
        },
        options: { namespace: "smudgenix" },
        execute: async (input, context) => {
          const { dir, thread } = await where(context.sessionID);
          await run(smxAi, ["pause", "--session", context.sessionID, "--thread", thread, "--reason", input.reason, input.line], dir);
          return { content: "Noted. End your turn now." };
        },
      });
      editor.add({
        name: "decide",
        description:
          "Record a small, reversible call you made within the direction and constraints in the decision log, " +
          "so the person can confirm or overturn it. One line, and why in a few words. Not for judgment calls " +
          "(ask the person with your question tool), nor for anything that would break a constraint.",
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
