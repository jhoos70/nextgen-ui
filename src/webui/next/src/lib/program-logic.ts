import type { LogicAction, LogicCondition } from "./api";
import type { Translate } from "./i18n";

/** ReGa's codes for the right-hand value of a condition and for what a destination sets. */
export const VT_BINARY = 2;
export const VT_FLOAT = 4;
export const VT_INTEGER = 16;
export const VT_OBJECT = 18;
export const VT_SYSVAR = 19;
export const VT_STRING = 20;
export const VT_DELAY = 28;

const TIMER_TYPES: Record<number, "timeOnce" | "timePeriodic" | "timeDaily" | "timeWeekly" | "timeMonthly" | "timeYearly"> = {
  8: "timeOnce",
  4: "timePeriodic",
  9: "timeDaily",
  5: "timeWeekly",
  6: "timeMonthly",
  7: "timeYearly",
};

/** The datapoint's own name ("MANU_MODE") from "VirtualDevices.INT0000006:1.MANU_MODE". */
export const shortDatapoint = (name: string): string => name.slice(name.lastIndexOf(".") + 1);

/** "21.000000" -> "21", "20.500000" -> "20.5"; anything that is no number stays as it is. */
export function trimNumber(v: string): string {
  if (!/^-?\d+(\.\d+)?$/.test(v)) return v;
  return String(Number(v));
}

/** ReGa hands a delay out as a date-time ("2026-11-04 00:03:00" = 3 minutes): the classic editor reads hours, minutes and seconds at fixed places. */
export function delaySeconds(v: string): number {
  const m = /^\d{4}-\d\d-\d\d (\d\d):(\d\d):(\d\d)/.exec(v);
  if (m) return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]);
  return Number(v);
}

/** 3725 -> "1 h 2 min 5 s". */
export function formatSeconds(v: string): string {
  const n = delaySeconds(v);
  if (!Number.isFinite(n) || n < 0) return v;
  if (n === 0) return "0 s";
  const h = Math.floor(n / 3600);
  const m = Math.floor((n % 3600) / 60);
  const s = Math.round((n % 60) * 100) / 100;
  return [h ? `${h} h` : "", m ? `${m} min` : "", s ? `${s} s` : ""].filter(Boolean).join(" ");
}

function withUnit(v: string, unit: string): string {
  const n = trimNumber(v);
  if (unit === "100%") return `${trimNumber(String(Math.round(Number(v) * 10000) / 100))} %`;
  return unit ? `${n} ${unit}` : n;
}

/** The right-hand value of a condition: a name for a logic value or a list entry, else the number with its unit. */
function conditionValue(c: LogicCondition, v: string, vt: number, t: Translate): string {
  if (vt === VT_BINARY) {
    const named = v === "true" || v === "1" ? c.valueName1 : c.valueName0;
    if (named && !/^\d$/.test(named)) return named;
    return v === "true" || v === "1" ? t("logicOn") : t("logicOff");
  }
  const [type, sub] = c.valueType.split("/");
  if (sub === "29" && type === "16" && c.valueList) {
    const entry = c.valueList.split(";")[Number(v)];
    if (entry) return entry;
  }
  return withUnit(v, c.unit);
}

const TRIGGERS: Record<number, "logicOnChange" | "logicOnUpdate" | "logicCheckOnly"> = { 4: "logicOnChange", 13: "logicOnUpdate", 15: "logicCheckOnly" };

/** A timer ("daily at 06:30") in words. */
export function describeTime(tm: NonNullable<LogicCondition["time"]>, t: Translate): string {
  const parts: string[] = [];
  const kind = TIMER_TYPES[tm.timerType];
  if (kind) parts.push(t(kind));
  const clock = (iso: string) => iso.slice(11, 16);
  if (tm.sunOffset === 0) {
    if (tm.seconds === 0 && tm.duration === 0) parts.push(t("timeAllDay"));
    else if (tm.duration === 0) parts.push(t("timeAt", { time: clock(tm.time) }));
    else {
      // the local time string, not "seconds" (which is UTC), so that the end follows the start on the same clock
      const start = Number(tm.time.slice(11, 13)) * 3600 + Number(tm.time.slice(14, 16)) * 60;
      const endSeconds = (start + tm.duration) % 86400;
      const end = `${String(Math.floor(endSeconds / 3600)).padStart(2, "0")}:${String(Math.floor((endSeconds % 3600) / 60)).padStart(2, "0")}`;
      parts.push(t("timeFromTo", { from: clock(tm.time), to: end }));
    }
  } else if (tm.sunOffset >= 1 && tm.sunOffset <= 3) parts.push(t("timeDaytime"));
  else parts.push(t("timeNight"));
  const date = (iso: string) => `${iso.slice(8, 10)}.${iso.slice(5, 7)}.${iso.slice(0, 4)}`;
  if (tm.begin && !tm.begin.startsWith("1970-")) parts.push(t("timeStart", { date: date(tm.begin) }));
  if (tm.repetitions > 0) parts.push(t("timeRepetitions", { n: tm.repetitions }));
  else if (tm.end && !tm.end.startsWith("1970-")) parts.push(t("timeUntil", { date: date(tm.end) }));
  return parts.join(" ");
}

/** One single condition in words: "Kinderzimmer:1 · CONTROL_MODE = MANU-MODE, when it changes". */
export function describeCondition(c: LogicCondition, t: Translate): string {
  const trigger = TRIGGERS[c.trigger] ? t(TRIGGERS[c.trigger]) : "";
  if (c.kind === "time") return [c.time ? describeTime(c.time, t) : t("timeModule"), trigger].filter(Boolean).join(", ");
  if (c.kind === "unknown") return t("logicUnsupported");
  const subject = c.kind === "device" ? `${c.channelName} · ${shortDatapoint(c.objectName)}` : c.objectName;
  const num = (v: string, vt: number) => conditionValue(c, v, vt, t);
  let test: string;
  switch (c.test) {
    case 1:
    case 5:
      test = `= ${num(c.right, c.rightType)}`;
      break;
    case 12:
      test = `≠ ${num(c.right, c.rightType)}`;
      break;
    case 8:
      test = `> ${num(c.right, c.rightType)}`;
      break;
    case 9:
      test = `≥ ${num(c.right, c.rightType)}`;
      break;
    case 10:
      test = `< ${num(c.right, c.rightType)}`;
      break;
    case 11:
      test = `≤ ${num(c.right, c.rightType)}`;
      break;
    case 6:
    case 7:
      test = t("logicRange", { from: num(c.right, c.rightType), to: num(c.right2, c.right2Type) });
      break;
    default:
      test = t("logicUnsupported");
  }
  return [`${subject} ${test}`, trigger].filter(Boolean).join(", ");
}

/** What an action does, without its delay or script text: "Set Kinderzimmer:1 · MANU_MODE to 21". */
export function describeAction(a: LogicAction, t: Translate): string {
  if (a.param === VT_STRING) return t("logicRunScript");
  if (a.param !== VT_OBJECT && a.param !== VT_SYSVAR) return t("logicUnsupported");
  const target = a.param === VT_OBJECT ? `${a.channelName} · ${shortDatapoint(a.datapointName)}` : a.datapointName || a.channelName;
  let value = a.value;
  if (a.valueType === VT_BINARY) value = a.value === "true" || a.value === "1" ? t("logicOn") : t("logicOff");
  else if (a.valueType === VT_FLOAT || a.valueType === VT_INTEGER) value = trimNumber(a.value);
  else if (a.valueType === 5 || a.valueType === 6) value = a.datapointUnit === "100%" ? `${trimNumber(String(Math.round(Number(a.value) * 10000) / 100))} %` : trimNumber(a.value);
  return t("logicSet", { target, value });
}

/** The delay of an action in words, or "" for an immediate one. */
export const describeDelay = (a: LogicAction, t: Translate): string => (a.delayType === VT_DELAY && a.delay ? t("logicDelayed", { delay: formatSeconds(a.delay) }) : "");

/** Anything this view cannot show as ReGa holds it (it will open read-only in the editor later). */
export const isUnsupportedCondition = (c: LogicCondition): boolean => c.kind === "unknown" || (c.kind !== "time" && ![1, 5, 6, 7, 8, 9, 10, 11, 12].includes(c.test));
