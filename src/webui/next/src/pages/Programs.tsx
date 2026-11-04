import * as React from "react";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { ProgramDialog, type ProgramDialogMode } from "@/components/ProgramDialog";
import { Button } from "@/components/ui/button";
import { Card, CardDescription, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Table, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { deleteProgram, describeChangeError, describeError, executeProgram, getModel, isSessionExpired, setProgramActive, type Program } from "@/lib/api";
import { text } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { useCurrentProfile } from "@/lib/profile-context";
import { filterPrograms, neverRan } from "@/lib/programs";
import { formatTime } from "@/lib/service-messages";
import { useCcuStrings } from "@/lib/use-ccu-strings";
import { usePolled } from "@/lib/use-polled";

/** A request runs a script on the CCU, so every 10 seconds is enough to keep the last run current. */
const POLL_MS = 10_000;

const getProgramQueryFromHash = (): string => {
  const m = window.location.hash.match(/[?&]q=([^&]+)/);
  if (m) return decodeURIComponent(m[1]);
  return "";
};

/** Status and control of the programs: the classic status list and its action, the run. */
export default function Programs({ sid, onExpired }: { sid: string; onExpired: () => void }) {
  const { t, lang } = useI18n();
  const strings = useCcuStrings("extension", "stringtable");
  const profile = useCurrentProfile();
  const load = React.useCallback(async () => (await getModel("programs", sid)).items, [sid]);
  const { data, error, loaded, refresh } = usePolled(load, POLL_MS, onExpired);
  const [query, setQuery] = React.useState<string>(getProgramQueryFromHash);

  React.useEffect(() => {
    const onHash = () => {
      const q = getProgramQueryFromHash();
      if (q) setQuery(q);
    };
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const [running, setRunning] = React.useState<string | null>(null);
  const [message, setMessage] = React.useState<{ text: string; failed: boolean } | null>(null);
  // the time of the last run the CCU reported for a run, shown until the next update has caught up
  const [lastRuns, setLastRuns] = React.useState<Record<string, string>>({});
  // the active flag the CCU reported for a switch, shown until the next update has caught up
  const [actives, setActives] = React.useState<Record<string, boolean>>({});

  React.useEffect(() => {
    if (!data) return;
    setLastRuns((m) => {
      const next = { ...m };
      for (const id of Object.keys(m)) {
        const d = data.find((x) => x.id === id);
        if (d && d.lastExecuteTime >= m[id]) delete next[id];
      }
      return Object.keys(next).length === Object.keys(m).length ? m : next;
    });
  }, [data]);

  React.useEffect(() => {
    if (!data) return;
    setActives((m) => {
      const next = { ...m };
      for (const id of Object.keys(m)) if (data.find((x) => x.id === id)?.isActive === m[id]) delete next[id];
      return Object.keys(next).length === Object.keys(m).length ? m : next;
    });
  }, [data]);

  const mayRun = profile?.level === "USER" || profile?.level === "ADMIN";
  // switching a program on or off is the editor's job in the classic UI: administrators only
  const maySwitch = profile?.level === "ADMIN";
  const shown = filterPrograms(
    (data ?? []).map((p): Program => ({ ...p, ...(lastRuns[p.id] ? { lastExecuteTime: lastRuns[p.id] } : {}), ...(p.id in actives ? { isActive: actives[p.id] } : {}) })),
    query,
    lang,
    maySwitch,
  );
  const any = filterPrograms(data ?? [], "", lang, maySwitch).length > 0;

  async function run(p: Program) {
    const name = text(p.name, strings);
    setRunning(p.id);
    setMessage(null);
    try {
      const r = await executeProgram(sid, p.id);
      setMessage({ text: t(r.executed ? "programStarted" : "programNotStarted", { name }), failed: !r.executed });
      if (r.lastExecuteTime) setLastRuns((m) => ({ ...m, [p.id]: r.lastExecuteTime }));
      refresh();
    } catch (e) {
      if (isSessionExpired(e)) return onExpired();
      setMessage({ text: t("programFailed", { name, reason: describeChangeError(e, t) }), failed: true });
    } finally {
      setRunning(null);
    }
  }

  /** Switches a program; returns the reason it failed (for a dialog), or null. */
  async function switchActive(p: Program, active: boolean): Promise<string | null> {
    const name = text(p.name, strings);
    setRunning(p.id);
    setMessage(null);
    try {
      const r = await setProgramActive(sid, p.id, active);
      setActives((m) => ({ ...m, [p.id]: r.isActive }));
      setMessage({ text: t(r.isActive ? "programActivated" : "programDeactivated", { name }), failed: false });
      refresh();
      return null;
    } catch (e) {
      if (isSessionExpired(e)) {
        onExpired();
        return null;
      }
      const reason = describeChangeError(e, t);
      setMessage({ text: t("programSwitchFailed", { name, reason }), failed: true });
      return reason;
    } finally {
      setRunning(null);
    }
  }
  // activating asks first: the CCU checks the conditions of a program when it is activated, and it can run at once
  const [activating, setActivating] = React.useState<Program | null>(null);
  const switchOpener = React.useRef<HTMLElement | null>(null);
  // managing (administrators): the dialog to create, edit or copy, and the program being deleted
  const [dialog, setDialog] = React.useState<ProgramDialogMode | null>(null);
  const [deleting, setDeleting] = React.useState<Program | null>(null);
  const dialogOpener = React.useRef<HTMLElement | null>(null);
  const restoreFocus = () => {
    const back = dialogOpener.current;
    window.setTimeout(() => back?.isConnected && back.focus(), 0);
  };
  const openDialog = (mode: ProgramDialogMode, opener: HTMLElement) => {
    dialogOpener.current = opener;
    setDialog(mode);
  };

  async function remove(p: Program): Promise<string | null> {
    const name = text(p.name, strings);
    try {
      await deleteProgram(sid, p.id);
      setMessage({ text: t("programDeleted", { name }), failed: false });
      refresh();
      return null;
    } catch (e) {
      if (isSessionExpired(e)) {
        onExpired();
        return null;
      }
      const reason = describeChangeError(e, t);
      setMessage({ text: t("programChangeFailed", { name, reason }), failed: true });
      return reason;
    }
  }

  return (
    <Card className="space-y-4">
      <div>
        <CardTitle>{t("programs")}</CardTitle>
        <CardDescription>{mayRun ? t("programsControl") : t("readOnly")}</CardDescription>
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="program-filter">{t("filter")}</Label>
        <Input id="program-filter" type="search" value={query} placeholder={t("filterByName")} onChange={(e) => setQuery(e.target.value)} />
      </div>
      {/* The result of a run: announced to a screen reader, shown to everybody */}
      {maySwitch && (
        <div>
          <Button variant="outline" onClick={(e) => openDialog({ kind: "create" }, e.currentTarget)}>
            {t("newProgram")}
          </Button>
        </div>
      )}
      <div role="status" aria-live="polite">
        {message && <p className={message.failed ? "text-sm text-[var(--destructive)]" : "text-sm"}>{message.text}</p>}
      </div>
      {Boolean(error) && (
        <p role="alert" className="text-sm text-[var(--destructive)]">
          {describeError(error, t)}
        </p>
      )}
      {!loaded ? (
        <p className="text-sm text-[var(--muted-foreground)]">{t("loading")}</p>
      ) : !any ? (
        <p className="text-sm text-[var(--muted-foreground)]">{t("noPrograms")}</p>
      ) : shown.length === 0 ? (
        <p className="text-sm text-[var(--muted-foreground)]">{t("noMatchPrograms")}</p>
      ) : (
        <Table>
          <TableHead>
            <TableRow>
              <TableHeader>{t("name")}</TableHeader>
              <TableHeader className="hidden md:table-cell">{t("description")}</TableHeader>
              <TableHeader className="hidden sm:table-cell">{t("lastRun")}</TableHeader>
              <TableHeader>{t("programActive")}</TableHeader>
              {mayRun && <TableHeader className="text-right">{t("action")}</TableHeader>}
              {maySwitch && <TableHeader className="text-right">{t("actions")}</TableHeader>}
            </TableRow>
          </TableHead>
          <tbody>
            {shown.map((p) => (
              <TableRow key={p.id}>
                <TableCell>{text(p.name, strings)}</TableCell>
                <TableCell className="hidden md:table-cell">{text(p.description, strings)}</TableCell>
                <TableCell className="hidden whitespace-nowrap sm:table-cell">{neverRan(p) ? "—" : formatTime(p.lastExecuteTime, lang)}</TableCell>
                <TableCell>
                  {maySwitch ? (
                    <button
                      type="button"
                      role="switch"
                      aria-checked={p.isActive}
                      aria-label={t("programActiveSwitch", { name: text(p.name, strings) })}
                      disabled={running !== null}
                      onClick={(e) => (p.isActive ? void switchActive(p, false) : ((switchOpener.current = e.currentTarget), setActivating(p)))}
                      className={`relative h-6 w-11 rounded-full transition-colors disabled:opacity-50 ${p.isActive ? "bg-[var(--accent)]" : "bg-[var(--track)]"}`}
                    >
                      <span className={`absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition-transform ${p.isActive ? "translate-x-5" : ""}`} />
                    </button>
                  ) : (
                    <span>{p.isActive ? t("yes") : t("no")}</span>
                  )}
                </TableCell>
                {mayRun && (
                  <TableCell className="text-right">
                    <Button variant="outline" className="h-8 px-3" disabled={running !== null} onClick={() => void run(p)} aria-label={`${t("run")}: ${text(p.name, strings)}`}>
                      {running === p.id ? t("saving") : t("run")}
                    </Button>
                  </TableCell>
                )}
                {maySwitch && (
                  <TableCell className="whitespace-nowrap text-right">
                    <div className="flex justify-end gap-1">
                      <Button variant="outline" className="h-8 px-3" disabled={running !== null} onClick={(e) => openDialog({ kind: "edit", program: p }, e.currentTarget)} aria-label={`${t("editProgram")}: ${text(p.name, strings)}`}>
                        {t("editProgram")}
                      </Button>
                      <Button variant="outline" className="h-8 px-3" disabled={running !== null} onClick={(e) => openDialog({ kind: "copy", program: p, name: t("programCopyName", { name: p.name }).slice(0, 100) }, e.currentTarget)} aria-label={`${t("copyProgram")}: ${text(p.name, strings)}`}>
                        {t("copyProgram")}
                      </Button>
                      <Button
                        variant="destructive"
                        className="h-8 px-3"
                        disabled={running !== null}
                        onClick={(e) => {
                          dialogOpener.current = e.currentTarget;
                          setDeleting(p);
                        }}
                        aria-label={`${t("delete")}: ${text(p.name, strings)}`}
                      >
                        {t("delete")}
                      </Button>
                    </div>
                  </TableCell>
                )}
              </TableRow>
            ))}
          </tbody>
        </Table>
      )}
      {dialog && (
        <ProgramDialog
          mode={dialog}
          sid={sid}
          onExpired={onExpired}
          onClose={() => {
            setDialog(null);
            restoreFocus();
          }}
          onDone={(kind, saved) => {
            setMessage({ text: t(kind === "create" ? "programCreated" : kind === "copy" ? "programCopied" : "programSaved", { name: saved.name }), failed: false });
            setDialog(null);
            restoreFocus();
            refresh();
          }}
        />
      )}
      {deleting && (
        <ConfirmDialog
          title={t("programDeleteTitle")}
          message={`${text(deleting.name, strings)}: ${t("programDeleteWarning")}`}
          confirmLabel={t("delete")}
          onConfirm={() => remove(deleting)}
          onClose={() => {
            setDeleting(null);
            restoreFocus();
          }}
        />
      )}
      {activating && (
        <ConfirmDialog
          title={t("programActivateTitle")}
          message={`${text(activating.name, strings)}: ${t("programActivateWarning")}`}
          confirmLabel={t("programActivate")}
          tone="default"
          onConfirm={() => switchActive(activating, true)}
          onClose={() => {
            setActivating(null);
            const back = switchOpener.current;
            window.setTimeout(() => back?.isConnected && back.focus(), 0);
          }}
        />
      )}
    </Card>
  );
}
