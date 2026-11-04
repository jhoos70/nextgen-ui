import * as React from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { TargetPicker, ValueInput } from "@/components/ProgramActionsDialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { describeChangeError, getConditionTargets, isSessionExpired, saveProgramConditions, type LogicRule, type ProgramLogic, type ProgramTargets } from "@/lib/api";
import { useI18n } from "@/lib/i18n";
import { findTarget, isPercent, type ActionKind } from "@/lib/program-actions";
import {
  CONDS_MAX,
  conditionIssue,
  defaultConditionValue,
  defaultTrigger,
  destroysTimer,
  draftFromRule,
  GROUPS_MAX,
  hasTrigger,
  newCondition,
  newGroup,
  sameConditions,
  testsFor,
  TIME_TRIGGERS,
  toConditionsInput,
  TRIGGERS,
  type CondDraft,
  type ConditionsDraft,
  type GroupDraft,
  type Joiner,
} from "@/lib/program-conditions";
import { describeTime } from "@/lib/program-logic";

const TEST_LABEL: Record<number, string> = { 1: "=", 5: "=", 12: "≠", 8: ">", 9: "≥", 10: "<", 11: "≤" };
const select = "h-8 rounded-md border border-[var(--border)] bg-[var(--card)] px-2 text-sm";

/** Edits the conditions of one rule ("if" / "else if") of a program in place and saves them in one request. A time control stays, changes how it triggers, or goes: it cannot be made here. */
export function ProgramConditionsDialog({
  programId,
  programName,
  isActive,
  rule,
  ruleIndex,
  part,
  sid,
  onClose,
  onSaved,
  onExpired,
}: {
  programId: string;
  programName: string;
  isActive: boolean;
  rule: LogicRule;
  ruleIndex: number;
  part: string;
  sid: string;
  onClose: () => void;
  onSaved: (logic: ProgramLogic) => void;
  onExpired: () => void;
}) {
  const { t } = useI18n();
  const [targets, setTargets] = React.useState<ProgramTargets | null>(null);
  const [draft, setDraft] = React.useState<ConditionsDraft | null>(null);
  const [initial, setInitial] = React.useState<ReturnType<typeof toConditionsInput> | null>(null);
  const [unsupported, setUnsupported] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState("");
  const [confirm, setConfirm] = React.useState<(() => void) | null>(null);

  React.useEffect(() => {
    let active = true;
    getConditionTargets(sid)
      .then((tg) => {
        if (!active) return;
        const d = draftFromRule(rule, tg);
        setTargets(tg);
        if (!d) return setUnsupported(true);
        setDraft(d);
        setInitial(toConditionsInput(d));
      })
      .catch((e) => {
        if (!active) return;
        if (isSessionExpired(e)) return onExpired();
        setError(describeChangeError(e, t));
      });
    return () => {
      active = false;
    };
    // the rule is the one that was opened: it does not change while the dialog is open
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sid]);

  const updateGroup = (gk: string, f: (g: GroupDraft) => GroupDraft) => setDraft((d) => d && { ...d, groups: d.groups.map((g) => (g.key === gk ? f(g) : g)) });
  const updateCond = (gk: string, ck: string, patch: Partial<CondDraft>) => updateGroup(gk, (g) => ({ ...g, conds: g.conds.map((c) => (c.key === ck ? { ...c, ...patch } : c)) }));
  /** Removing a time control (or a group with one) destroys its timer: ask first. */
  const askThen = (destroys: boolean, apply: () => void) => (destroys ? setConfirm(() => apply) : apply());

  const issues = draft && targets ? draft.groups.map((g) => g.conds.map((c) => conditionIssue(c, targets))) : [];
  const input = draft ? toConditionsInput(draft) : null;
  const changed = input !== null && initial !== null && !sameConditions(input, initial);
  const valid = issues.every((g) => g.every((i) => i === ""));
  const noEmptyGroup = draft ? draft.groups.every((g) => g.conds.length > 0) : false;

  function describeIssue(issue: string): string {
    if (issue === "target") return t("errActionTarget");
    if (issue === "value2") return t("errCondValue2");
    if (issue === "test") return t("errCondTest");
    return t("errActionValue");
  }

  async function save() {
    if (!input || !valid || busy) return;
    setBusy(true);
    setError("");
    try {
      onSaved(await saveProgramConditions(sid, programId, ruleIndex, input));
    } catch (e) {
      if (isSessionExpired(e)) return onExpired();
      setError(describeChangeError(e, t));
      setBusy(false);
    }
  }

  const joiner = (value: Joiner, onChange: (v: Joiner) => void, label: string) => (
    <label className="flex items-center gap-2 text-sm">
      {label}
      <select aria-label={label} className={select} value={value} onChange={(e) => onChange(e.target.value as Joiner)}>
        <option value="and">{t("logicAnd")}</option>
        <option value="or">{t("logicOr")}</option>
      </select>
    </label>
  );

  return (
    <Dialog.Root open onOpenChange={(open) => !open && !busy && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[60] bg-black/50 backdrop-blur-xs" />
        <Dialog.Content aria-describedby={undefined} className="fixed left-1/2 top-1/2 z-[70] max-h-[calc(100vh-2rem)] w-[min(48rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-lg border border-[var(--border)] bg-[var(--card)] p-6 text-[var(--foreground)] shadow-lg">
          <div className="space-y-4">
            <Dialog.Title className="text-lg font-semibold">{t("condsEditTitle", { part, name: programName })}</Dialog.Title>
            {isActive && <p className="text-sm text-[var(--muted-foreground)]">{t("actionActiveWarning")}</p>}
            {unsupported && (
              <p role="alert" className="text-sm text-[var(--destructive)]">
                {t("condUnsupported")}
              </p>
            )}
            {!draft && !unsupported && !error && <p className="text-sm text-[var(--muted-foreground)]">{t("loading")}</p>}
            {draft && targets && (
              <>
                <p className="text-xs text-[var(--muted-foreground)]">{t("condTimeNote")}</p>
                {draft.groups.length === 0 && <p className="text-sm text-[var(--muted-foreground)]">{t("condNone")}</p>}
                {draft.groups.length > 1 && joiner(draft.op, (op) => setDraft((d) => d && { ...d, op }), t("condJoinGroups"))}
                <ol className="space-y-4">
                  {draft.groups.map((g, gi) => (
                    <li key={g.key} aria-label={t("condGroup", { n: gi + 1 })} className="space-y-3 rounded-md border border-[var(--border)] p-3">
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <h3 className="text-sm font-semibold">{t("condGroup", { n: gi + 1 })}</h3>
                        <Button
                          type="button"
                          variant="destructive"
                          className="h-7 px-2 text-xs"
                          aria-label={`${t("condGroup", { n: gi + 1 })}: ${t("condRemoveGroup")}`}
                          onClick={() => askThen(destroysTimer(g.conds), () => setDraft((d) => d && { ...d, groups: d.groups.filter((x) => x.key !== g.key) }))}
                        >
                          {t("condRemoveGroup")}
                        </Button>
                      </div>
                      {g.conds.length > 1 && joiner(g.op, (op) => updateGroup(g.key, (x) => ({ ...x, op })), `${t("condGroup", { n: gi + 1 })}: ${t("condJoinWithin")}`)}
                      <ol className="space-y-2">
                        {g.conds.map((c, ci) => {
                          const label = `${t("condGroup", { n: gi + 1 })}, ${t("actionRow", { n: ci + 1 })}`;
                          const meta = c.kind === "time" ? null : findTarget(targets, c.kind, c.targetId);
                          const kind = c.kind as ActionKind;
                          return (
                            <li key={c.key} aria-label={label} className="space-y-2 rounded-md bg-[var(--muted)] p-2">
                              <div className="flex flex-wrap items-center gap-2">
                                {c.kind === "time" ? (
                                  <span className="text-sm">
                                    <strong>{t("condTimeKept")}:</strong> {c.original?.time ? describeTime(c.original.time, t) : ""}
                                  </span>
                                ) : (
                                  <select
                                    aria-label={`${label}: ${t("actionKind")}`}
                                    className={select}
                                    value={c.kind}
                                    onChange={(e) => updateCond(g.key, c.key, { kind: e.target.value as "device" | "sysvar", targetId: "", value: "", test: 1 })}
                                  >
                                    <option value="device">{t("actionKindDevice")}</option>
                                    <option value="sysvar">{t("actionKindSysvar")}</option>
                                  </select>
                                )}
                                <Button
                                  type="button"
                                  variant="destructive"
                                  className="ml-auto h-7 px-2 text-xs"
                                  aria-label={`${label}: ${t("condRemove")}`}
                                  onClick={() => askThen(c.kind === "time", () => updateGroup(g.key, (x) => ({ ...x, conds: x.conds.filter((y) => y.key !== c.key) })))}
                                >
                                  {t("condRemove")}
                                </Button>
                              </div>
                              {c.kind === "time" ? (
                                <label className="flex items-center gap-2 text-sm">
                                  {t("condTrigger")}
                                  <select aria-label={`${label}: ${t("condTrigger")}`} className={select} value={c.trigger} onChange={(e) => updateCond(g.key, c.key, { trigger: Number(e.target.value) })}>
                                    {TIME_TRIGGERS.map((n) => (
                                      <option key={n} value={n}>
                                        {t(n === 13 ? "trigOnUpdate" : "trigCheckOnly")}
                                      </option>
                                    ))}
                                  </select>
                                </label>
                              ) : (
                                <>
                                  <TargetPicker
                                    kind={kind}
                                    targets={targets}
                                    value={c.targetId}
                                    label={`${label}: ${t("actionTarget")}`}
                                    onChange={(id) => {
                                      const m = findTarget(targets, c.kind as "device" | "sysvar", id);
                                      updateCond(g.key, c.key, m ? { targetId: id, test: testsFor(m)[0] ?? 1, value: defaultConditionValue(m), value2: "0", trigger: defaultTrigger(m) } : { targetId: id });
                                    }}
                                  />
                                  {meta && (
                                    <div className="flex flex-wrap items-center gap-2">
                                      {testsFor(meta).length > 1 && (
                                        <select aria-label={`${label}: ${t("condComparison")}`} className={select} value={c.test} onChange={(e) => updateCond(g.key, c.key, { test: Number(e.target.value) })}>
                                          {testsFor(meta).map((n) => (
                                            <option key={n} value={n}>
                                              {n === 6 ? t("testBetween") : TEST_LABEL[n]}
                                            </option>
                                          ))}
                                        </select>
                                      )}
                                      <ValueInput ranged={false} meta={meta as typeof meta & { valueName0?: string; valueName1?: string }} value={c.value} labelOf={`${label}: ${t("actionValue")}`} onChange={(v) => updateCond(g.key, c.key, { value: v })} />
                                      {c.test === 6 && (
                                        <>
                                          <span className="text-sm">{t("logicAnd")}</span>
                                          <Input aria-label={`${label}: ${t("condValue2")}`} type="number" inputMode="decimal" step="any" value={c.value2} onChange={(e) => updateCond(g.key, c.key, { value2: e.target.value })} className="h-8 w-28 text-sm" />
                                          {isPercent(meta) && <span className="text-sm text-[var(--muted-foreground)]">%</span>}
                                        </>
                                      )}
                                      {hasTrigger(meta) && (
                                        <select aria-label={`${label}: ${t("condTrigger")}`} className={select} value={c.trigger} onChange={(e) => updateCond(g.key, c.key, { trigger: Number(e.target.value) })}>
                                          {TRIGGERS.map((n) => (
                                            <option key={n} value={n}>
                                              {t(n === 4 ? "trigOnChange" : n === 13 ? "trigOnUpdate" : "trigCheckOnly")}
                                            </option>
                                          ))}
                                        </select>
                                      )}
                                    </div>
                                  )}
                                </>
                              )}
                              {issues[gi]?.[ci] && (
                                <p role="alert" className="text-sm text-[var(--destructive)]">
                                  {describeIssue(issues[gi][ci])}
                                </p>
                              )}
                            </li>
                          );
                        })}
                      </ol>
                      <Button type="button" variant="outline" className="h-8 text-sm" disabled={g.conds.length >= CONDS_MAX} onClick={() => updateGroup(g.key, (x) => ({ ...x, conds: [...x.conds, newCondition("device")] }))}>
                        {t("condAdd")}
                      </Button>
                    </li>
                  ))}
                </ol>
                <Button type="button" variant="outline" disabled={draft.groups.length >= GROUPS_MAX} onClick={() => setDraft((d) => d && { ...d, groups: [...d.groups, newGroup()] })}>
                  {t("condAddGroup")}
                </Button>
              </>
            )}
            {error && (
              <p role="alert" className="text-sm text-[var(--destructive)]">
                {error}
              </p>
            )}
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={onClose} disabled={busy}>
                {t("cancel")}
              </Button>
              <Button type="button" onClick={() => void save()} disabled={busy || !changed || !valid || !noEmptyGroup || unsupported}>
                {busy ? t("saving") : t("ok")}
              </Button>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
      {confirm && (
        <ConfirmDialog
          raised
          title={t("condTimerWarningTitle")}
          message={t("condTimerWarning")}
          confirmLabel={t("condRemove")}
          onConfirm={async () => {
            confirm();
            return null;
          }}
          onClose={() => setConfirm(null)}
        />
      )}
    </Dialog.Root>
  );
}
