import { describe, expect, it } from "vitest";
import type { LogicAction, LogicCondition } from "./api";
import { makeGetProgramLogic } from "./api";
import { translate } from "./i18n";
import { delaySeconds, describeAction, describeCondition, describeDelay, describeTime, formatSeconds, shortDatapoint, trimNumber } from "./program-logic";

const t = (k: Parameters<typeof translate>[1], p?: Record<string, string | number>) => translate("en", k, p);
const de = (k: Parameters<typeof translate>[1], p?: Record<string, string | number>) => translate("de", k, p);

const cond = (o: Partial<LogicCondition>): LogicCondition => ({
  op: "or",
  kind: "device",
  objectId: "1",
  objectName: "VirtualDevices.INT0000006:1.CONTROL_MODE",
  channelId: "2",
  channelName: "Kinderzimmer:1",
  valueType: "16/29",
  unit: "",
  valueName0: "",
  valueName1: "",
  valueList: "AUTO-MODE;MANU-MODE;PARTY-MODE",
  test: 1,
  trigger: 4,
  rightType: 16,
  right: "1",
  right2Type: 16,
  right2: "0",
  ...o,
});
const act = (o: Partial<LogicAction>): LogicAction => ({ param: 18, valueType: 4, delayType: 0, value: "21.000000", delay: "", channelId: "2", datapointId: "3", channelName: "Kinderzimmer:1", datapointName: "VirtualDevices.INT0000006:1.MANU_MODE", datapointType: "4/0", ...o });

describe("small helpers", () => {
  it("shortens a datapoint name and trims numbers", () => {
    expect(shortDatapoint("VirtualDevices.INT0000006:1.MANU_MODE")).toBe("MANU_MODE");
    expect(shortDatapoint("Anwesenheit")).toBe("Anwesenheit");
    expect([trimNumber("21.000000"), trimNumber("20.500000"), trimNumber("-3"), trimNumber("abc")]).toEqual(["21", "20.5", "-3", "abc"]);
  });
  it("reads a delay the way the classic editor does, and formats it", () => {
    expect(delaySeconds("2026-11-04 00:03:00")).toBe(180);
    expect(delaySeconds("2026-11-04 01:02:05")).toBe(3725);
    expect(delaySeconds("30")).toBe(30);
    expect([formatSeconds("2026-11-04 00:03:00"), formatSeconds("3725"), formatSeconds("0"), formatSeconds("x")]).toEqual(["3 min", "1 h 2 min 5 s", "0 s", "x"]);
  });
});

describe("describeCondition", () => {
  it("names the list entry of a device datapoint and when it triggers", () => {
    expect(describeCondition(cond({}), t)).toBe("Kinderzimmer:1 · CONTROL_MODE = MANU-MODE, when it changes");
  });
  it("uses the names of a logic value, and on / off when there are none", () => {
    const sv = { kind: "sysvar" as const, objectName: "Anwesenheit", channelName: "", valueType: "2/2", valueName0: "nicht anwesend", valueName1: "anwesend", valueList: "", rightType: 2, trigger: 4 };
    expect(describeCondition(cond({ ...sv, right: "true" }), t)).toBe("Anwesenheit = anwesend, when it changes");
    expect(describeCondition(cond({ ...sv, right: "false" }), t)).toBe("Anwesenheit = nicht anwesend, when it changes");
    expect(describeCondition(cond({ kind: "device", valueType: "2/0", valueName0: "0", valueName1: "1", valueList: "", rightType: 2, right: "true", trigger: 13 }), t)).toBe("Kinderzimmer:1 · CONTROL_MODE = on, when it is updated");
  });
  it("shows a number with its unit and the comparison", () => {
    const temp = { valueType: "4/0", unit: "°C", valueList: "", rightType: 4, trigger: 13 };
    expect(describeCondition(cond({ ...temp, test: 8, right: "20.000000" }), t)).toBe("Kinderzimmer:1 · CONTROL_MODE > 20 °C, when it is updated");
    expect(describeCondition(cond({ ...temp, test: 9, right: "20.5" }), t)).toContain("≥ 20.5 °C");
    expect(describeCondition(cond({ ...temp, test: 10, right: "5" }), t)).toContain("< 5 °C");
    expect(describeCondition(cond({ ...temp, test: 12, right: "5" }), t)).toContain("≠ 5 °C");
    expect(describeCondition(cond({ ...temp, test: 6, right: "5", right2: "9" }), t)).toContain("between 5 °C and 9 °C");
  });
  it("shows a percentage that ReGa keeps as a fraction", () => {
    expect(describeCondition(cond({ valueType: "4/0", unit: "100%", valueList: "", rightType: 4, test: 8, right: "0.5" }), t)).toContain("> 50 %");
  });
  it("says check only for a condition that does not trigger, and is German in German", () => {
    expect(describeCondition(cond({ trigger: 15 }), t)).toContain("only checked");
    expect(describeCondition(cond({ trigger: 4 }), de)).toContain("bei Änderung");
  });
  it("says it cannot show what it does not know", () => {
    expect(describeCondition(cond({ test: 99 }), t)).toContain("Not shown here");
    expect(describeCondition(cond({ kind: "unknown" }), t)).toContain("Not shown here");
  });
});

describe("describeTime", () => {
  const tm = { timerType: 9, sunOffset: 0, seconds: 23400, duration: 0, time: "1970-01-01 07:30:00", begin: "2025-10-04 00:00:00", end: "1970-01-01 01:00:00", repetitions: 0 };
  it("describes a daily time with its start", () => {
    expect(describeTime(tm, t)).toBe("daily at 07:30 starting 04.10.2025");
  });
  it("describes a span, the whole day, daytime and night", () => {
    expect(describeTime({ ...tm, duration: 3600 }, t)).toContain("from 07:30 to 08:30");
    expect(describeTime({ ...tm, seconds: 0, time: "1970-01-01 01:00:00" }, t)).toContain("all day");
    expect(describeTime({ ...tm, sunOffset: 1 }, t)).toContain("during the day");
    expect(describeTime({ ...tm, sunOffset: 4 }, t)).toContain("at night");
  });
  it("tells repetitions or an end date", () => {
    expect(describeTime({ ...tm, repetitions: 5 }, t)).toContain("with 5 repetitions");
    expect(describeTime({ ...tm, end: "2026-01-02 00:00:00" }, t)).toContain("until 02.01.2026");
  });
  it("is a time condition in a condition", () => {
    expect(describeCondition(cond({ kind: "time", test: 3, trigger: 13, time: tm }), t)).toBe("daily at 07:30 starting 04.10.2025, when it is updated");
  });
});

describe("describeAction", () => {
  it("sets a device datapoint", () => {
    expect(describeAction(act({}), t)).toBe("Set Kinderzimmer:1 · MANU_MODE to 21");
    expect(describeAction(act({ valueType: 2, value: "false" }), t)).toBe("Set Kinderzimmer:1 · MANU_MODE to off");
  });
  it("sets a system variable by its name", () => {
    expect(describeAction(act({ param: 19, valueType: 16, value: "0", channelName: "", datapointName: "Rollladenautomatik" }), t)).toBe("Set Rollladenautomatik to 0");
  });
  it("runs a script and tells a delay", () => {
    expect(describeAction(act({ param: 20, valueType: 20 }), t)).toBe("Run a script");
    expect(describeDelay(act({ delayType: 28, delay: "2026-11-04 00:05:00" }), t)).toBe("after 5 min");
    expect(describeDelay(act({}), t)).toBe("");
  });
});

describe("getProgramLogic", () => {
  it("GETs the program with its id and keeps the rules", async () => {
    let url = "", init: RequestInit | undefined;
    const body = { id: "7", name: "P", description: "", isActive: true, isVisible: true, isOperable: true, rules: [{ hasCondition: true, groups: [], stopDelays: false, actions: [] }] };
    const out = await makeGetProgramLogic(async (u, i) => ((url = String(u)), (init = i), new Response(JSON.stringify(body))))("x", "7");
    expect([url, init!.method, out.rules.length]).toEqual(["/api/homematic.cgi/v2/programs?id=7", "GET", 1]);
  });
  it("refuses an answer without rules", async () => {
    await expect(makeGetProgramLogic(async () => new Response('{"id":"7","name":"P","isVisible":true,"isOperable":true}'))("x", "7")).rejects.toBeInstanceOf(Error);
  });
});
