import { describe, expect, it } from "vitest";
import type { LogicAction, ProgramTargets } from "./api";
import { defaultValue, delayInSeconds, draftFromAction, draftIssue, inputKind, newDraft, numberRange, sameActions, splitDelay, toActionInput, valueIssue, type ActionDraft } from "./program-actions";

const meta = (o: Partial<Parameters<typeof inputKind>[0]>) => ({ valueType: 4, subType: 0, min: "", max: "", unit: "", valueList: "", ...o });
const targets: ProgramTargets = {
  datapoints: [
    { id: "3943", param: "MANU_MODE", channel: "Kinderzimmer:1", device: "K", valueType: 4, subType: 0, min: "5.0", max: "30.0", unit: "°C", valueList: "" },
    { id: "3939", param: "BOOST_MODE", channel: "Kinderzimmer:1", device: "K", valueType: 2, subType: 0, min: "", max: "", unit: "", valueList: "" },
    { id: "1013", param: "LEVEL", channel: "Rollo:1", device: "R", valueType: 6, subType: 0, min: "0.0", max: "1.0", unit: "100%", valueList: "" },
    { id: "3941", param: "CONTROL_MODE", channel: "Kinderzimmer:1", device: "K", valueType: 16, subType: 29, min: "0", max: "3", unit: "", valueList: "AUTO-MODE;MANU-MODE;PARTY-MODE" },
    { id: "9", param: "PRESS_SHORT", channel: "Taster:1", device: "T", valueType: 2, subType: 28, min: "", max: "", unit: "", valueList: "" },
  ],
  variables: [{ id: "12202", name: "Rollladenautomatik", valueType: 16, subType: 0, min: "0", max: "65000", unit: "", valueList: "", valueName0: "", valueName1: "" }],
};
const action = (o: Partial<LogicAction>): LogicAction => ({ param: 18, valueType: 4, delayType: 0, value: "21.000000", delay: "", channelId: "1", datapointId: "3943", channelName: "Kinderzimmer:1", datapointName: "X.MANU_MODE", datapointType: "4/0", datapointUnit: "°C", ...o });

describe("inputKind and valueIssue", () => {
  it("knows how a value is entered", () => {
    expect([inputKind(meta({ valueType: 2 })), inputKind(meta({ valueType: 2, subType: 28 })), inputKind(meta({ valueType: 16, subType: 29 })), inputKind(meta({ valueType: 16 })), inputKind(meta({ valueType: 6 })), inputKind(meta({ valueType: 20 })), inputKind(meta({ valueType: 99 }))]).toEqual(["bool", "trigger", "enum", "integer", "number", "string", "unsupported"]);
  });
  it("checks a number against the range, a percentage as 0 to 100", () => {
    const temp = meta({ min: "5.0", max: "30.0" });
    expect([valueIssue(temp, "19.5"), valueIssue(temp, "5"), valueIssue(temp, "30"), valueIssue(temp, "31"), valueIssue(temp, "4.9"), valueIssue(temp, "warm"), valueIssue(temp, "")]).toEqual(["", "", "", "range", "range", "value", "value"]);
    const level = meta({ valueType: 6, min: "0.0", max: "1.0", unit: "100%" });
    expect(numberRange(level)).toEqual({ min: 0, max: 100 });
    expect([valueIssue(level, "50"), valueIssue(level, "100"), valueIssue(level, "101")]).toEqual(["", "", "range"]);
  });
  it("checks a list index, a logic value, a button and a text", () => {
    const list = meta({ valueType: 16, subType: 29, valueList: "A;B;C" });
    expect([valueIssue(list, "2"), valueIssue(list, "3"), valueIssue(list, "x")]).toEqual(["", "value", "value"]);
    expect([valueIssue(meta({ valueType: 2 }), "false"), valueIssue(meta({ valueType: 2 }), "1")]).toEqual(["", "value"]);
    expect([valueIssue(meta({ valueType: 2, subType: 28 }), "true"), valueIssue(meta({ valueType: 2, subType: 28 }), "false")]).toEqual(["", "value"]);
    expect([valueIssue(meta({ valueType: 20 }), "text"), valueIssue(meta({ valueType: 20 }), "a\nb")]).toEqual(["", "value"]);
    expect([valueIssue(meta({ valueType: 16, min: "0", max: "10" }), "11"), valueIssue(meta({ valueType: 16 }), "1.5")]).toEqual(["range", "value"]);
  });
  it("starts a new action with a valid value", () => {
    for (const m of [meta({ min: "5.0", max: "30.0" }), meta({ valueType: 2 }), meta({ valueType: 16, subType: 29, valueList: "A;B" }), meta({ valueType: 6, min: "0", max: "1", unit: "100%" }), meta({ valueType: 16, min: "3", max: "9" })]) {
      expect(valueIssue(m, defaultValue(m))).toBe("");
    }
  });
});

describe("delays", () => {
  it("splits a delay into the biggest whole unit and back", () => {
    expect([splitDelay(30), splitDelay(180), splitDelay(3600), splitDelay(5400), splitDelay(7200)]).toEqual([{ amount: "30", unit: "s" }, { amount: "3", unit: "min" }, { amount: "1", unit: "h" }, { amount: "90", unit: "min" }, { amount: "2", unit: "h" }]);
    const d: ActionDraft = { ...newDraft("script"), delayOn: true, delayAmount: "2", delayUnit: "min" };
    expect(delayInSeconds(d)).toBe(120);
    expect(delayInSeconds({ ...d, delayOn: false })).toBe(0);
  });
});

describe("draftFromAction and toActionInput", () => {
  it("makes a row of a device action with its delay and sends it back as it was", () => {
    const d = draftFromAction(action({ delayType: 28, delay: "2026-11-04 00:03:00" }), targets)!;
    expect([d.kind, d.targetId, d.value, d.delayOn, d.delayAmount, d.delayUnit]).toEqual(["device", "3943", "21", true, "3", "min"]);
    expect(toActionInput(d)).toEqual({ kind: "device", datapointId: "3943", value: "21", delaySeconds: 180 });
  });
  it("shows a scaling value as a percentage and sends the percentage", () => {
    const d = draftFromAction(action({ datapointId: "1013", valueType: 6, value: "0.500000", datapointUnit: "100%" }), targets)!;
    expect(d.value).toBe("50");
    expect(toActionInput(d)).toEqual({ kind: "device", datapointId: "1013", value: "50" });
  });
  it("makes rows of a logic value, a list, a system variable and a script", () => {
    expect(draftFromAction(action({ datapointId: "3939", valueType: 2, value: "false" }), targets)!.value).toBe("false");
    expect(draftFromAction(action({ datapointId: "3941", valueType: 16, value: "1" }), targets)!.value).toBe("1");
    expect(toActionInput(draftFromAction(action({ param: 19, datapointId: "12202", valueType: 16, value: "0" }), targets)!)).toEqual({ kind: "sysvar", variableId: "12202", value: "0" });
    expect(toActionInput(draftFromAction(action({ param: 20, valueType: 20, value: "if (x) {\n}" }), targets)!)).toEqual({ kind: "script", script: "if (x) {\n}" });
  });
  it("gives up on what it cannot show: a target that is not known, an unknown kind", () => {
    expect(draftFromAction(action({ datapointId: "424242" }), targets)).toBeNull();
    expect(draftFromAction(action({ param: 99 }), targets)).toBeNull();
  });
});

describe("draftIssue", () => {
  it("tells what is wrong with a row", () => {
    const ok = draftFromAction(action({}), targets)!;
    expect(draftIssue(ok, targets)).toBe("");
    expect(draftIssue({ ...ok, targetId: "" }, targets)).toBe("target");
    expect(draftIssue({ ...ok, value: "99" }, targets)).toBe("range");
    expect(draftIssue({ ...ok, value: "x" }, targets)).toBe("value");
    expect(draftIssue({ ...ok, delayOn: true, delayAmount: "x" }, targets)).toBe("delay");
    expect(draftIssue({ ...ok, delayOn: true, delayAmount: "100", delayUnit: "h" }, targets)).toBe("delay");
    expect(draftIssue({ ...newDraft("script"), script: "x".repeat(32001) }, targets)).toBe("script");
    expect(draftIssue({ ...newDraft("script"), script: "ok" }, targets)).toBe("");
  });
  it("compares the actions", () => {
    expect(sameActions([{ kind: "script", script: "a" }], [{ kind: "script", script: "a" }])).toBe(true);
    expect(sameActions([{ kind: "script", script: "a" }], [{ kind: "script", script: "b" }])).toBe(false);
  });
});
