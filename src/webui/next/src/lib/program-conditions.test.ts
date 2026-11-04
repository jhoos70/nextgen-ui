import { describe, expect, it } from "vitest";
import type { LogicCondition, LogicRule, ProgramTargets } from "./api";
import { conditionIssue, conditionValueIssue, defaultTrigger, destroysTimer, draftFromRule, hasTrigger, isEditable, newCondition, newGroup, sameConditions, testsFor, toConditionsInput, type CondDraft } from "./program-conditions";

const meta = (o: Partial<Parameters<typeof testsFor>[0]>) => ({ valueType: 4, subType: 0, min: "", max: "", unit: "", valueList: "", ...o });
const targets: ProgramTargets = {
  datapoints: [
    { id: "3937", param: "ACTUAL_TEMPERATURE", channel: "Kinderzimmer:1", device: "K", valueType: 4, subType: 0, min: "-40.0", max: "80.0", unit: "°C", valueList: "" },
    { id: "3941", param: "CONTROL_MODE", channel: "Kinderzimmer:1", device: "K", valueType: 16, subType: 29, min: "0", max: "3", unit: "", valueList: "AUTO-MODE;MANU-MODE;PARTY-MODE" },
    { id: "1013", param: "LEVEL", channel: "Rollo:1", device: "R", valueType: 6, subType: 0, min: "0.0", max: "1.0", unit: "100%", valueList: "" },
    { id: "9", param: "PRESS_SHORT", channel: "Taster:1", device: "T", valueType: 2, subType: 28, min: "", max: "", unit: "", valueList: "" },
  ],
  variables: [
    { id: "950", name: "Anwesenheit", valueType: 2, subType: 2, min: "", max: "", unit: "", valueList: "", valueName0: "nicht anwesend", valueName1: "anwesend" },
    { id: "12", name: "Text", valueType: 20, subType: 11, min: "", max: "", unit: "", valueList: "", valueName0: "", valueName1: "" },
  ],
};
const cond = (o: Partial<LogicCondition>): LogicCondition => ({
  op: "and", kind: "device", objectId: "3937", objectName: "X.ACTUAL_TEMPERATURE", channelId: "1", channelName: "Kinderzimmer:1", valueType: "4/0", unit: "°C", valueName0: "", valueName1: "", valueList: "",
  test: 8, trigger: 13, rightType: 4, right: "20.000000", right2Type: 4, right2: "0.000000", ...o,
});
const time = (o: Partial<LogicCondition> = {}): LogicCondition => cond({ kind: "time", objectId: "", test: 3, trigger: 13, rightType: 18, right: "555", time: { timerType: 9, sunOffset: 0, seconds: 0, duration: 0, time: "1970-01-01 01:00:00", begin: "2025-10-04 00:00:00", end: "1970-01-01 01:00:00", repetitions: 0 }, ...o });

describe("tests and values", () => {
  it("offers 'is' for a logic value, a list and a button, comparisons for a number, nothing for a text", () => {
    expect(testsFor(meta({ valueType: 2 }))).toEqual([1]);
    expect(testsFor(meta({ valueType: 2, subType: 28 }))).toEqual([1]);
    expect(testsFor(meta({ valueType: 16, subType: 29 }))).toEqual([1]);
    expect(testsFor(meta({ valueType: 6 }))).toEqual([5, 12, 8, 9, 10, 11, 6]);
    expect(testsFor(meta({ valueType: 20 }))).toEqual([]);
    expect([isEditable(meta({ valueType: 20 })), isEditable(meta({ valueType: 99 })), isEditable(meta({}))]).toEqual([false, false, true]);
  });
  it("a button has no trigger choice", () => {
    expect([hasTrigger(meta({ valueType: 2, subType: 28 })), hasTrigger(meta({})), defaultTrigger(meta({ valueType: 2, subType: 28 })), defaultTrigger(meta({}))]).toEqual([false, true, 1, 4]);
  });
  it("checks a value against its type and the test, not against the range of the datapoint", () => {
    const temp = meta({ min: "-40", max: "80" });
    expect([conditionValueIssue(temp, 8, "20.5", ""), conditionValueIssue(temp, 8, "999", ""), conditionValueIssue(temp, 8, "x", ""), conditionValueIssue(temp, 1, "20", "")]).toEqual(["", "", "value", "test"]);
    expect([conditionValueIssue(temp, 6, "5", "9"), conditionValueIssue(temp, 6, "9", "5"), conditionValueIssue(temp, 6, "5", "")]).toEqual(["", "value2", "value2"]);
    expect([conditionValueIssue(meta({ valueType: 2 }), 1, "false", ""), conditionValueIssue(meta({ valueType: 2 }), 1, "1", ""), conditionValueIssue(meta({ valueType: 2, subType: 28 }), 1, "false", "")]).toEqual(["", "value", "value"]);
    const list = meta({ valueType: 16, subType: 29, valueList: "A;B;C" });
    expect([conditionValueIssue(list, 1, "2", ""), conditionValueIssue(list, 1, "3", ""), conditionValueIssue(list, 8, "1", "")]).toEqual(["", "value", "test"]);
  });
});

describe("draftFromRule", () => {
  const rule: LogicRule = {
    hasCondition: true,
    stopDelays: true,
    actions: [],
    groups: [
      { op: "or", conditions: [cond({ op: "and", test: 1, objectId: "3941", valueType: "16/29", valueList: "AUTO-MODE;MANU-MODE;PARTY-MODE", right: "1", rightType: 16, trigger: 4 }), cond({ op: "and", test: 9, right: "19.500000" }), time({ op: "and" })] },
      { op: "or", conditions: [cond({ kind: "sysvar", objectId: "950", test: 1, right: "true", rightType: 2, trigger: 4, op: "and" })] },
    ],
  };
  it("makes rows with the joiners of the program and the positions of its conditions", () => {
    const d = draftFromRule(rule, targets)!;
    expect([d.op, d.groups.map((g) => g.op), d.groups.map((g) => g.from), d.groups[0].conds.map((c) => [c.kind, c.from])]).toEqual(["or", ["and", "and"], [0, 1], [["device", 0], ["device", 1], ["time", 2]]]);
    expect([d.groups[0].conds[0].value, d.groups[0].conds[1].value, d.groups[1].conds[0].value]).toEqual(["1", "19.5", "true"]);
    expect(d.groups[0].conds[2].original?.kind).toBe("time");
  });
  it("sends what the program already says when nothing changed, with every position", () => {
    const d = draftFromRule(rule, targets)!;
    expect(toConditionsInput(d)).toEqual({
      op: "or",
      groups: [
        { from: 0, op: "and", conditions: [{ from: 0, kind: "device", datapointId: "3941", test: 1, value: "1", trigger: 4 }, { from: 1, kind: "device", datapointId: "3937", test: 9, value: "19.5", trigger: 13 }, { from: 2, kind: "time", trigger: 13 }] },
        { from: 1, op: "and", conditions: [{ from: 0, kind: "sysvar", variableId: "950", test: 1, value: "true", trigger: 4 }] },
      ],
    });
  });
  it("shows a scaling value as a percentage, and 'between' with both ends", () => {
    const r: LogicRule = { ...rule, groups: [{ op: "and", conditions: [cond({ objectId: "1013", valueType: "6/0", unit: "100%", test: 6, right: "0.250000", right2: "0.750000" })] }] };
    const d = draftFromRule(r, targets)!;
    expect([d.groups[0].conds[0].value, d.groups[0].conds[0].value2]).toEqual(["25", "75"]);
    expect(toConditionsInput(d).groups[0].conditions[0]).toEqual({ from: 0, kind: "device", datapointId: "1013", test: 6, value: "25", value2: "75", trigger: 13 });
  });
  it("keeps a button's trigger at 1", () => {
    const r: LogicRule = { ...rule, groups: [{ op: "and", conditions: [cond({ objectId: "9", valueType: "2/28", test: 1, right: "true", rightType: 2, trigger: 1 })] }] };
    expect(draftFromRule(r, targets)!.groups[0].conds[0].trigger).toBe(1);
  });
  it("gives up on a rule with something it cannot show: a text variable, an unknown target, an unknown test", () => {
    const one = (c: LogicCondition): LogicRule => ({ ...rule, groups: [{ op: "and", conditions: [c] }] });
    expect(draftFromRule(one(cond({ kind: "sysvar", objectId: "12", test: 1, right: "x" })), targets)).toBeNull();
    expect(draftFromRule(one(cond({ objectId: "424242" })), targets)).toBeNull();
    expect(draftFromRule(one(cond({ test: 99 })), targets)).toBeNull();
    expect(draftFromRule(one(cond({ kind: "unknown" })), targets)).toBeNull();
  });
});

describe("new rows and issues", () => {
  it("a new condition and a new group start without a position", () => {
    const g = newGroup();
    expect([g.from, g.conds[0].from, g.conds[0].kind, newCondition("sysvar").kind]).toEqual([undefined, undefined, "device", "sysvar"]);
    expect(toConditionsInput({ op: "and", groups: [g] }).groups[0]).toEqual({ op: "and", conditions: [{ kind: "device", datapointId: "", test: 1, value: "", trigger: 4 }] });
  });
  it("tells what is wrong with a row", () => {
    const ok: CondDraft = { ...newCondition("device"), targetId: "3937", test: 8, value: "20" };
    expect(conditionIssue(ok, targets)).toBe("");
    expect(conditionIssue({ ...ok, targetId: "" }, targets)).toBe("target");
    expect(conditionIssue({ ...ok, value: "x" }, targets)).toBe("value");
    expect(conditionIssue({ ...ok, test: 6, value2: "5" }, targets)).toBe("value2");
    expect(conditionIssue({ ...newCondition("sysvar"), targetId: "12", value: "x" }, targets)).toBe("target");
    expect(conditionIssue({ ...ok, kind: "time", from: 2, trigger: 13 }, targets)).toBe("");
  });
  it("knows that removing a time control (or its group) destroys the timer", () => {
    const t: CondDraft = { ...newCondition("device"), kind: "time", from: 2 };
    expect([destroysTimer([t]), destroysTimer([newCondition("device")])]).toEqual([true, false]);
    expect(sameConditions({ op: "and", groups: [] }, { op: "and", groups: [] })).toBe(true);
  });
});
