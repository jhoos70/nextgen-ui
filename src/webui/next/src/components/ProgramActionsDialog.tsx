import * as React from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { describeChangeError, getProgramTargets, isSessionExpired, saveProgramActions, type LogicRule, type ProgramLogic, type ProgramTargets, type TargetDatapoint, type TargetVariable } from "@/lib/api";
import { useI18n } from "@/lib/i18n";
import {
  ACTIONS_MAX,
  defaultValue,
  draftFromAction,
  draftIssue,
  findTarget,
  inputKind,
  isPercent,
  newDraft,
  numberRange,
  sameActions,
  toActionInput,
  type ActionDraft,
  type ActionKind,
  type DelayUnit,
  type TargetMeta,
} from "@/lib/program-actions";

const MAX_SHOWN = 50;

/** One target to choose from: a datapoint as "channel · PARAM", a variable by its name. */
function TargetPicker({ kind, targets, value, onChange, label }: { kind: ActionKind; targets: ProgramTargets; value: string; onChange: (id: string) => void; label: string }) {
  const { t } = useI18n();
  const [open, setOpen] = React.useState(false);
  const [query, setQuery] = React.useState("");
  const options = React.useMemo(() => {
    const q = query.trim().toLowerCase();
    const all: { id: string; label: string }[] = kind === "device" ? targets.datapoints.map((d: TargetDatapoint) => ({ id: d.id, label: `${d.channel} · ${d.param}` })) : targets.variables.map((v: TargetVariable) => ({ id: v.id, label: v.name }));
    return all.filter((o) => !q || o.label.toLowerCase().includes(q));
  }, [kind, targets, query]);
  const current = kind === "device" ? targets.datapoints.find((d) => d.id === value) : targets.variables.find((v) => v.id === value);
  const currentLabel = current ? ("param" in current ? `${current.channel} · ${current.param}` : current.name) : t("actionPick");
  return (
    <div className="space-y-1">
      <Button type="button" variant="outline" className="h-8 w-full justify-start truncate px-2 text-left text-sm" aria-expanded={open} aria-label={`${label}: ${currentLabel}`} onClick={() => setOpen((o) => !o)}>
        {currentLabel}
      </Button>
      {open && (
        <div className="space-y-1 rounded-md border border-[var(--border)] p-2">
          <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder={t("actionFilter")} aria-label={t("actionFilter")} className="h-8 text-sm" autoFocus />
          {options.length === 0 ? (
            <p className="py-1 text-xs text-[var(--muted-foreground)]">{t("actionNoMatch")}</p>
          ) : (
            <ul className="max-h-40 divide-y divide-[var(--border)] overflow-y-auto text-sm">
              {options.slice(0, MAX_SHOWN).map((o) => (
                <li key={o.id}>
                  <button
                    type="button"
                    className="w-full truncate px-1 py-1 text-left hover:bg-[var(--muted)]"
                    onClick={() => {
                      onChange(o.id);
                      setOpen(false);
                      setQuery("");
                    }}
                  >
                    {o.label}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}

/** The input that fits the target's type. */
function ValueInput({ meta, value, onChange, labelOf }: { meta: TargetMeta & { valueName0?: string; valueName1?: string }; value: string; onChange: (v: string) => void; labelOf: string }) {
  const { t } = useI18n();
  const kind = inputKind(meta);
  if (kind === "trigger") return <span className="text-sm">{t("actionTrigger")}</span>;
  if (kind === "bool") {
    const on = meta.valueName1 && !/^\d$/.test(meta.valueName1) ? meta.valueName1 : t("logicOn");
    const off = meta.valueName0 && !/^\d$/.test(meta.valueName0) ? meta.valueName0 : t("logicOff");
    return (
      <select aria-label={labelOf} className="h-8 rounded-md border border-[var(--border)] bg-[var(--card)] px-2 text-sm" value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="true">{on}</option>
        <option value="false">{off}</option>
      </select>
    );
  }
  if (kind === "enum") {
    return (
      <select aria-label={labelOf} className="h-8 rounded-md border border-[var(--border)] bg-[var(--card)] px-2 text-sm" value={value} onChange={(e) => onChange(e.target.value)}>
        {meta.valueList.split(";").map((name, i) => (
          <option key={i} value={String(i)}>
            {name}
          </option>
        ))}
      </select>
    );
  }
  if (kind === "string") return <Input aria-label={labelOf} value={value} onChange={(e) => onChange(e.target.value)} className="h-8 text-sm" />;
  const range = numberRange(meta);
  const unit = isPercent(meta) ? "%" : meta.unit;
  return (
    <span className="flex items-center gap-1">
      <Input aria-label={labelOf} type="number" inputMode="decimal" step={kind === "integer" ? 1 : "any"} min={range?.min} max={range?.max} value={value} onChange={(e) => onChange(e.target.value)} className="h-8 w-28 text-sm" />
      {unit && <span className="text-sm text-[var(--muted-foreground)]">{unit}</span>}
    </span>
  );
}

/** Edits the actions of one rule of a program (the "then" or the "else" part) and saves them in one request. */
export function ProgramActionsDialog({
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
  const [rows, setRows] = React.useState<ActionDraft[] | null>(null);
  const [initial, setInitial] = React.useState<ReturnType<typeof toActionInput>[]>([]);
  const [stopDelays, setStopDelays] = React.useState(rule.stopDelays);
  const [unsupported, setUnsupported] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState("");

  React.useEffect(() => {
    let active = true;
    getProgramTargets(sid)
      .then((tg) => {
        if (!active) return;
        const drafts = rule.actions.map((a) => draftFromAction(a, tg));
        if (drafts.some((d) => d === null)) setUnsupported(true);
        const ok = drafts.filter((d): d is ActionDraft => d !== null);
        setTargets(tg);
        setRows(ok);
        setInitial(ok.map(toActionInput));
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

  const update = (key: string, patch: Partial<ActionDraft>) => setRows((rs) => rs && rs.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  const move = (index: number, delta: -1 | 1) =>
    setRows((rs) => {
      if (!rs) return rs;
      const target = index + delta;
      if (target < 0 || target >= rs.length) return rs;
      const copy = [...rs];
      const [item] = copy.splice(index, 1);
      copy.splice(target, 0, item);
      return copy;
    });

  const issues = rows && targets ? rows.map((r) => draftIssue(r, targets)) : [];
  const inputs = rows ? rows.map(toActionInput) : [];
  const changed = rows !== null && (!sameActions(inputs, initial) || stopDelays !== rule.stopDelays);
  const valid = issues.every((i) => i === "");

  function describeIssue(row: ActionDraft, issue: string): string {
    switch (issue) {
      case "target":
        return t("errActionTarget");
      case "range": {
        const m = targets ? findTarget(targets, row.kind, row.targetId) : null;
        const r = m ? numberRange(m) : null;
        return t("errActionRange", { min: r?.min ?? "", max: r?.max ?? "" });
      }
      case "script":
        return t("errActionScript");
      case "delay":
        return t("errActionDelay");
      default:
        return t("errActionValue");
    }
  }

  async function save() {
    if (!rows || !valid || busy) return;
    setBusy(true);
    setError("");
    try {
      onSaved(await saveProgramActions(sid, programId, ruleIndex, inputs, stopDelays));
    } catch (e) {
      if (isSessionExpired(e)) return onExpired();
      setError(describeChangeError(e, t));
      setBusy(false);
    }
  }

  const select = "h-8 rounded-md border border-[var(--border)] bg-[var(--card)] px-2 text-sm";
  return (
    <Dialog.Root open onOpenChange={(open) => !open && !busy && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[60] bg-black/50 backdrop-blur-xs" />
        <Dialog.Content aria-describedby={undefined} className="fixed left-1/2 top-1/2 z-[70] max-h-[calc(100vh-2rem)] w-[min(46rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-lg border border-[var(--border)] bg-[var(--card)] p-6 text-[var(--foreground)] shadow-lg">
          <div className="space-y-4">
            <Dialog.Title className="text-lg font-semibold">{t("actionsEditTitle", { part, name: programName })}</Dialog.Title>
            {isActive && <p className="text-sm text-[var(--muted-foreground)]">{t("actionActiveWarning")}</p>}
            {unsupported && (
              <p role="alert" className="text-sm text-[var(--destructive)]">
                {t("actionUnsupported")}
              </p>
            )}
            {!rows && !error && <p className="text-sm text-[var(--muted-foreground)]">{t("loading")}</p>}
            {rows && targets && !unsupported && (
              <>
                {rows.length === 0 && <p className="text-sm text-[var(--muted-foreground)]">{t("actionNone")}</p>}
                <ol className="space-y-3">
                  {rows.map((row, i) => {
                    const meta = row.kind === "script" ? null : findTarget(targets, row.kind, row.targetId);
                    const label = t("actionRow", { n: i + 1 });
                    return (
                      <li key={row.key} className="space-y-2 rounded-md border border-[var(--border)] p-3" aria-label={label}>
                        <div className="flex flex-wrap items-center gap-2">
                          <select
                            aria-label={`${label}: ${t("actionKind")}`}
                            className={select}
                            value={row.kind}
                            onChange={(e) => {
                              const kind = e.target.value as ActionKind;
                              update(row.key, { kind, targetId: "", value: "" });
                            }}
                          >
                            <option value="device">{t("actionKindDevice")}</option>
                            <option value="sysvar">{t("actionKindSysvar")}</option>
                            <option value="script">{t("actionKindScript")}</option>
                          </select>
                          <span className="ml-auto flex gap-1">
                            <Button type="button" variant="outline" className="h-8 px-2" disabled={i === 0} onClick={() => move(i, -1)} aria-label={`${label}: ${t("actionMoveUp")}`}>
                              ↑
                            </Button>
                            <Button type="button" variant="outline" className="h-8 px-2" disabled={i === rows.length - 1} onClick={() => move(i, 1)} aria-label={`${label}: ${t("actionMoveDown")}`}>
                              ↓
                            </Button>
                            <Button type="button" variant="destructive" className="h-8 px-2" onClick={() => setRows((rs) => rs && rs.filter((r) => r.key !== row.key))} aria-label={`${label}: ${t("actionRemove")}`}>
                              {t("actionRemove")}
                            </Button>
                          </span>
                        </div>
                        {row.kind === "script" ? (
                          <textarea
                            aria-label={`${label}: ${t("actionScript")}`}
                            value={row.script}
                            onChange={(e) => update(row.key, { script: e.target.value })}
                            rows={8}
                            spellCheck={false}
                            className="w-full rounded-md border border-[var(--border)] bg-[var(--background)] p-2 font-mono text-xs"
                          />
                        ) : (
                          <div className="grid gap-2 sm:grid-cols-[1fr_auto] sm:items-center">
                            <TargetPicker
                              kind={row.kind}
                              targets={targets}
                              value={row.targetId}
                              label={`${label}: ${t("actionTarget")}`}
                              onChange={(id) => {
                                const m = findTarget(targets, row.kind, id);
                                update(row.key, { targetId: id, value: m ? defaultValue(m) : "" });
                              }}
                            />
                            {meta && <ValueInput meta={meta as TargetMeta & { valueName0?: string; valueName1?: string }} value={row.value} labelOf={`${label}: ${t("actionValue")}`} onChange={(v) => update(row.key, { value: v })} />}
                          </div>
                        )}
                        <div className="flex flex-wrap items-center gap-2 text-sm">
                          <label className="flex items-center gap-2">
                            <input type="checkbox" checked={row.delayOn} onChange={(e) => update(row.key, { delayOn: e.target.checked })} aria-label={`${label}: ${t("actionDelayed")}`} />
                            {t("actionDelayed")}
                          </label>
                          {row.delayOn && (
                            <>
                              <Input aria-label={`${label}: ${t("actionDelayAmount")}`} inputMode="numeric" value={row.delayAmount} onChange={(e) => update(row.key, { delayAmount: e.target.value })} className="h-8 w-20 text-sm" />
                              <select aria-label={`${label}: ${t("actionDelayUnit")}`} className={select} value={row.delayUnit} onChange={(e) => update(row.key, { delayUnit: e.target.value as DelayUnit })}>
                                <option value="s">{t("unitSeconds")}</option>
                                <option value="min">{t("unitMinutes")}</option>
                                <option value="h">{t("unitHours")}</option>
                              </select>
                            </>
                          )}
                        </div>
                        {issues[i] !== "" && (
                          <p role="alert" className="text-sm text-[var(--destructive)]">
                            {describeIssue(row, issues[i])}
                          </p>
                        )}
                      </li>
                    );
                  })}
                </ol>
                <div className="flex flex-wrap items-center gap-3">
                  <Button type="button" variant="outline" disabled={rows.length >= ACTIONS_MAX} onClick={() => setRows((rs) => rs && [...rs, newDraft("device")])}>
                    {t("actionAdd")}
                  </Button>
                  <Label className="flex items-center gap-2 text-sm font-normal">
                    <input type="checkbox" checked={stopDelays} onChange={(e) => setStopDelays(e.target.checked)} />
                    {t("actionStopDelays")}
                  </Label>
                </div>
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
              <Button type="button" onClick={() => void save()} disabled={busy || !changed || !valid || unsupported}>
                {busy ? t("saving") : t("ok")}
              </Button>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
