import * as React from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { Button } from "@/components/ui/button";
import { ProgramActionsDialog } from "@/components/ProgramActionsDialog";
import { describeChangeError, getProgramLogic, isSessionExpired, type LogicRule, type Program } from "@/lib/api";
import { useI18n } from "@/lib/i18n";
import { describeAction, describeCondition, describeDelay, VT_STRING } from "@/lib/program-logic";

/** What a program does, read from the CCU and shown in words: its conditions and its actions, per rule. Read only. */
export function ProgramLogicDialog({ program, sid, onClose, onExpired, onChanged }: { program: Program; sid: string; onClose: () => void; onExpired: () => void; onChanged: () => void }) {
  const { t } = useI18n();
  const [rules, setRules] = React.useState<LogicRule[] | null>(null);
  const [error, setError] = React.useState("");
  const [editing, setEditing] = React.useState<number | null>(null);
  const [saved, setSaved] = React.useState(false);
  const editOpener = React.useRef<HTMLElement | null>(null);

  React.useEffect(() => {
    let active = true;
    getProgramLogic(sid, program.id)
      .then((l) => active && setRules(l.rules))
      .catch((e) => {
        if (!active) return;
        if (isSessionExpired(e)) return onExpired();
        setError(describeChangeError(e, t));
      });
    return () => {
      active = false;
    };
    // the texts do not change what is read
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sid, program.id]);

  const heading = (rule: LogicRule, index: number) => (!rule.hasCondition ? t("logicElse") : index === 0 ? t("logicIf") : t("logicElseIf"));

  return (
    <Dialog.Root open onOpenChange={(open) => !open && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/50 backdrop-blur-xs" />
        <Dialog.Content
          aria-describedby={undefined}
          className="fixed left-1/2 top-1/2 z-50 max-h-[calc(100vh-2rem)] w-[min(44rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-lg border border-[var(--border)] bg-[var(--card)] p-6 text-[var(--foreground)] shadow-lg"
        >
          <div className="space-y-4">
            <Dialog.Title className="text-lg font-semibold">{t("logicTitle", { name: program.name })}</Dialog.Title>
            <p className="text-xs text-[var(--muted-foreground)]">{t("logicReadOnly")}</p>
            {saved && (
              <p role="status" className="text-sm">
                {t("actionSaved", { name: program.name })}
              </p>
            )}
            {error && (
              <p role="alert" className="text-sm text-[var(--destructive)]">
                {error}
              </p>
            )}
            {!rules && !error && <p className="text-sm text-[var(--muted-foreground)]">{t("loading")}</p>}
            {rules && rules.length === 0 && <p className="text-sm">{t("logicNoRules")}</p>}
            {rules?.map((rule, ri) => (
              <section key={ri} className="space-y-2 rounded-md border border-[var(--border)] p-3 text-sm">
                {rule.hasCondition && (
                  <div>
                    <h3 className="font-semibold">{heading(rule, ri)}</h3>
                    {rule.groups.length === 0 && <p className="text-[var(--muted-foreground)]">—</p>}
                    {rule.groups.map((g, gi) => (
                      <React.Fragment key={gi}>
                        {gi > 0 && <p className="my-1 font-semibold">{t(rule.groups[gi - 1].op === "and" ? "logicAnd" : "logicOr")}</p>}
                        <ul className="ml-4 list-disc space-y-0.5">
                          {g.conditions.map((c, ci) => (
                            <li key={ci}>
                              {ci > 0 && <strong>{t(c.op === "and" ? "logicAnd" : "logicOr")} </strong>}
                              {describeCondition(c, t)}
                            </li>
                          ))}
                        </ul>
                      </React.Fragment>
                    ))}
                  </div>
                )}
                <div>
                  <div className="flex items-center justify-between gap-2">
                    <h3 className="font-semibold">{rule.hasCondition ? t("logicThen") : heading(rule, ri)}</h3>
                    <Button
                      type="button"
                      variant="outline"
                      className="h-7 px-2 text-xs"
                      aria-label={`${t("actionsEdit")}: ${rule.hasCondition ? t("logicThen") : heading(rule, ri)}`}
                      onClick={(e) => {
                        editOpener.current = e.currentTarget;
                        setEditing(ri);
                      }}
                    >
                      {t("actionsEdit")}
                    </Button>
                  </div>
                  {rule.actions.length === 0 ? (
                    <p className="text-[var(--muted-foreground)]">{t("logicNoActions")}</p>
                  ) : (
                    <ul className="ml-4 list-disc space-y-1">
                      {rule.actions.map((a, ai) => (
                        <li key={ai}>
                          {describeAction(a, t)}
                          {describeDelay(a, t) && <span className="text-[var(--muted-foreground)]"> — {describeDelay(a, t)}</span>}
                          {a.param === VT_STRING && a.value && (
                            <details className="mt-1">
                              <summary className="cursor-pointer text-xs text-[var(--muted-foreground)]">{t("logicShowScript")}</summary>
                              <pre className="mt-1 max-h-64 overflow-auto rounded bg-[var(--muted)] p-2 text-xs whitespace-pre-wrap">{a.value}</pre>
                            </details>
                          )}
                        </li>
                      ))}
                    </ul>
                  )}
                  {rule.stopDelays && rule.actions.length > 0 && <p className="mt-1 text-xs text-[var(--muted-foreground)]">{t("logicStopDelays")}</p>}
                </div>
              </section>
            ))}
            <div className="flex justify-end">
              <Button type="button" variant="outline" onClick={onClose} autoFocus>
                {t("ok")}
              </Button>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
      {rules && editing !== null && rules[editing] && (
        <ProgramActionsDialog
          programId={program.id}
          programName={program.name}
          isActive={program.isActive}
          rule={rules[editing]}
          ruleIndex={editing}
          part={rules[editing].hasCondition ? t("logicThen") : heading(rules[editing], editing)}
          sid={sid}
          onExpired={onExpired}
          onClose={() => {
            setEditing(null);
            const back = editOpener.current;
            window.setTimeout(() => back?.isConnected && back.focus(), 0);
          }}
          onSaved={(logic) => {
            setRules(logic.rules);
            setSaved(true);
            setEditing(null);
            onChanged();
          }}
        />
      )}
    </Dialog.Root>
  );
}
