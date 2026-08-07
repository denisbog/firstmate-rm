// firstmate-rm worker extension for spawned Pi agents.
//
// Provides:
//   - rm_report_status - report working, blocked, completed status
//   - rm_read_answer - read blocking answer from main agent
//   - rm_create_pr - create a PR for the completed work
//   - rm_write_done_report - write a done report with summary

import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

const rmHome = process.env.RM_HOME || root;
const rmTaskId = process.env.RM_TASK_ID || "unknown";
const rmStateDir = process.env.RM_STATE_OVERRIDE || join(rmHome, "state");
const rmBin = join(rmHome, "bin");
const workersDir = join(rmStateDir, "workers");

// Ensure workers dir exists
mkdirSync(workersDir, { recursive: true });

// File helpers
const statusFile = () => join(workersDir, `${rmTaskId}.status`);
const lastMsgFile = () => join(workersDir, `${rmTaskId}.lastmsg`);
const blockingQuestionFile = () => join(workersDir, `${rmTaskId}.blocking-question`);
const blockingAnswerFile = () => join(workersDir, `${rmTaskId}.blocking-answer`);
const doneReportFile = () => join(workersDir, `${rmTaskId}.done-report`);
const prFile = () => join(workersDir, `${rmTaskId}.pr`);

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

export default function (pi: ExtensionAPI) {
  // Notify the main agent via status
  function notifyMain(status: string, message: string) {
    writeStatus(status, message);
  }

  pi.on?.("session_start", () => {
    mkdirSync(workersDir, { recursive: true });
    writeStatus("working", "Worker pi agent started");
    writeFileStr(lastMsgFile(), "Worker agent started and ready.");
  });

  pi.on?.("session_shutdown", () => {
    // Optionally notify that the worker is shutting down
  });

  // --- Tools ---

  pi.registerTool?.({
    name: "rm_report_status",
    label: "Report status",
    description: "Report your current status back to the main pi agent. Use 'blocked' when you need user input, 'completed' when finished with a PR, or 'working' for progress updates.",
    promptSnippet: "Report your current work status to the main pi agent.",
    promptGuidelines: [
      "Use status 'working' for progress updates (e.g., 'working on X module').",
      "Use status 'blocked' when you need user input or guidance. Also call rm_write_blocking_question to describe what you need.",
      "Use status 'completed' when you have created a PR. Also call rm_write_done_report and rm_write_last_message before reporting completed.",
      "Use status 'failed' if the task cannot be completed.",
    ],
    parameters: Type.Object({
      status: Type.Enum({
        working: "working",
        blocked: "blocked",
        completed: "completed",
        failed: "failed",
      }, { description: "Your current status" }),
      message: Type.String({ description: "A brief message describing your status" }),
    }),
    execute: async (params) => {
      const { status, message } = params;
      notifyMain(status, message);
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
    execute: async (params) => {
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
    execute: async () => {
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
          content: [{ type: "text", text: `Answer from main agent:\n\n${answer}\n\nContinue implementing the task. When done, create a PR and report 'completed'.` }],
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
    execute: async (params) => {
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
    description: "Write a done report describing the implementation approach. Call this before reporting 'completed' status, after creating the PR.",
    promptSnippet: "Write a detailed report of what was accomplished, to be persisted for the main agent.",
    promptGuidelines: [
      "Describe the implementation approach, key changes made, and any challenges.",
      "This is saved for the main agent to read when you report 'completed'.",
      "Call this AFTER creating the PR and BEFORE reporting completed.",
    ],
    parameters: Type.Object({
      report: Type.String({ description: "The implementation report" }),
    }),
    execute: async (params) => {
      const { report } = params;
      writeFileStr(doneReportFile(), report);
      return {
        content: [{ type: "text", text: `Done report written.` }],
        details: { report },
      };
    },
  });

  pi.registerTool?.({
    name: "rm_create_pr",
    label: "Create PR",
    description: "Create a pull request (PR) for the completed changes using gh CLI. Call this before reporting 'completed'.",
    promptSnippet: "Create a pull request with the completed changes.",
    promptGuidelines: [
      "Make sure all changes are committed and pushed to the remote before creating the PR.",
      "Provide a clear title and detailed body describing the changes and implementation approach.",
      "Call rm_write_done_report and rm_write_last_message after creating the PR, then report 'completed'.",
    ],
    parameters: Type.Object({
      projectDir: Type.String({ description: "Absolute path to the git project directory" }),
      title: Type.String({ description: "PR title" }),
      body: Type.String({ description: "PR body with description of changes and implementation approach" }),
    }),
    execute: async (params) => {
      const { projectDir, title, body } = params;
      const cwd = projectDir;

      // Get the current branch
      const branchResult = runBash(`git -C "${cwd}" rev-parse --abbrev-ref HEAD`);
      if (!branchResult.ok) {
        return {
          content: [{ type: "text", text: `Failed to determine current branch: ${branchResult.stderr}` }],
          details: {},
          isError: true,
        };
      }
      const branch = branchResult.stdout;

      // Get default branch
      const defaultResult = runBash(`git -C "${cwd}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || git -C "${cwd}" rev-parse --abbrev-ref HEAD || echo "main"`);
      const baseBranch = defaultResult.stdout || "main";

      // Push the branch
      const pushResult = runBash(`git -C "${cwd}" push origin "${branch}" 2>&1`);
      if (!pushResult.ok) {
        // Branch may already be pushed
      }

      // Create the PR
      const prResult = runBash(`gh pr create --title ${JSON.stringify(title)} --body ${JSON.stringify(body)} --base "${baseBranch}" --head "${branch}"`);
      if (!prResult.ok) {
        return {
          content: [{ type: "text", text: `Failed to create PR: ${prResult.stderr || prResult.stdout}` }],
          details: {},
          isError: true,
        };
      }
      const prUrl = prResult.stdout.trim();

      // Write PR info
      writeFileStr(prFile(), `pr_url=${prUrl}\ndescription=${title}\nts=${Math.floor(Date.now() / 1000)}`);

      // Append to status
      appendStatus(`event=pr_created`, `pr_url=${prUrl}`);

      return {
        content: [{ type: "text", text: `PR created: ${prUrl}` }],
        details: { prUrl, branch, baseBranch },
      };
    },
  });
}
