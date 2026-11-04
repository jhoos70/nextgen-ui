import type { ConditionInput, ConditionsInput, LogicCondition, LogicRule, ProgramTargets } from "./api";
import { findTarget, inputKind, isPercent, newKey, type InputKind, type TargetMeta } from "./program-actions";
import { trimNumber } from "./program-logic";

/** What a condition row edits. A time control cannot be made here: an existing one is kept, may change how it triggers, or goes. */
export type CondKind = "device" | "sysvar" | "time";
export type Joiner = "and" | "or";

export interface CondDraft {
  key: string;
  from?: number; // its position in the program as it is now (a kept condition); a new one has none
  kind: CondKind;
  targetId: string;
  test: number;
  value: string; // as typed: a percentage as 0..100, a list as its index
  value2: string; // the upper end of "between"
  trigger: number; // 4 on change, 13 on update, 15 check only, 1 a button
  original?: LogicCondition; // a time control keeps what it was, to show it
}

export interface GroupDraft {
  key: string;
  from?: number;
  op: Joiner; // how the conditions of the group are joined
  conds: CondDraft[];
}

export interface ConditionsDraft {
  op: Joiner; // how the groups are joined
  groups: GroupDraft[];
}

export const GROUPS_MAX = 20;
export const CONDS_MAX = 30;
export const TESTS_FOR_NUMBERS = [5, 12, 8, 9, 10, 11, 6] as const; // = ≠ > ≥ < ≤ between
export const TRIGGERS = [4, 13, 15] as const;
export const TIME_TRIGGERS = [13, 15] as const;
const BUTTON = 1;

/** Which tests a target offers: "is" for a logic value, a list or a button, comparisons for a number, nothing for a text. */
export function testsFor(m: TargetMeta): readonly number[] {
  switch (inputKind(m)) {
    case "trigger":
    case "bool":
    case "enum":
      return [1];
    case "integer":
    case "number":
      return TESTS_FOR_NUMBERS;
    default:
      return [];
  }
}

/** A text variable, a special value and the like are not edited here. */
export const isEditable = (m: TargetMeta): boolean => inputKind(m) !== "string" && inputKind(m) !== "unsupported";

/** Whether the target has a "how it triggers" choice: a button does not. */
export const hasTrigger = (m: TargetMeta): boolean => inputKind(m) !== "trigger";

/** "" when the value fits, else "value". The server does not check a number against the range of the datapoint, a comparison may lie outside it. */
export function conditionValueIssue(m: TargetMeta, test: number, value: string, value2: string): "" | "value" | "value2" | "test" {
  const kind: InputKind = inputKind(m);
  if (!testsFor(m).includes(test)) return "test";
  switch (kind) {
    case "trigger":
      return value === "true" ? "" : "value";
    case "bool":
      return value === "true" || value === "false" ? "" : "value";
    case "enum":
      return /^[0-9]{1,4}$/.test(value) && Number(value) < m.valueList.split(";").length ? "" : "value";
    case "integer":
    case "number": {
      const re = kind === "integer" ? /^-?[0-9]{1,9}$/ : /^-?[0-9]{1,15}(\.[0-9]{1,6})?$/;
      if (!re.test(value)) return "value";
      if (test === 6) {
        if (!re.test(value2)) return "value2";
        if (Number(value) > Number(value2)) return "value2";
      }
      return "";
    }
    default:
      return "value";
  }
}

/** The value a new condition starts with for a target and a test. */
export function defaultConditionValue(m: TargetMeta): string {
  switch (inputKind(m)) {
    case "trigger":
    case "bool":
      return "true";
    default:
      return "0";
  }
}

/** The trigger a new condition starts with. */
export const defaultTrigger = (m: TargetMeta): number => (hasTrigger(m) ? 4 : BUTTON);

function displayNumber(raw: string, m: TargetMeta): string {
  if (isPercent(m)) return trimNumber(String(Math.round(Number(raw) * 10000) / 100));
  return trimNumber(raw);
}

/** A condition of the program as an editable row, or null when this editor cannot show it (then the rule stays in the classic editor). */
export function draftFromCondition(c: LogicCondition, index: number, targets: ProgramTargets): CondDraft | null {
  const base = { key: newKey(), from: index, value2: "", original: undefined as LogicCondition | undefined };
  if (c.kind === "time") return { ...base, kind: "time", targetId: "", test: 3, value: "", trigger: c.trigger === 15 ? 15 : 13, original: c };
  if (c.kind !== "device" && c.kind !== "sysvar") return null;
  const meta = findTarget(targets, c.kind, c.objectId);
  if (!meta || !isEditable(meta)) return null;
  if (!testsFor(meta).includes(c.test)) return null;
  const kind = inputKind(meta);
  let value = c.right;
  let value2 = "";
  if (kind === "bool" || kind === "trigger") value = c.right === "true" || c.right === "1" ? "true" : "false";
  else if (kind === "integer" || kind === "number") {
    value = displayNumber(c.right, meta);
    if (c.test === 6) value2 = displayNumber(c.right2, meta);
  } else value = trimNumber(c.right);
  const trigger = kind === "trigger" ? BUTTON : (TRIGGERS as readonly number[]).includes(c.trigger) ? c.trigger : 4;
  return { ...base, kind: c.kind, targetId: c.objectId, test: c.test, value, value2, trigger };
}

/** The rows of the conditions of a rule, or null when one of them cannot be shown. */
export function draftFromRule(rule: LogicRule, targets: ProgramTargets): ConditionsDraft | null {
  const groups: GroupDraft[] = [];
  for (let gi = 0; gi < rule.groups.length; gi++) {
    const g = rule.groups[gi];
    const conds: CondDraft[] = [];
    for (let ci = 0; ci < g.conditions.length; ci++) {
      const d = draftFromCondition(g.conditions[ci], ci, targets);
      if (!d) return null;
      conds.push(d);
    }
    // the joiner inside a group is the one of the conditions after the first (the first one's is only a preset)
    const op: Joiner = g.conditions.length > 1 ? g.conditions[1].op : "and";
    groups.push({ key: newKey(), from: gi, op, conds });
  }
  // between the groups: the one of the first group (the classic editor keeps one for the whole rule)
  return { op: rule.groups.length > 1 ? rule.groups[0].op : "and", groups };
}

export function newCondition(kind: "device" | "sysvar"): CondDraft {
  return { key: newKey(), kind, targetId: "", test: 1, value: "", value2: "", trigger: 4 };
}

export function newGroup(): GroupDraft {
  return { key: newKey(), op: "and", conds: [newCondition("device")] };
}

export type CondIssue = "" | "target" | "value" | "value2" | "test";

export function conditionIssue(d: CondDraft, targets: ProgramTargets): CondIssue {
  if (d.kind === "time") return "";
  const meta = findTarget(targets, d.kind, d.targetId);
  if (!meta || !isEditable(meta)) return "target";
  return conditionValueIssue(meta, d.test, d.value, d.value2);
}

/** Whether a row is a time control (it cannot be made, only kept or removed). */
export const isTime = (d: CondDraft): boolean => d.kind === "time";

/** Does removing these rows destroy a timer? (a time control, or a group that holds one) */
export const destroysTimer = (conds: CondDraft[]): boolean => conds.some((c) => c.kind === "time");

export function toConditionInput(d: CondDraft): ConditionInput {
  const from = d.from === undefined ? {} : { from: d.from };
  if (d.kind === "time") return { from: d.from ?? 0, kind: "time", trigger: d.trigger };
  const value2 = d.test === 6 ? { value2: d.value2 } : {};
  const common = { ...from, test: d.test, value: d.value, ...value2, trigger: d.trigger };
  return d.kind === "device" ? { kind: "device", datapointId: d.targetId, ...common } : { kind: "sysvar", variableId: d.targetId, ...common };
}

export function toConditionsInput(d: ConditionsDraft): ConditionsInput {
  return { op: d.op, groups: d.groups.map((g) => ({ ...(g.from === undefined ? {} : { from: g.from }), op: g.op, conditions: g.conds.map(toConditionInput) })) };
}

/** Nothing the user changed: the request would say what the program already says. */
export const sameConditions = (a: ConditionsInput, b: ConditionsInput): boolean => JSON.stringify(a) === JSON.stringify(b);
