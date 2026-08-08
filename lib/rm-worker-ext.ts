// firstmate-rm worker extension for spawned Pi agents.
//
// Provides:
//   - rm_report_status - report working, blocked, completed status
//   - rm_read_answer - read blocking answer from main agent
//   - rm_write_done_report - write a done report with summary
//
// The worker commits changes to the task branch and reports completion.
// Pushing, PR creation, and merging are done manually by the user.
//
// Communicates with the main agent exclusively via filesystem files under
// state/workers/<task-id>.*  The main agent's rm-watch extension polls
// these files asynchronously — no pane output is captured.
//
// Additionally fires a herdr notification as immediate UI feedback.

import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

const rmHome = process.env.RM_HOME || root;
const rmTaskId = process.env.RM_TASK_ID || "unknown";
const rmStateDir = process.env.RM_STATE_OVERRIDE || join(rmHome, "state");
const workersDir = join(rmStateDir, "workers");

// Ensure workers dir exists
mkdirSync(workersDir, { recursive: true });

// File helpers
const statusFile = () => join(workersDir, `${rmTaskId}.status`);
const lastMsgFile = () => join(workersDir, `${rmTaskId}.lastmsg`);
const blockingQuestionFile = () => join(workersDir, `${rmTaskId}.blocking-question`);
const blockingAnswerFile = () => join(workersDir, `${rmTaskId}.blocking-answer`);
const doneReportFile = () => join(workersDir, `${rmTaskId}.done-report`);
const sessionInfoFile = () => join(workersDir, `${rmTaskId}.session`);

function writeStatus(status: string, message: string) {
  const content = [
    `status=${status}`,
    `message=${message}`,
    `ts=${Math.floor(Date.now() / 1000)}`,
    `worker_id=worker-${rmTaskId}`,
  ].join("\n") + "\n";
  writeFileSync(statusFile(), content, "utf8");
}

function appendStatus(...lines: string[]) {
  appendFileSync(statusFile(), lines.join("\n") + "\n", "utf8");
}

function writeFileStr(path: string, content: string) {
  writeFileSync(path, `${content}\n`, "utf8");
}

function readFileStr(path: string): string | null {
  if (!existsSync(path)) return null;
  return readFileSync(path, "utf8").trim();
}

function runBash(command: string): { ok: boolean; stdout: string; stderr: string } {
  try {
    const stdout = execSync(command, { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 }).trim();
    return { ok: true, stdout, stderr: "" };
  } catch (e: any) {
    return { ok: false, stdout: e.stdout?.trim() ?? "", stderr: e.stderr?.trim() ?? e.message ?? "" };
  }
}

// Fire a herdr notification for immediate UI feedback.
// The main agent's watch extension also picks this up via filesystem polling.
function sendHerdrNotification(title: string, body: string, sound?: string) {
  const soundFlag = sound ? ` --sound ${sound}` : "";
  try {
    execSync(
      `herdr notification show ${JSON.stringify(title)} --body ${JSON.stringify(body)}${soundFlag}`,
      { encoding: "utf8", stdio: "ignore", timeout: 3000 },
    );
  } catch {
    // Notification is best-effort — never block the worker for this
  }
}

// Status-to-notification mapping
type StatusSound = "none" | "done" | "request" | undefined;
const statusSounds: Record<string, StatusSound> = {
  blocked: "request",
  completed: "done",
  failed: "request",
};

function notifyMain(status: string, message: string) {
  // 1) Write status to filesystem (primary channel — consumed by rm-watch)
  writeStatus(status, message);

  // 2) Fire a herdr notification (secondary channel — immediate UI cue)
  const sound = statusSounds[status];
  sendHerdrNotification(
    `Worker ${rmTaskId}: ${status}`,
    message,
    sound,
  );
}

// Persist the pi session ID so the main agent can resume this session.
// The session-id was set at launch via --session-id rm-<task-id>,
// so the main agent can resume it with `pi --session rm-<task-id>`.
function persistSessionInfo() {
  const sessionId = process.env.PI_SESSION_ID;
  if (sessionId) {
    writeFileStr(sessionInfoFile(), `session_id=${sessionId}\n`);
  }
}

export default function (pi: ExtensionAPI) {
  pi.on?.("session_start", () => {
    mkdirSync(workersDir, { recursive: true });
    notifyMain("working", "Worker pi agent started");
    writeFileStr(lastMsgFile(), "Worker agent started and ready.");
  });

  pi.on?.("session_shutdown", () => {
    // Persist session info on shutdown so the main agent can find it
    persistSessionInfo();
  });

  // --- Tools ---

  pi.registerTool?.({
    name: "rm_report_status",
    label: "Report status",
    description: "Report your current status back to the main pi agent. Use 'blocked' when you need user input, 'completed' when finished implementing, or 'working' for progress updates.",
    promptSnippet: "Report your current work status to the main pi agent.",
    promptGuidelines: [
      "Use status 'working' for progress updates (e.g., 'working on X module').",
      "Use status 'blocked' when you need user input or guidance. Also call rm_write_blocking_question to describe what you need.",
      "Use status 'completed' when you have finished implementing and committed your changes. Also call rm_write_done_report and rm_write_last_message before reporting completed. The user will push and merge manually.",
      "Use status 'failed' if the task cannot be completed.",
    ],
    parameters: Type.Object({
      status: StringEnum(["working", "blocked", "completed", "failed"] as const, { description: "Your current status" }),
      message: Type.String({ description: "A brief message describing your status" }),
    }),
    async execute(_toolCallId, params) {
      const { status, message } = params;
      notifyMain(status, message);
      // Persist session info on final statuses so the main agent can resume
      if (status === "completed" || status === "failed") {
        persistSessionInfo();
      }
      return {
        content: [{ type: "text", text: `Status reported: ${status} — ${message}` }],
        details: { status, message },
      };
    },
  });

  pi.registerTool?.({
    name: "rm_write_blocking_question",
    label: "Write blocking question",
    description: "Write a blocking question for the main pi agent. Call this BEFORE reporting 'blocked' status. The main agent will read this and provide an answer via rm_blocking_answer.",
    promptSnippet: "Write a question to the main pi agent when you need guidance or input to continue.",
    promptGuidelines: [
      "Call this BEFORE rm_report_status with status=blocked.",
      "Describe clearly what you need: what decision or information is blocking you.",
      "After the main pi agent provides the answer, call rm_read_blocking_answer to read it.",
    ],
    parameters: Type.Object({
      question: Type.String({ description: "Your question or what you need from the user" }),
    }),
    async execute(_toolCallId, params) {
      const { question } = params;
      writeFileStr(blockingQuestionFile(), question);
      return {
        content: [{ type: "text", text: `Blocking question written. Waiting for answer from main agent.` }],
        details: { question },
      };
    },
  });

  pi.registerTool?.({
    name: "rm_read_blocking_answer",
    label: "Read blocking answer",
    description: "Read the answer from the main pi agent. Call this after reporting 'blocked' status. If no answer is available yet, it will indicate that.",
    promptSnippet: "Check if the main pi agent has provided an answer to your blocking question.",
    promptGuidelines: [
      "If no answer is available yet, wait a bit and try again.",
      "Once you have the answer, continue implementing the task.",
    ],
    parameters: Type.Object({}),
    async execute() {
      const answer = readFileStr(blockingAnswerFile());
      if (answer) {
        // Remove the answer file so it's consumed once
        try { writeFileSync(blockingAnswerFile(), "", "utf8"); } catch {}
        // Clear the blocking question too
        try { writeFileSync(blockingQuestionFile(), "", "utf8"); } catch {}
        // Update status
        appendStatus("event=answer_received");
        writeFileStr(lastMsgFile(), `Received answer from main agent: ${answer}`);
        return {
          content: [{ type: "text", text: `Answer from main agent:\n\n${answer}\n\nContinue implementing the task. When done, commit your changes and report 'completed'.` }],
          details: { answer },
        };
      }
      return {
        content: [{ type: "text", text: "No answer available yet. The main agent may still be reviewing your question. Try again shortly." }],
        details: {},
      };
    },
  });

  pi.registerTool?.({
    name: "rm_write_last_message",
    label: "Write last message",
    description: "Write the last message that summarizes what you did. Call this before reporting 'completed' status.",
    promptSnippet: "Write a summary of what was accomplished for the main pi agent to present to the user.",
    promptGuidelines: [
      "Provide a clear, concise summary of what was implemented.",
      "Include what changes were made, key decisions, and any important details.",
      "Call this BEFORE rm_report_status with status=completed.",
    ],
    parameters: Type.Object({
      message: Type.String({ description: "The summary message to send to the main agent" }),
    }),
    async execute(_toolCallId, params) {
      const { message } = params;
      writeFileStr(lastMsgFile(), message);
      return {
        content: [{ type: "text", text: `Last message written.` }],
        details: { message },
      };
    },
  });

  pi.registerTool?.({
    name: "rm_write_done_report",
    label: "Write done report",
    description: "Write a done report describing the implementation approach. Call this before reporting 'completed' status.",
    promptSnippet: "Write a detailed report of what was accomplished, to be persisted for the main agent.",
    promptGuidelines: [
      "Describe the implementation approach, key changes made, and any challenges.",
      "This is saved for the main agent to read when you report 'completed'.",
      "The user will push and merge manually after you report completed.",
    ],
    parameters: Type.Object({
      report: Type.String({ description: "The implementation report" }),
    }),
    async execute(_toolCallId, params) {
      const { report } = params;
      writeFileStr(doneReportFile(), report);
      return {
        content: [{ type: "text", text: `Done report written.` }],
        details: { report },
      };
    },
  });


}
