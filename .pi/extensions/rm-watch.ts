// firstmate-rm watcher extension for the main Pi agent.
//
// Monitors filesystem status files from worker pi agents and:
//   - Shows notifications when status changes
//   - Detects "blocked" status, extracts the question, presents to user
//   - Detects "completed" status, extracts done report and last message
//   - Provides tools for the main agent to spawn workers, check status,
//     send answers, and manage the workflow lifecycle

import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  readdirSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Box, Container, Text, type Component } from "@earendil-works/pi-tui";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const rmHome = process.env.RM_HOME || root;
const rmStateDir = process.env.RM_STATE_OVERRIDE || join(rmHome, "state");
const rmBin = join(rmHome, "bin");
const workersDir = join(rmStateDir, "workers");

// Known statuses and their visual meanings
type WorkerStatus = "spawned" | "working" | "blocked" | "completed" | "failed" | "pr_created" | "pr_reviewed" | "unknown";

interface WorkerState {
  taskId: string;
  status: WorkerStatus;
  message: string;
  lastSeenTs: number;
  notificationSent: boolean;
}

interface RenderState {
  shell?: Box;
  rows: Component[];
}

// Helper: read a field from a status file
function readStatusField(taskId: string, field: string): string | null {
  const file = join(workersDir, `${taskId}.status`);
  if (!existsSync(file)) return null;
  const content = readFileSync(file, "utf8");
  for (const line of content.split("\n")) {
    if (line.startsWith(`${field}=`)) {
      return line.slice(field.length + 1).trim();
    }
  }
  return null;
}

// Helper: read the last message file
function readLastMessage(taskId: string): string {
  const file = join(workersDir, `${taskId}.lastmsg`);
  if (!existsSync(file)) return "(no message)";
  return readFileSync(file, "utf8").trim();
}

// Helper: read the done report file
function readDoneReport(taskId: string): string {
  const file = join(workersDir, `${taskId}.done-report`);
  if (!existsSync(file)) return "(no report)";
  return readFileSync(file, "utf8").trim();
}

// Helper: read the blocking question file
function readBlockingQuestion(taskId: string): string | null {
  const file = join(workersDir, `${taskId}.blocking-question`);
  if (!existsSync(file)) return null;
  return readFileSync(file, "utf8").trim();
}

// Helper: read the PR URL
function readPrUrl(taskId: string): string | null {
  const file = join(workersDir, `${taskId}.pr`);
  if (!existsSync(file)) return null;
  const content = readFileSync(file, "utf8");
  for (const line of content.split("\n")) {
    if (line.startsWith("pr_url=")) {
      return line.slice(7).trim();
    }
  }
  return null;
}

// Helper: list all known tasks
function listTasks(): string[] {
  if (!existsSync(workersDir)) return [];
  return readdirSync(workersDir)
    .filter((f) => f.endsWith(".status"))
    .map((f) => f.slice(0, -7));
}

// Helper: read current status
function readStatus(taskId: string): WorkerStatus {
  const raw = readStatusField(taskId, "status") as WorkerStatus | null;
  return raw || "unknown";
}

// Helper: read message from status
function readStatusMessage(taskId: string): string {
  return readStatusField(taskId, "message") || "";
}

// Helper: timestamp of last modification
function statusTimestamp(taskId: string): number {
  const file = join(workersDir, `${taskId}.status`);
  if (!existsSync(file)) return 0;
  return statSync(file).mtimeMs;
}

// Helper: run a bin script
function runBin(script: string, args: string[]): { ok: boolean; stdout: string; stderr: string } {
  const result = spawnSync("bash", [join(rmBin, script), ...args], {
    cwd: rmHome,
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  return {
    ok: result.status === 0,
    stdout: result.stdout?.trim() ?? "",
    stderr: result.stderr?.trim() ?? "",
  };
}

// Notify type for the main agent via followUp message.
// sendUserMessage may be undefined (print/JSON mode) or return undefined.
// Guard every call so a missing method never crashes the poll loop.
function notifyAgent(pi: ExtensionAPI, message: string, _type: "info" | "warning" | "error" = "info") {
  const send = pi.sendUserMessage;
  if (typeof send !== "function") return;
  const promise = send(`[RM-NOTIFICATION] ${message}`, { deliverAs: "followUp" });
  if (promise && typeof promise.catch === "function") {
    promise.catch(() => {});
  }
}

export default function (pi: ExtensionAPI) {
  // Track which status notifications we've already sent
  const notifiedStatuses = new Map<string, string>(); // taskId -> status
  const knownWorkers = new Map<string, WorkerState>();

  // Non-blocking status watches: taskId -> { targetStatus, callback }
  // Registered by rm_wait_for_worker, checked every poll cycle.
  // When the target status is detected, the callback fires a followUp
  // notification and the watch is removed.
  interface StatusWatch {
    targetStatus: string;
    startedAt: number;
    timeoutMs: number;
    fired: boolean;
  }
  const statusWatches = new Map<string, StatusWatch>();

  // Debounce agent-settled notifications so "Ready for new orders" fires
  // at most once in a MIN_READY_INTERVAL window, preventing spam when
  // followUp notifications arrive in quick succession.
  const MIN_READY_INTERVAL = 5_000;
  let lastReadyNotification = 0;

  // Polling interval
  let pollTimer: ReturnType<typeof setInterval> | null = null;
  let paused = false;

  // Render state for status tool
  const renderState: RenderState = { rows: [] };

  // --- Polling function ---
  function pollWorkers() {
    if (paused) return;
    const tasks = listTasks();
    const now = Date.now();

    // Phase 1: detect status transitions and fire notifications
    for (const taskId of tasks) {
      const status = readStatus(taskId);
      const message = readStatusMessage(taskId);
      const prevStatus = notifiedStatuses.get(taskId);

      if (status !== prevStatus && status !== "unknown") {
        notifiedStatuses.set(taskId, status);

        switch (status) {
          case "blocked": {
            const question = readBlockingQuestion(taskId);
            const qText = question ? `\nQuestion: ${question}` : "";
            notifyAgent(
              pi,
              `Worker "${taskId}" is BLOCKED.${qText}\n\nUse rm_check_worker to review the question and rm_answer_worker to provide guidance.`,
              "warning",
            );
            break;
          }
          case "completed": {
            const lastMsg = readLastMessage(taskId);
            const report = readDoneReport(taskId);
            const prUrl = readPrUrl(taskId);
            const prText = prUrl ? `\nPR: ${prUrl}` : "";
            const reportText = report.length > 0 ? `\nReport: ${report}` : "";
            notifyAgent(
              pi,
              `Worker "${taskId}" COMPLETED.${prText}${reportText}\n\nLast message:\n${lastMsg}`,
              "info",
            );
            break;
          }
          case "failed": {
            notifyAgent(
              pi,
              `Worker "${taskId}" FAILED.\nMessage: ${message}`,
              "error",
            );
            break;
          }
          case "pr_created": {
            const prUrl = readPrUrl(taskId);
            const prText = prUrl ? `\nPR: ${prUrl}` : "";
            notifyAgent(
              pi,
              `Worker "${taskId}" created a PR.${prText}`,
              "info",
            );
            break;
          }
          case "working": {
            if (prevStatus === "spawned") {
              notifyAgent(
                pi,
                `Worker "${taskId}" is now actively working.`,
                "info",
              );
            }
            break;
          }
        }
      }
    }

    // Phase 2: check non-blocking status watches (registered by rm_wait_for_worker)
    for (const [taskId, watch] of statusWatches) {
      if (watch.fired) continue;

      // Check timeout
      if (now - watch.startedAt > watch.timeoutMs) {
        watch.fired = true;
        statusWatches.delete(taskId);
        notifyAgent(
          pi,
          `Watch timeout: Worker "${taskId}" did not reach status "${watch.targetStatus}" within ${Math.floor(watch.timeoutMs / 1000)}s (last status: ${readStatus(taskId)}).`,
          "warning",
        );
        continue;
      }

      // Check if target status reached
      const currentStatus = readStatus(taskId);
      if (currentStatus === watch.targetStatus) {
        watch.fired = true;
        statusWatches.delete(taskId);
        const msg = readStatusMessage(taskId);
        notifyAgent(
          pi,
          `Worker "${taskId}" reached status "${watch.targetStatus}".\nMessage: ${msg}`,
          "info",
        );
      }
    }
  }

  // --- Start/stop polling ---
  function startPolling() {
    if (pollTimer) return;
    // Initial poll
    const tasks = listTasks();
    for (const taskId of tasks) {
      const status = readStatus(taskId);
      if (status !== "unknown") {
        notifiedStatuses.set(taskId, status);
      }
    }
    pollTimer = setInterval(pollWorkers, 2000);
    pollTimer.unref();
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  // --- Lifecycle ---
  pi.on?.("session_start", (_event, ctx) => {
    mkdirSync(workersDir, { recursive: true });
    startPolling();
    // Show on startup when nothing is queued — UI notification only, no agent processing.
    if (typeof ctx.hasPendingMessages === "function" && !ctx.hasPendingMessages()) {
      ctx.ui?.notify?.("Ready for new orders", "info");
    }
  });

  pi.on?.("session_shutdown", () => {
    stopPolling();
  });

  // When the agent finishes processing and becomes truly idle (no pending
  // followUp or steer messages queued), signal readiness via UI notification.
  // Uses ctx.ui.notify so the user sees it but the agent is NOT triggered.
  // Debounced to at most once per MIN_READY_INTERVAL so rapid cycles don't spam.
  pi.on?.("agent_settled", (_event, ctx) => {
    const now = Date.now();
    if (now - lastReadyNotification < MIN_READY_INTERVAL) return;
    if (ctx.isIdle() && (!ctx.hasPendingMessages || !ctx.hasPendingMessages())) {
      lastReadyNotification = now;
      ctx.ui?.notify?.("Ready for new orders", "info");
    }
  });

  // --- Commands ---

  // /rm-status - show all worker statuses
  pi.registerCommand?.("rm-status", {
    description: "Show all known worker agents and their current status",
    handler: async (_args, ctx) => {
      const tasks = listTasks();
      if (tasks.length === 0) {
        ctx.ui.notify("No workers found", "info");
        return;
      }
      const lines: string[] = [];
      for (const taskId of tasks) {
        const status = readStatus(taskId);
        const msg = readStatusMessage(taskId);
        const prUrl = readPrUrl(taskId);
        let line = `  ${taskId}: ${status}`;
        if (msg) line += ` (${msg})`;
        if (prUrl) line += ` PR: ${prUrl}`;
        lines.push(line);
      }
      ctx.ui.notify(`Workers:\n${lines.join("\n")}`, "info");
    },
  });

  // /rm-spawn <task-id> <project-dir> - spawn a worker
  // /rm-cleanup <task-id> - clean up a completed task
  pi.registerCommand?.("rm-cleanup", {
    description: "Clean up a completed task's workspace and status files",
    handler: async (args, ctx) => {
      const taskId = args.trim();
      if (!taskId) {
        ctx.ui.notify("Usage: /rm-cleanup <task-id>", "warning");
        return;
      }
      // Try to get project dir from herdr meta
      const herdrMeta = join(rmStateDir, "herdr", `${taskId}.meta`);
      let projectDir = "";
      if (existsSync(herdrMeta)) {
        for (const line of readFileSync(herdrMeta, "utf8").split("\n")) {
          if (line.startsWith("worktree=")) {
            projectDir = line.slice(9).trim();
            break;
          }
        }
      }

      const args_list: string[] = [taskId];
      if (projectDir) args_list.push(projectDir);
      args_list.push("--force");

      const result = runBin("rm-cleanup.sh", args_list);
      if (result.ok) {
        ctx.ui.notify(`Cleanup complete for ${taskId}`, "info");
        notifiedStatuses.delete(taskId);
      } else {
        ctx.ui.notify(`Cleanup failed: ${result.stderr || result.stdout}`, "error");
      }
    },
  });

  // --- Tools ---

  pi.registerTool?.({
    name: "rm_list_workers",
    label: "List workers",
    description: "List all known worker agents and their current status.",
    promptSnippet: "List all spawned worker agents and their current status.",
    promptGuidelines: [
      "Use this to check on all workers, or before spawning a new one to avoid ID conflicts.",
    ],
    parameters: Type.Object({}),
    renderShell: "self",
    renderCall: (_args, theme, context) => {
      const state = context.state as RenderState;
      state.rows = [new Text(theme.fg("toolTitle", theme.bold("rm_list_workers")), 0, 0)];
      return refreshWorkersShell(state, theme, false, false);
    },
    renderResult: (result, _options, theme, context) => {
      const output = result.content
        .filter((item) => item.type === "text")
        .map((item) => item.text)
        .join("\n");
      const state = context.state as RenderState;
      state.rows = [new Text(theme.fg("toolOutput", output), 0, 0)];
      return refreshWorkersShell(state, theme, false, false);
    },
    execute: async () => {
      const tasks = listTasks();
      if (tasks.length === 0) {
        return { content: [{ type: "text", text: "No workers found." }], details: {} };
      }
      const lines: string[] = ["Workers:"];
      for (const taskId of tasks) {
        const status = readStatus(taskId);
        const msg = readStatusMessage(taskId);
        const prUrl = readPrUrl(taskId);
        let line = `  ${taskId}: ${status}`;
        if (msg) line += ` — ${msg}`;
        if (prUrl) line += `\n    PR: ${prUrl}`;
        lines.push(line);
      }
      return { content: [{ type: "text", text: lines.join("\n") }], details: {} };
    },
  });

  pi.registerTool?.({
    name: "rm_check_worker",
    label: "Check worker",
    description: "Check the status and last message of a specific worker agent.",
    promptSnippet: "Check a worker agent's current status, last message, and any details (blocking question, PR URL, done report).",
    promptGuidelines: [
      "Use this when a worker reports blocked or completed to see their question or results.",
      "The response includes the status, last message, PR URL (if any), and done report (if completed).",
    ],
    parameters: Type.Object({
      taskId: Type.String({ description: "Task identifier to check" }),
    }),
    execute: async (_toolCallId, params) => {
      const { taskId } = params;
      console.error(`[RM-DEBUG] rm_check_worker params: ${JSON.stringify(params)}`);
      const status = readStatus(taskId);
      if (status === "unknown") {
        return {
          content: [{ type: "text", text: `No worker found for task "${taskId}".` }],
          details: { taskId, status: "unknown" },
          isError: true,
        };
      }
      const msg = readStatusMessage(taskId);
      const lastMsg = readLastMessage(taskId);
      const prUrl = readPrUrl(taskId);
      const question = readBlockingQuestion(taskId);
      const report = readDoneReport(taskId);

      const parts: string[] = [
        `Task: ${taskId}`,
        `Status: ${status}`,
        `Message: ${msg}`,
      ];
      if (lastMsg.length > 0 && lastMsg !== "(no message)") {
        parts.push(`Last message:\n${lastMsg}`);
      }
      if (question) {
        parts.push(`Blocking question:\n${question}`);
      }
      if (prUrl) {
        parts.push(`PR URL: ${prUrl}`);
      }
      if (report.length > 0 && report !== "(no report)") {
        parts.push(`Done report:\n${report}`);
      }

      if (status === "blocked" && question) {
        parts.push("\nThis worker is blocked and waiting for your answer. Use rm_answer_worker to respond.");
      }
      if (status === "completed") {
        parts.push("\nThis worker has completed its task. The user should review the results. Use the report and PR to assess the work.");
      }

      return {
        content: [{ type: "text", text: parts.join("\n") }],
        details: { taskId, status, message: msg, prUrl, blocked: !!question },
      };
    },
  });

  pi.registerTool?.({
    name: "rm_answer_worker",
    label: "Answer worker",
    description: "Answer a blocked worker's question so it can continue implementing.",
    promptSnippet: "Provide an answer to a blocked worker agent to unblock it.",
    promptGuidelines: [
      "First use rm_check_worker to see the worker's blocking question.",
      "Provide a clear, actionable answer. The worker will read the answer file and continue.",
    ],
    parameters: Type.Object({
      taskId: Type.String({ description: "Task identifier of the blocked worker" }),
      answer: Type.String({ description: "Your answer to the worker's question" }),
    }),
    execute: async (_toolCallId, params) => {
      const { taskId, answer } = params;
      console.error(`[RM-DEBUG] rm_answer_worker params: ${JSON.stringify(params)}`);
      const status = readStatus(taskId);
      if (status !== "blocked") {
        return {
          content: [{ type: "text", text: `Worker "${taskId}" is not blocked (status: ${status}). No answer needed.` }],
          details: { taskId, status },
          isError: true,
        };
      }
      // Write the answer to the blocking-answer file
      const answerFile = join(workersDir, `${taskId}.blocking-answer`);
      writeFileSync(answerFile, `${answer}\n`, "utf8");
      // Also append to status indicating answer was provided
      const statusFile = join(workersDir, `${taskId}.status`);
      if (existsSync(statusFile)) {
        const content = readFileSync(statusFile, "utf8");
        writeFileSync(statusFile, `${content}event=answer_provided\nts=${Math.floor(Date.now() / 1000)}\n`, "utf8");
      }
      return {
        content: [{ type: "text", text: `Answer sent to worker "${taskId}". The worker will read it and continue.` }],
        details: { taskId, answerSent: true },
      };
    },
  });

  pi.registerTool?.({
    name: "rm_cleanup_task",
    label: "Cleanup task",
    description: "Clean up a task's herdr workspace, status files, and local branch after the PR is merged. Only use after the PR has been merged by the user.",
    promptSnippet: "Clean up all resources for a completed and merged task.",
    promptGuidelines: [
      "This should only be called after the user confirms the PR was merged.",
      "It destroys the herdr workspace, removes status files, and cleans up the local git branch.",
      "Use the --force flag to skip PR merge check if needed.",
    ],
    parameters: Type.Object({
      taskId: Type.String({ description: "Task identifier to clean up" }),
      force: Type.Optional(Type.Boolean({ description: "Skip PR merge check" })),
    }),
    execute: async (_toolCallId, params) => {
      const { taskId, force } = params;
      console.error(`[RM-DEBUG] rm_cleanup_task params: ${JSON.stringify(params)}`);
      const herdrMeta = join(rmStateDir, "herdr", `${taskId}.meta`);
      let projectDir = "";
      if (existsSync(herdrMeta)) {
        for (const line of readFileSync(herdrMeta, "utf8").split("\n")) {
          if (line.startsWith("worktree=")) {
            projectDir = line.slice(9).trim();
            break;
          }
        }
      }
      const args: string[] = [taskId];
      if (projectDir) args.push(projectDir);
      if (force) args.push("--force");

      const result = runBin("rm-cleanup.sh", args);
      if (result.ok) {
        notifiedStatuses.delete(taskId);
        return {
          content: [{ type: "text", text: `Cleanup complete for task "${taskId}".` }],
          details: { taskId, cleaned: true },
        };
      }
      return {
        content: [{ type: "text", text: `Cleanup failed: ${result.stderr || result.stdout}` }],
        details: { taskId, error: result.stderr || result.stdout },
        isError: true,
      };
    },
  });

  pi.registerTool?.({
    name: "rm_wait_for_worker",
    label: "Wait for worker (async)",
    description: "Register a non-blocking watch for a worker to reach a specific status (e.g. 'completed', 'blocked'). Returns immediately. The extension's async poll loop will notify you via a followUp message when the status is reached or the watch times out.",
    promptSnippet: "Register an async watch for when a worker reaches a target status. Non-blocking - returns immediately.",
    promptGuidelines: [
      "This is NON-BLOCKING. It returns immediately and the extension notifies you asynchronously when the status is reached.",
      "Default timeout is 300 seconds. Set a custom timeout if the task is expected to take longer.",
      "Do NOT sit and wait - just register the watch and continue with other work. You will be notified when the status arrives.",
    ],
    parameters: Type.Object({
      taskId: Type.String({ description: "Task identifier" }),
      targetStatus: Type.String({ description: "Status to wait for (e.g. 'completed', 'blocked', 'failed')" }),
      timeout: Type.Optional(Type.Number({ description: "Timeout in seconds (default 300)" })),
    }),
    execute: async (_toolCallId, params) => {
      const { taskId, targetStatus, timeout } = params;

      console.error(`[RM-DEBUG] rm_wait_for_worker params: ${JSON.stringify(params)}`);

      // Validate taskId — reject literal "undefined" or empty string
      if (!taskId || typeof taskId !== "string" || taskId === "undefined" || taskId === "null") {
        return {
          content: [{ type: "text", text: `Invalid taskId: ${JSON.stringify(taskId)}. You passed a ${typeof taskId} instead of a string. Make sure you are INVOKING the tool with a proper parameter like taskId="fix-auth", not writing it as text.\n\nDEBUG: Full params received: ${JSON.stringify(params)}` }],
          details: { error: "invalid taskId", receivedParams: params },
          isError: true,
        };
      }

      const maxWait = timeout ?? 300;
      const status = readStatus(taskId);

      // Worker doesn't exist yet (spawn bash script may still be running).
      // Register the watch anyway — the poll loop will pick it up when
      // the status file appears (next poll is within 2s).
      if (status === "unknown") {
        statusWatches.set(taskId, {
          targetStatus,
          startedAt: Date.now(),
          timeoutMs: maxWait * 1000,
          fired: false,
        });
        return {
          content: [{ type: "text", text: `Async watch registered for worker "${taskId}" to reach "${targetStatus}". Worker not yet visible (spawn may still be starting) — the extension will pick it up and notify you when the status arrives (timeout: ${maxWait}s).` }],
          details: { taskId, targetStatus, watching: true, timeout: maxWait, pendingSpawn: true },
        };
      }

      if (status === targetStatus) {
        const msg = readStatusMessage(taskId);
        return {
          content: [{ type: "text", text: `Worker "${taskId}" is already at status "${targetStatus}".\nMessage: ${msg}` }],
          details: { taskId, status, arrived: true },
        };
      }

      if (statusWatches.has(taskId)) {
        const existing = statusWatches.get(taskId)!;
        return {
          content: [{ type: "text", text: `A watch for worker "${taskId}" is already registered (target: ${existing.targetStatus}). You will be notified when it arrives.` }],
          details: { taskId, watchAlreadyRegistered: true, targetStatus: existing.targetStatus },
        };
      }

      statusWatches.set(taskId, {
        targetStatus,
        startedAt: Date.now(),
        timeoutMs: maxWait * 1000,
        fired: false,
      });

      return {
        content: [{ type: "text", text: `Async watch registered for worker "${taskId}" to reach "${targetStatus}". You will be notified when it arrives (timeout: ${maxWait}s). Continue with other work.` }],
        details: { taskId, targetStatus, watching: true, timeout: maxWait },
      };
    },
  });


  // --- Start polling on load ---
  mkdirSync(workersDir, { recursive: true });
  startPolling();
}

function refreshWorkersShell(state: RenderState, theme: any, isError: boolean, isPartial: boolean): Box {
  const background = isPartial
    ? (text: string) => theme.bg("toolPendingBg", text)
    : isError
      ? (text: string) => theme.bg("toolErrorBg", text)
      : (text: string) => theme.bg("toolSuccessBg", text);
  const shell = state.shell ?? new Box(1, 1, background);
  state.shell = shell;
  shell.setBgFn(background);
  shell.clear();
  for (const row of state.rows) {
    shell.addChild(row);
  }
  return shell;
}
