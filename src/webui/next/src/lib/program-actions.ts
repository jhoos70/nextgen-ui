import type { ActionInput, LogicAction, ProgramTargets, TargetDatapoint, TargetVariable } from "./api";
import { delaySeconds, trimNumber, VT_BINARY, VT_FLOAT, VT_INTEGER, VT_OBJECT, VT_STRING, VT_SYSVAR } from "./program-logic";

/** What an action row edits. */
export type ActionKind = "device" | "sysvar" | "script";
export type DelayUnit = "s" | "min" | "h";

export interface ActionDraft {
  key: string;
  kind: ActionKind;
  targetId: string; // a datapoint or a variable
  value: string; // as shown: a percentage as 0..100, a list as its index, a logic value as "true" / "false"
  script: string;
  delayOn: boolean;
  delayAmount: string;
  delayUnit: DelayUnit;
}

/** The part of a target that decides what can be typed. */
export interface TargetMeta {
  valueType: number;
  subType: number;
  min: string;
  max: string;
  unit: string;
  valueList: string;
}

export type InputKind = "trigger" | "bool" | "enum" | "integer" | "number" | "string" | "unsupported";

export const ACTIONS_MAX = 50;
export const SCRIPT_MAX = 32000;
export const DELAY_MAX = 359999;
const SUB_BUTTON = 28;
const SUB_LIST = 29;

/** How a value of a target is entered. */
export function inputKind(m: TargetMeta): InputKind {
  switch (m.valueType) {
    case 2:
      return m.subType === SUB_BUTTON ? "trigger" : "bool";
    case 16:
      return m.subType === SUB_LIST ? "enum" : "integer";
    case 4:
    case 5:
    case 6:
      return "number";
    case 20:
      return "string";
    default:
      return "unsupported";
  }
}

export const isPercent = (m: TargetMeta): boolean => m.unit === "100%";

/** The range a number can have as it is typed (a percentage as 0..100), or null when the target has none. */
export function numberRange(m: TargetMeta): { min: number; max: number } | null {
  const min = Number(m.min);
  const max = Number(m.max);
  if (m.min === "" || m.max === "" || !Number.isFinite(min) || !Number.isFinite(max)) return null;
  return isPercent(m) ? { min: min * 100, max: max * 100 } : { min, max };
}

/** "" when the value fits the target, else why not: "value" (does not fit its type), "range" (outside the limits). */
export function valueIssue(m: TargetMeta, value: string): "" | "value" | "range" {
  switch (inputKind(m)) {
    case "trigger":
      return value === "true" ? "" : "value";
    case "bool":
      return value === "true" || value === "false" ? "" : "value";
    case "enum": {
      const n = m.valueList.split(";").length;
      return /^[0-9]{1,4}$/.test(value) && Number(value) < n ? "" : "value";
    }
    case "integer": {
      if (!/^-?[0-9]{1,9}$/.test(value)) return "value";
      const r = numberRange(m);
      return r && (Number(value) < r.min || Number(value) > r.max) ? "range" : "";
    }
    case "number": {
      if (!/^-?[0-9]{1,15}(\.[0-9]{1,6})?$/.test(value)) return "value";
      const r = numberRange(m);
      return r && (Number(value) < r.min - 1e-9 || Number(value) > r.max + 1e-9) ? "range" : "";
    }
    case "string":
      return value.length <= 1000 && !/[\u0000-\u001f\u007f]/.test(value) ? "" : "value";
    default:
      return "value";
  }
}

/** The value a new action starts with for a target: something that is valid. */
export function defaultValue(m: TargetMeta): string {
  switch (inputKind(m)) {
    case "trigger":
    case "bool":
      return "true";
    case "enum":
    case "integer": {
      const r = numberRange(m);
      return r && (r.min > 0 || r.max < 0) ? String(Math.ceil(r.min)) : "0";
    }
    case "number": {
      const r = numberRange(m);
      return r && (r.min > 0 || r.max < 0) ? String(r.min) : "0";
    }
    default:
      return "";
  }
}

export const metaOfDatapoint = (d: TargetDatapoint): TargetMeta => d;
export const metaOfVariable = (v: TargetVariable): TargetMeta => v;

export function findTarget(targets: ProgramTargets, kind: ActionKind, id: string): TargetMeta | null {
  if (kind === "device") return targets.datapoints.find((d) => d.id === id) ?? null;
  if (kind === "sysvar") return targets.variables.find((v) => v.id === id) ?? null;
  return null;
}

/** The delay as the amount and the biggest unit it is a whole number of. */
export function splitDelay(seconds: number): { amount: string; unit: DelayUnit } {
  if (seconds >= 3600 && seconds % 3600 === 0) return { amount: String(seconds / 3600), unit: "h" };
  if (seconds >= 60 && seconds % 60 === 0) return { amount: String(seconds / 60), unit: "min" };
  return { amount: String(seconds), unit: "s" };
}

export function delayInSeconds(d: ActionDraft): number {
  if (!d.delayOn) return 0;
  const n = Number(d.delayAmount);
  return n * (d.delayUnit === "h" ? 3600 : d.delayUnit === "min" ? 60 : 1);
}

export const delayIssue = (d: ActionDraft): boolean => d.delayOn && (!/^[0-9]{1,6}$/.test(d.delayAmount) || delayInSeconds(d) > DELAY_MAX);

let counter = 0;
export const newKey = (): string => `a${++counter}`;

/** An action of the program as an editable row, or null when this editor cannot show it (it then stays in the classic editor). */
export function draftFromAction(a: LogicAction, targets: ProgramTargets): ActionDraft | null {
  const base = { key: newKey(), script: "", delayOn: false, delayAmount: "1", delayUnit: "s" as DelayUnit };
  if (a.delayType === 28 && a.delay) {
    const { amount, unit } = splitDelay(delaySeconds(a.delay));
    base.delayOn = true;
    base.delayAmount = amount;
    base.delayUnit = unit;
  }
  if (a.param === VT_STRING) return { ...base, kind: "script", targetId: "", value: "", script: a.value };
  if (a.param !== VT_OBJECT && a.param !== VT_SYSVAR) return null;
  const kind: ActionKind = a.param === VT_OBJECT ? "device" : "sysvar";
  const meta = findTarget(targets, kind, a.datapointId);
  if (!meta || inputKind(meta) === "unsupported") return null;
  let value = a.value;
  if (a.valueType === VT_BINARY) value = a.value === "true" || a.value === "1" ? "true" : "false";
  else if (a.valueType === VT_FLOAT || a.valueType === 5 || a.valueType === 6) value = trimNumber(isPercent(meta) ? String(Math.round(Number(a.value) * 10000) / 100) : a.value);
  else if (a.valueType === VT_INTEGER) value = trimNumber(a.value);
  return { ...base, kind, targetId: a.datapointId, value };
}

/** A new action row of a kind. */
export function newDraft(kind: ActionKind): ActionDraft {
  return { key: newKey(), kind, targetId: "", value: "", script: "", delayOn: false, delayAmount: "1", delayUnit: "s" };
}

/** Why a row cannot be saved, or "" ("target", "value", "range", "script", "delay"). */
export function draftIssue(d: ActionDraft, targets: ProgramTargets): "" | "target" | "value" | "range" | "script" | "delay" {
  if (delayIssue(d)) return "delay";
  if (d.kind === "script") return d.script.length > SCRIPT_MAX || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(d.script) ? "script" : "";
  const meta = findTarget(targets, d.kind, d.targetId);
  if (!meta) return "target";
  return valueIssue(meta, d.value);
}

/** The request body of a row. */
export function toActionInput(d: ActionDraft): ActionInput {
  const delaySeconds = delayInSeconds(d);
  const delay = delaySeconds > 0 ? { delaySeconds } : {};
  if (d.kind === "script") return { kind: "script", script: d.script, ...delay };
  if (d.kind === "device") return { kind: "device", datapointId: d.targetId, value: d.value, ...delay };
  return { kind: "sysvar", variableId: d.targetId, value: d.value, ...delay };
}

/** Nothing the user changed: the rows say the same as the program's actions (to leave Save off). */
export function sameActions(a: ActionInput[], b: ActionInput[]): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}
