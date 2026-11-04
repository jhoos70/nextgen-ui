import * as React from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { copyProgram, createProgram, describeChangeError, isSessionExpired, updateProgram, type ManagedProgram, type Program } from "@/lib/api";
import { useI18n } from "@/lib/i18n";
import { isValidProgramName, PROGRAM_INFO_MAX, PROGRAM_NAME_MAX } from "@/lib/programs";

export type ProgramDialogMode = { kind: "create" } | { kind: "edit"; program: Program } | { kind: "copy"; program: Program; name: string };

/** Creates an empty program, changes the name, description and flags of one, or copies one under a new name (administrators). */
export function ProgramDialog({ mode, sid, onClose, onDone, onExpired }: { mode: ProgramDialogMode; sid: string; onClose: () => void; onDone: (kind: ProgramDialogMode["kind"], program: ManagedProgram) => void; onExpired: () => void }) {
  const { t } = useI18n();
  const editing = mode.kind === "edit" ? mode.program : null;
  const [name, setName] = React.useState(mode.kind === "copy" ? mode.name : (editing?.name ?? ""));
  const [info, setInfo] = React.useState(editing?.description ?? "");
  const [visible, setVisible] = React.useState(editing?.isVisible ?? true);
  const [operable, setOperable] = React.useState(editing?.isOperable ?? false);
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState("");

  const validName = isValidProgramName(name);
  const validInfo = info.length <= PROGRAM_INFO_MAX;
  const title = mode.kind === "create" ? t("newProgramTitle") : mode.kind === "copy" ? t("copyProgramTitle") : t("editProgramTitle");

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!validName || !validInfo || busy) return;
    setBusy(true);
    setError("");
    try {
      let saved: ManagedProgram;
      if (mode.kind === "create") saved = await createProgram(sid, name, info);
      else if (mode.kind === "copy") saved = await copyProgram(sid, mode.program.id, name);
      else {
        const p = mode.program;
        // only what changed is sent: a rename is checked against the other objects, the rest is not
        saved = await updateProgram(sid, p.id, {
          ...(name !== p.name ? { name } : {}),
          ...(info !== p.description ? { description: info } : {}),
          ...(visible !== p.isVisible ? { isVisible: visible } : {}),
          ...(operable !== p.isOperable ? { isOperable: operable } : {}),
        });
      }
      onDone(mode.kind, saved);
    } catch (err) {
      if (isSessionExpired(err)) return onExpired();
      setError(describeChangeError(err, t));
      setBusy(false);
    }
  }

  const unchanged = editing !== null && name === editing.name && info === editing.description && visible === editing.isVisible && operable === editing.isOperable;

  return (
    <Dialog.Root open onOpenChange={(open) => !open && !busy && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/50 backdrop-blur-xs" />
        <Dialog.Content
          aria-describedby={undefined}
          className="fixed left-1/2 top-1/2 z-50 max-h-[calc(100vh-2rem)] w-[min(30rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-lg border border-[var(--border)] bg-[var(--card)] p-6 text-[var(--foreground)] shadow-lg"
        >
          <form onSubmit={(e) => void submit(e)} className="space-y-4">
            <Dialog.Title className="text-lg font-semibold">{title}</Dialog.Title>
            <div className="space-y-1.5">
              <Label htmlFor="program-name">{t("name")}</Label>
              <Input id="program-name" value={name} maxLength={PROGRAM_NAME_MAX + 20} autoFocus onChange={(e) => setName(e.target.value)} aria-invalid={name.length > 0 && !validName} />
              {name.length > 0 && !validName && (
                <p role="alert" className="text-sm text-[var(--destructive)]">
                  {t("errProgramName")}
                </p>
              )}
            </div>
            {mode.kind !== "copy" && (
              <div className="space-y-1.5">
                <Label htmlFor="program-info">{t("description")}</Label>
                <Input id="program-info" value={info} onChange={(e) => setInfo(e.target.value)} aria-invalid={!validInfo} />
              </div>
            )}
            {editing && (
              <div className="space-y-2 text-sm">
                <label className="flex items-center gap-2">
                  <input type="checkbox" checked={visible} onChange={(e) => setVisible(e.target.checked)} />
                  {t("programVisible")}
                </label>
                <label className="flex items-center gap-2">
                  <input type="checkbox" checked={operable} onChange={(e) => setOperable(e.target.checked)} />
                  {t("programOperable")}
                </label>
              </div>
            )}
            {mode.kind !== "copy" && <p className="text-xs text-[var(--muted-foreground)]">{t("programEditNote")}</p>}
            {error && (
              <p role="alert" className="text-sm text-[var(--destructive)]">
                {error}
              </p>
            )}
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={onClose} disabled={busy}>
                {t("cancel")}
              </Button>
              <Button type="submit" disabled={busy || !validName || !validInfo || unchanged}>
                {busy ? t("saving") : t("ok")}
              </Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
