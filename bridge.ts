#!/usr/bin/env bun

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { constants } from "node:fs";
import { access, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative } from "node:path";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

const HOME = homedir();
const APP_ROOT = join(HOME, ".omp", "quick-agent");
const INSTANCE_ID = `${Date.now()}-${randomUUID().slice(0, 8)}`;
const RUNTIME_ROOT = join(APP_ROOT, "runtime");
const RUNTIME_DIR = join(RUNTIME_ROOT, INSTANCE_ID);
const SESSION_DIR = join(RUNTIME_DIR, "session");
const HANDOFF_DIR = join(APP_ROOT, "handoffs");
const CONFIG_FILE = join(RUNTIME_DIR, "widget-config.yml");
const OWNER_FILE = join(RUNTIME_DIR, "owner.json");
const PRESERVE_FILE = join(RUNTIME_DIR, "preserve");
const SYSTEM_PROMPT =
  "You are a concise desktop chat assistant. Answer directly in Markdown. Aim for about 120 words, using one compact paragraph or at most five bullets. " +
  "Do not add a preamble, repeat the question, or tack on a summary. Exceed the target when correctness requires it or the user explicitly asks for more detail. " +
  "Use web_search when current information is needed. Use read only when the user explicitly asks you to inspect a file; every read requires their approval. " +
  "Do not claim access you do not have.";

interface UiCommand {
  type: "send" | "cancel" | "new" | "cycle_model" | "cycle_thinking" | "handoff" | "permission";
  text?: string;
  id?: string;
  answer?: string | boolean;
}
const UI_COMMAND_TYPES: Record<UiCommand["type"], true> = {
  send: true,
  cancel: true,
  new: true,
  cycle_model: true,
  cycle_thinking: true,
  handoff: true,
  permission: true,
};


type RpcObject = Record<string, unknown>;

interface Launcher {
  command: string[];
  terminalCommand: string[];
  env: NodeJS.ProcessEnv;
}

interface PendingRpc {
  resolve: (frame: RpcObject) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

interface PermissionRequest {
  method: "confirm" | "select";
  toolCallId?: string;
}

interface PendingReadCall {
  toolCallId: string;
  path: string;
  claimed: boolean;
}

interface DisplayMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
}


async function usable(path: string, mode = constants.X_OK): Promise<boolean> {
  try {
    await access(path, mode);
    return true;
  } catch {
    return false;
  }
}

async function resolveLauncher(): Promise<Launcher> {
  const installedO = join(HOME, ".local", "bin", "o");
  const installedSandbox = join(HOME, ".local", "bin", "agent-sandbox");
  const installedPaths = join(HOME, ".config", "agent-sandbox", "paths");
  if ((await usable(installedSandbox)) && (await usable(installedPaths, constants.R_OK))) {
    const command = [installedSandbox, "github:can1357/oh-my-pi@latest", "omp"];
    return {
      command,
      terminalCommand: await usable(installedO) ? [installedO] : command,
      env: {
        ...process.env,
        HERDR_ENV: "1",
        HERDR_AGENT: "omp",
        AGENT_SANDBOX_PATHS: installedPaths,
      },
    };
  }

  const dotfilesRoot = join(HOME, "dotfiles", "agent-sandbox");
  const sourceSandbox = join(dotfilesRoot, ".local", "bin", "agent-sandbox");
  const sourcePaths = join(dotfilesRoot, ".config", "agent-sandbox", "paths");
  if ((await usable(sourceSandbox)) && (await usable(sourcePaths, constants.R_OK))) {
    const command = [sourceSandbox, "github:can1357/oh-my-pi@latest", "omp"];
    return {
      command,
      terminalCommand: await usable(installedO) ? [installedO] : command,
      env: {
        ...process.env,
        HERDR_ENV: "1",
        HERDR_AGENT: "omp",
        AGENT_SANDBOX_PATHS: sourcePaths,
      },
    };
  }

  throw new Error(
    "OMP sandbox launcher is not installed: install ~/.local/bin/agent-sandbox and ~/.config/agent-sandbox/paths (or keep the agent-sandbox dotfiles checkout available)",
  );
}
async function readConfiguredModelCycle(launcher: Launcher): Promise<string[]> {
  const child = spawn(
    launcher.command[0],
    [...launcher.command.slice(1), "config", "get", "cycleOrder", "--json"],
    {
      cwd: RUNTIME_DIR,
      env: launcher.env,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const completed = Promise.withResolvers<number | null>();
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout = `${stdout}${String(chunk)}`.slice(0, 65_536);
  });
  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${String(chunk)}`.slice(-2_048);
  });
  child.once("error", completed.reject);
  child.once("close", completed.resolve);
  const code = await completed.promise;
  if (code !== 0) {
    throw new Error(`Could not read OMP cycleOrder: ${cleanError(stderr.trim() || `exit ${code}`)}`);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new Error("OMP returned invalid JSON for cycleOrder");
  }
  const value = asObject(parsed)?.value;
  if (!Array.isArray(value) || value.length === 0 || !value.every((item) => typeof item === "string" && item.trim())) {
    throw new Error("OMP cycleOrder must contain at least one configured model role");
  }
  return value;
}


function emit(frame: object): void {
  process.stdout.write(`${JSON.stringify(frame)}\n`);
}

function cleanError(value: unknown): string {
  const text = value instanceof Error ? value.message : String(value);
  return text
    .replace(/(authorization|api[-_ ]?key|token|secret|cookie)(\s*[:=]\s*)\S+/gi, "$1$2[redacted]")
    .slice(0, 1200);
}

function asObject(value: unknown): RpcObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as RpcObject)
    : undefined;
}
function processStartTime(stat: string): string | undefined {
  const commandEnd = stat.lastIndexOf(")");
  if (commandEnd < 0) return undefined;
  return stat.slice(commandEnd + 1).trim().split(/\s+/)[19];
}

async function cleanupOrphanedRuntimes(): Promise<void> {
  await mkdir(RUNTIME_ROOT, { recursive: true, mode: 0o700 });
  const entries = await readdir(RUNTIME_ROOT, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === INSTANCE_ID) continue;
    const directory = join(RUNTIME_ROOT, entry.name);
    if (await usable(join(directory, "preserve"), constants.R_OK)) continue;

    let owner: RpcObject | undefined;
    try {
      owner = asObject(JSON.parse(await readFile(join(directory, "owner.json"), "utf8")));
    } catch {
      owner = undefined;
    }
    const pid = typeof owner?.pid === "number" && Number.isInteger(owner.pid) ? owner.pid : undefined;
    const expectedStart = typeof owner?.startTime === "string" ? owner.startTime : undefined;
    if (!pid || !expectedStart) continue;
    let live = false;
    try {
      live = processStartTime(await readFile(`/proc/${pid}/stat`, "utf8")) === expectedStart;
    } catch {
      live = false;
    }
    if (!live) await rm(directory, { recursive: true, force: true });
  }
}


function extractText(message: unknown): string {
  const record = asObject(message);
  if (!record) return "";
  if (typeof record.content === "string") return record.content;
  if (!Array.isArray(record.content)) return "";
  const text: string[] = [];
  for (const rawPart of record.content) {
    const part = asObject(rawPart);
    if (part && (part.type === "text" || part.type === "output_text") && typeof part.text === "string") {
      text.push(part.text);
    }
  }
  return text.join("");
}

function displayRole(message: unknown): "user" | "assistant" | undefined {
  const role = asObject(message)?.role;
  return role === "user" || role === "assistant" ? role : undefined;
}

function modelLabel(model: unknown): string {
  const record = asObject(model);
  const id = typeof record?.id === "string" ? record.id : "";
  const name = typeof record?.name === "string" ? record.name : "";
  return name || id || "sol";
}

function delay(ms: number): Promise<void> {
  const { promise, resolve: resolveDelay } = Promise.withResolvers<void>();
  setTimeout(resolveDelay, ms);
  return promise;
}

function parseUiCommand(value: unknown): UiCommand | undefined {
  const record = asObject(value);
  const type = record?.type;
  if (typeof type !== "string" || !Object.hasOwn(UI_COMMAND_TYPES, type)) return undefined;
  // Object.hasOwn above narrows the untrusted string to this closed command vocabulary.
  const commandType = type as UiCommand["type"];
  return {
    type: commandType,
    ...(typeof record.text === "string" ? { text: record.text } : {}),
    ...(typeof record.id === "string" ? { id: record.id } : {}),
    ...(typeof record.answer === "string" || typeof record.answer === "boolean"
      ? { answer: record.answer }
      : {}),
  };
}

class Bridge {
  private launcher!: Launcher;
  private child?: ChildProcessWithoutNullStreams;
  private ready = false;
  private closing = false;
  private handingOff = false;
  private nextId = 1;
  private model = "sol";
  private thinking = "medium";
  private busy = false;
  private settled = true;
  private sessionFile?: string;
  private stderrTail = "";
  private pending = new Map<string, PendingRpc>();
  private permissions = new Map<string, PermissionRequest>();
  private readCalls: PendingReadCall[] = [];
  private messages = new Map<string, DisplayMessage>();
  private dirtyMessages = new Set<string>();
  private flushTimer?: NodeJS.Timeout;
  private chunk?: { id: string; index: number; count: number; byteLength: number; parts: Buffer[] };
  private readyResolve?: () => void;
  private readyReject?: (error: Error) => void;
  private childClosed?: Promise<number | null>;
  private commandGate = Promise.withResolvers<void>();
  private handoffTask?: Promise<void>;

  async start(): Promise<void> {
    this.launcher = await resolveLauncher();
    await mkdir(RUNTIME_DIR, { recursive: true, mode: 0o700 });
    const ownStartTime = processStartTime(await readFile(`/proc/${process.pid}/stat`, "utf8"));
    await writeFile(OWNER_FILE, JSON.stringify({ pid: process.pid, startTime: ownStartTime }), { mode: 0o600 });
    await cleanupOrphanedRuntimes();
    await mkdir(SESSION_DIR, { recursive: true, mode: 0o700 });
    await mkdir(HANDOFF_DIR, { recursive: true, mode: 0o700 });
    const modelCycle = await readConfiguredModelCycle(this.launcher);
    await writeFile(
      CONFIG_FILE,
      [
        "tools:",
        "  approvalMode: yolo",
        "  approval:",
        "    read: prompt",
        "advisor:",
        "  enabled: false",
        "",
      ].join("\n"),
      { mode: 0o600 },
    );

    const args = [
      ...this.launcher.command,
      "--mode",
      "rpc-ui",
      "--model",
      "sol",
      "--models",
      modelCycle.join(","),
      "--thinking",
      "medium",
      "--tools",
      "read,web_search",
      "--approval-mode",
      "yolo",
      "--config",
      CONFIG_FILE,
      "--no-extensions",
      "--no-skills",
      "--no-rules",
      "--no-lsp",
      "--no-pty",
      "--no-prewalk",
      "--system-prompt",
      SYSTEM_PROMPT,
      "--session-dir",
      SESSION_DIR,
      "--cwd",
      RUNTIME_DIR,
    ];

    this.child = spawn(args[0], args.slice(1), {
      cwd: RUNTIME_DIR,
      env: this.launcher.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const childExit = Promise.withResolvers<number | null>();
    this.childClosed = childExit.promise;
    this.child.once("close", (code) => childExit.resolve(code));
    this.child.once("error", (error) => this.failStartup(error));
    this.child.once("close", (code, signal) => this.onChildClose(code, signal));

    createInterface({ input: this.child.stdout }).on("line", (line) => this.onRpcLine(line));
    this.child.stderr.on("data", (chunk) => {
      this.stderrTail = `${this.stderrTail}${String(chunk)}`.slice(-4096);
    });

    const readyGate = Promise.withResolvers<void>();
    const timer = setTimeout(() => readyGate.reject(new Error("OMP RPC startup timed out")), 20_000);
    this.readyResolve = () => {
      clearTimeout(timer);
      readyGate.resolve();
    };
    this.readyReject = (error) => {
      clearTimeout(timer);
      readyGate.reject(error);
    };
    await readyGate.promise;

    await this.request("negotiate_protocol", { protocolVersion: 2 });
    await this.request("set_event_filter", {
      events: [
        "agent_start",
        "agent_end",
        "message_start",
        "message_update",
        "message_end",
        "model_changed",
        "thinking_level_changed",
        "tool_execution_start",
        "tool_execution_end",
      ],
    });
    await this.refreshState();
    this.ready = true;
    this.emitState();
    this.commandGate.resolve();
  }

  private failStartup(error: Error): void {
    this.readyReject?.(error);
    this.readyReject = undefined;
  }

  private writeRpc(frame: object): void {
    if (!this.child?.stdin.writable || this.child.stdin.destroyed) throw new Error("OMP RPC input is closed");
    this.child.stdin.write(`${JSON.stringify(frame)}\n`);
  }

  private request(type: string, body: object = {}, timeout = 20_000): Promise<RpcObject> {
    const id = `bridge-${this.nextId++}`;
    const requestGate = Promise.withResolvers<RpcObject>();
    const timer = setTimeout(() => {
      this.pending.delete(id);
      requestGate.reject(new Error(`OMP ${type} request timed out`));
    }, timeout);
    this.pending.set(id, { resolve: requestGate.resolve, reject: requestGate.reject, timer });
    try {
      this.writeRpc({ id, type, ...body });
    } catch (error) {
      clearTimeout(timer);
      this.pending.delete(id);
      requestGate.reject(error instanceof Error ? error : new Error(String(error)));
    }
    return requestGate.promise;
  }

  private onRpcLine(line: string): void {
    if (!line.trim()) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      this.reportError("OMP emitted invalid JSON");
      return;
    }
    const frame = asObject(parsed);
    if (!frame) {
      this.reportError("OMP emitted a non-object JSON frame");
      return;
    }
    if (frame.type === "rpc_chunk") {
      this.onChunk(frame);
      return;
    }
    if (this.chunk) {
      this.chunk = undefined;
      this.reportError("OMP interrupted a chunked RPC frame");
    }
    this.onFrame(frame);
  }

  private onChunk(frame: RpcObject): void {
    try {
      const chunkId = frame.chunkId;
      const index = frame.index;
      const count = frame.count;
      const byteLength = frame.byteLength;
      const data = frame.data;
      if (
        typeof chunkId !== "string" ||
        typeof index !== "number" ||
        !Number.isInteger(index) ||
        typeof count !== "number" ||
        !Number.isInteger(count) ||
        typeof byteLength !== "number" ||
        !Number.isInteger(byteLength) ||
        typeof data !== "string" ||
        count < 1 ||
        byteLength < 0 ||
        byteLength > 67_108_864
      ) {
        throw new Error("invalid chunk metadata");
      }
      if (!this.chunk) {
        if (index !== 0) throw new Error("chunk sequence did not start at zero");
        this.chunk = { id: chunkId, index: 0, count, byteLength, parts: [] };
      }
      const active = this.chunk;
      if (
        active.id !== chunkId ||
        active.index !== index ||
        active.count !== count ||
        active.byteLength !== byteLength
      ) {
        throw new Error("invalid chunk sequence");
      }
      active.parts.push(Buffer.from(data, "base64"));
      active.index += 1;
      if (active.index === active.count) {
        const complete = Buffer.concat(active.parts);
        this.chunk = undefined;
        if (complete.byteLength !== active.byteLength) throw new Error("chunk byte length mismatch");
        const json = new TextDecoder("utf-8", { fatal: true }).decode(complete);
        const parsed: unknown = JSON.parse(json);
        const completeFrame = asObject(parsed);
        if (!completeFrame) throw new Error("reassembled frame was not an object");
        this.onFrame(completeFrame);
      }
    } catch (error) {
      this.chunk = undefined;
      this.reportError(`OMP chunk error: ${cleanError(error)}`);
    }
  }

  private onFrame(frame: RpcObject): void {
    if (frame.type === "ready") {
      this.readyResolve?.();
      this.readyResolve = undefined;
      return;
    }

    if (frame.type === "response" && typeof frame.id === "string") {
      const pending = this.pending.get(frame.id);
      if (pending) {
        clearTimeout(pending.timer);
        this.pending.delete(frame.id);
        if (frame.success) {
          pending.resolve(frame);
        } else {
          const error = typeof frame.error === "string" ? frame.error : `${String(frame.command)} failed`;
          pending.reject(new Error(error));
        }
      }
      return;
    }

    if (frame.type === "extension_ui_request") {
      this.onPermission(frame);
      return;
    }

    if (frame.type === "message_start" || frame.type === "message_update" || frame.type === "message_end") {
      this.onMessage(frame);
      return;
    }
    if (frame.type === "tool_execution_start") {
      const toolCallId = typeof frame.toolCallId === "string" ? frame.toolCallId : undefined;
      if (toolCallId && frame.toolName === "read") {
        const args = asObject(frame.args);
        const path = typeof args?.path === "string" && args.path.trim() ? args.path : "(path unavailable)";
        this.readCalls.push({ toolCallId, path, claimed: false });
      }
      return;
    }

    if (frame.type === "tool_execution_end") {
      if (typeof frame.toolCallId === "string") {
        this.readCalls = this.readCalls.filter((call) => call.toolCallId !== frame.toolCallId);
      }
      return;
    }

    if (frame.type === "agent_start") {
      this.busy = true;
      this.settled = false;
      this.emitState();
      return;
    }

    if (frame.type === "agent_end") {
      if (frame.isTerminal !== false) this.busy = false;
      this.emitState();
      return;
    }

    if (frame.type === "prompt_result") {
      if (frame.status === "error") {
        const providerError = asObject(frame.error);
        this.reportError(
          typeof providerError?.message === "string" ? providerError.message : "The model request failed",
        );
      }
      if (frame.sessionSettled === true) {
        this.busy = false;
        this.settled = true;
        this.emitState();
      }
      return;
    }

    if (frame.type === "session_settled") {
      this.busy = false;
      this.settled = true;
      this.emitState();
      return;
    }

    if (frame.type === "model_changed" || frame.type === "thinking_level_changed") {
      void this.refreshState().catch((error) => this.reportError(cleanError(error)));
      return;
    }

    if (frame.type === "extension_error") {
      this.reportError(typeof frame.error === "string" ? frame.error : "An OMP extension failed");
    }
  }

  private onPermission(frame: RpcObject): void {
    const id = typeof frame.id === "string" ? frame.id : undefined;
    if (!id) return;
    const title = typeof frame.title === "string" ? frame.title : "";
    const readCall = title === "Allow tool: read"
      ? this.readCalls.find((call) => !call.claimed)
      : undefined;
    if (readCall) readCall.claimed = true;
    const nativeMessage = typeof frame.message === "string" ? frame.message.trim() : "";
    const message = readCall
      ? [nativeMessage, `Requested path: ${readCall.path}`].filter(Boolean).join("\n")
      : nativeMessage;

    if (frame.method === "confirm") {
      this.permissions.set(id, { method: "confirm", toolCallId: readCall?.toolCallId });
      emit({
        type: "permission",
        id,
        title: title || "Allow file access?",
        message: message || "OMP requested permission.",
        options: [
          { label: "Allow", value: true },
          { label: "Deny", value: false },
        ],
      });
      return;
    }
    if (frame.method === "select" && Array.isArray(frame.options)) {
      this.permissions.set(id, { method: "select", toolCallId: readCall?.toolCallId });
      emit({
        type: "permission",
        id,
        title: title || "Choose an option",
        message: message || (title === "Allow tool: read" ? "Requested path unavailable; deny this request." : ""),
        options: frame.options.map((option: unknown) => ({ label: String(option), value: String(option) })),
      });
      return;
    }
    if (frame.method === "input" || frame.method === "editor") {
      this.writeRpc({ type: "extension_ui_response", id, cancelled: true });
      this.reportError(`Unsupported OMP ${frame.method} request was cancelled`);
    }
  }

  private onMessage(frame: RpcObject): void {
    const id = typeof frame.messageId === "string" ? frame.messageId : undefined;
    if (!id) return;
    const role = displayRole(frame.message);
    const prior = this.messages.get(id);
    const messageRole = role ?? prior?.role;
    if (!messageRole) return;

    const snapshotText = extractText(frame.message);
    const delta = asObject(frame.assistantMessageEvent);
    let text = snapshotText || prior?.text || "";
    if (!snapshotText && delta?.type === "text_delta" && typeof delta.delta === "string") {
      text = `${prior?.text ?? ""}${delta.delta}`;
    }

    this.messages.set(id, { id, role: messageRole, text });
    if (messageRole === "assistant" && !text) return;
    this.dirtyMessages.add(id);
    if (frame.type === "message_end") this.flushMessages();
    else this.scheduleMessageFlush();
  }

  private scheduleMessageFlush(): void {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = undefined;
      this.flushMessages();
    }, 35);
  }

  private flushMessages(): void {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = undefined;
    }
    for (const id of this.dirtyMessages) {
      const message = this.messages.get(id);
      if (message) emit({ type: "message", ...message });
    }
    this.dirtyMessages.clear();
  }

  private emitState(): void {
    emit({ type: "state", model: this.model, thinking: this.thinking, busy: this.busy, ready: this.ready });
  }

  private reportError(message: string): void {
    emit({ type: "error", message });
  }

  private async refreshState(): Promise<RpcObject> {
    const response = await this.request("get_state");
    const state = asObject(response.data) ?? {};
    this.model = modelLabel(state.model);
    if (typeof state.thinkingLevel === "string") this.thinking = state.thinkingLevel;
    this.busy = state.isStreaming === true || state.isCompacting === true;
    this.settled = state.isSettled !== false && state.hasPendingAsyncWork !== true;
    if (typeof state.sessionFile === "string") this.sessionFile = state.sessionFile;
    this.emitState();
    return state;
  }

  releaseStartupFailure(): void {
    this.closing = true;
    this.commandGate.resolve();
  }

  async handle(command: UiCommand): Promise<void> {
    if (this.closing) return;
    if (!this.ready) await this.commandGate.promise;
    if (this.closing) return;
    try {
      switch (command.type) {
        case "send": {
          const text = command.text?.trim();
          if (!text) return;
          const wasBusy = this.busy;
          this.busy = true;
          this.settled = false;
          this.emitState();
          await this.request("prompt", {
            message: text,
            ...(wasBusy ? { streamingBehavior: "followUp" } : {}),
          });
          break;
        }
        case "cancel":
          await this.cancelPermissions();
          await this.request("abort");
          break;
        case "new":
          await this.cancelPermissions();
          await this.request("new_session");
          this.messages.clear();
          this.dirtyMessages.clear();
          this.busy = false;
          this.settled = true;
          this.sessionFile = undefined;
          emit({ type: "reset" });
          await this.refreshState();
          break;
        case "cycle_model":
          await this.request("cycle_model");
          await this.refreshState();
          break;
        case "cycle_thinking":
          await this.request("cycle_thinking_level");
          await this.refreshState();
          break;
        case "permission":
          this.answerPermission(command.id, command.answer);
          break;
        case "handoff":
          this.handoffTask ??= this.handoff().finally(() => {
            this.handoffTask = undefined;
          });
          await this.handoffTask;
          break;
      }
    } catch (error) {
      this.reportError(cleanError(error));
      if (command.type === "handoff") {
        emit({ type: "handoff", ok: false, message: cleanError(error) });
        if (this.child?.stdin.destroyed) {
          setTimeout(() => process.exit(1), 50);
        } else {
          this.closing = false;
        }
      } else if (command.type !== "permission") {
        void this.refreshState().catch(() => undefined);
      }
    }
  }

  private answerPermission(id: string | undefined, answer: string | boolean | undefined): void {
    if (!id) return;
    const pending = this.permissions.get(id);
    if (!pending) return;
    this.permissions.delete(id);
    if (pending.method === "confirm") {
      const confirmed = answer === true || answer === "true";
      this.writeRpc({ type: "extension_ui_response", id, confirmed });
    } else if (answer === false || answer === undefined) {
      this.writeRpc({ type: "extension_ui_response", id, cancelled: true });
    } else {
      this.writeRpc({ type: "extension_ui_response", id, value: String(answer) });
    }
  }

  private async cancelPermissions(): Promise<void> {
    for (const [id] of this.permissions) {
      this.writeRpc({ type: "extension_ui_response", id, cancelled: true });
    }
    this.permissions.clear();
  }

  private async waitUntilSettled(): Promise<RpcObject> {
    await this.cancelPermissions();
    let state = await this.refreshState();
    if (state.isSettled === true && state.hasPendingAsyncWork !== true) return state;
    await this.request("abort").catch(() => undefined);
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      await delay(100);
      state = await this.refreshState();
      if (state.isSettled === true && state.hasPendingAsyncWork !== true) return state;
    }
    throw new Error("OMP did not settle after cancellation; the session was not transferred");
  }

  private async closeRpc(): Promise<void> {
    const child = this.child;
    if (!child || !this.childClosed) return;
    const writerClosed = Promise.withResolvers<void>();
    child.stdin.end(writerClosed.resolve);
    await writerClosed.promise;
    let code = await Promise.race([this.childClosed, delay(20_000).then(() => "timeout" as const)]);
    if (code === "timeout") {
      child.kill("SIGTERM");
      code = await Promise.race([this.childClosed, delay(5_000).then(() => "timeout" as const)]);
    }
    if (code === "timeout") {
      child.kill("SIGKILL");
      code = await this.childClosed;
    }
    if (code !== 0) throw new Error(`OMP exited with status ${code ?? "unknown"} while saving the session`);
  }

  private async handoff(): Promise<void> {
    if (this.handingOff) return;
    this.handingOff = true;
    this.closing = true;
    let preservedFile: string | undefined;
    try {
      const state = await this.waitUntilSettled();
      const sourceFile = typeof state.sessionFile === "string" ? state.sessionFile : this.sessionFile;
      if (!sourceFile) throw new Error("There is no saved conversation to hand off yet");
      const rel = relative(SESSION_DIR, sourceFile);
      if (!rel || rel.startsWith("..") || isAbsolute(rel)) throw new Error("OMP returned a session outside the temporary session directory");
      preservedFile = sourceFile;
      await writeFile(PRESERVE_FILE, sourceFile, { mode: 0o600 });

      this.flushMessages();
      await this.closeRpc();

      const destination = join(HANDOFF_DIR, `${new Date().toISOString().replace(/[:.]/g, "-")}-${basename(INSTANCE_ID)}`);
      await rename(SESSION_DIR, destination);
      const promotedFile = join(destination, rel);
      preservedFile = promotedFile;
      if (!(await usable(promotedFile, constants.R_OK))) throw new Error("The promoted OMP session journal is missing");
      await rm(RUNTIME_DIR, { recursive: true, force: true }).catch(() => undefined);

      const sessionModel = asObject(state.model);
      const provider = typeof sessionModel?.provider === "string" ? sessionModel.provider : undefined;
      const modelId = typeof sessionModel?.id === "string" ? sessionModel.id : undefined;
      const thinking = typeof state.thinkingLevel === "string" ? state.thinkingLevel : this.thinking;
      const terminalCommand = [
        ...this.launcher.terminalCommand,
        "--resume",
        promotedFile,
        ...(provider && modelId ? ["--model", `${provider}/${modelId}`] : []),
        "--thinking",
        thinking,
        "--cwd",
        destination,
      ];
      await this.launchTerminal(terminalCommand, destination, promotedFile);
      emit({ type: "handoff", ok: true, message: `Opened the conversation in OMP (${promotedFile})` });
      setTimeout(() => process.exit(0), 50);
    } catch (error) {
      const message = cleanError(error);
      if (preservedFile && !message.includes(preservedFile)) {
        throw new Error(`${message}; session preserved at ${preservedFile}`);
      }
      throw error;
    } finally {
      this.handingOff = false;
    }
  }

  private async launchTerminal(command: string[], cwd: string, promotedFile: string): Promise<void> {
    const xdgTerminal = "/usr/bin/xdg-terminal-exec";
    const ghostty = "/usr/bin/ghostty";
    const resumeCommand = command.map((part) => `'${part.replaceAll("'", "'\"'\"'")}'`).join(" ");
    let executable: string;
    let args: string[];
    if (await usable(xdgTerminal)) {
      executable = xdgTerminal;
      args = command;
    } else if (await usable(ghostty)) {
      executable = ghostty;
      args = ["--working-directory", cwd, "-e", ...command];
    } else {
      throw new Error(
        `No supported terminal launcher was found; session preserved at ${promotedFile}. Resume it with ${resumeCommand}`,
      );
    }

    const terminalStarted = Promise.withResolvers<void>();
    const terminalExited = Promise.withResolvers<{ code: number | null; signal: NodeJS.Signals | null }>();
    const terminal = spawn(executable, args, {
      cwd,
      env: this.launcher.env,
      detached: true,
      stdio: "ignore",
    });
    terminal.once("error", terminalStarted.reject);
    terminal.once("spawn", terminalStarted.resolve);
    terminal.once("exit", (code, signal) => terminalExited.resolve({ code, signal }));
    await terminalStarted.promise;

    const immediateExit = await Promise.race([
      terminalExited.promise,
      delay(750).then(() => undefined),
    ]);
    if (immediateExit && immediateExit.code !== 0) {
      const status = immediateExit.code ?? immediateExit.signal ?? "unknown";
      throw new Error(
        `Terminal launcher exited with status ${status}; session preserved at ${promotedFile}. Resume it with ${resumeCommand}`,
      );
    }
    if (!immediateExit) terminal.unref();
  }

  private onChildClose(code: number | null, signal: NodeJS.Signals | null): void {
    this.readyReject?.(new Error(`OMP exited during startup (${code ?? signal ?? "unknown"})`));
    this.readyReject = undefined;
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(new Error(`OMP exited before completing request ${id}`));
    }
    this.pending.clear();
    if (!this.closing && !this.handingOff) {
      this.ready = false;
      this.emitState();
      const detail = this.stderrTail.trim().split("\n").at(-1);
      this.reportError(`OMP stopped unexpectedly${detail ? `: ${cleanError(detail)}` : ""}`);
    }
  }

  async shutdown(): Promise<void> {
    const activeHandoff = this.handoffTask;
    if (activeHandoff) {
      await activeHandoff.catch(() => undefined);
      if (this.child?.stdin.destroyed) return;
    }
    this.closing = true;
    try {
      await this.cancelPermissions().catch(() => undefined);
      if (this.child && !this.child.stdin.destroyed) await this.closeRpc().catch(() => undefined);
    } finally {
      await rm(RUNTIME_DIR, { recursive: true, force: true }).catch(() => undefined);
    }
  }
}

const bridge = new Bridge();
let shutdownStarted = false;

async function shutdown(): Promise<void> {
  if (shutdownStarted) return;
  shutdownStarted = true;
  await bridge.shutdown();
  process.exit(0);
}

process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
process.on("SIGHUP", () => void shutdown());
process.on("uncaughtException", (error) => {
  emit({ type: "error", message: cleanError(error) });
  void shutdown();
});
process.on("unhandledRejection", (error) => {
  emit({ type: "error", message: cleanError(error) });
});

createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    emit({ type: "error", message: "Invalid UI command JSON" });
    return;
  }
  const command = parseUiCommand(parsed);
  if (!command) {
    emit({ type: "error", message: "Unknown or malformed UI command" });
    return;
  }
  void bridge.handle(command);
}).once("close", () => void shutdown());

emit({ type: "state", model: "sol", thinking: "medium", busy: false, ready: false });
bridge.start().catch(async (error) => {
  bridge.releaseStartupFailure();
  emit({ type: "error", message: cleanError(error) });
  await bridge.shutdown();
  process.exit(1);
});
