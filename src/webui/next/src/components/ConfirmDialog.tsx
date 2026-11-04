import * as React from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { Button } from "@/components/ui/button";
import { useI18n } from "@/lib/i18n";

/** Asks before something that cannot be undone, or that does more than it looks like (tone "default": not a red button). Cancel and Escape close it; a failure stays in the dialog. */
export function ConfirmDialog({ title, message, confirmLabel, tone = "destructive", onConfirm, onClose, raised = false }: { title: string; message: string; confirmLabel: string; tone?: "destructive" | "default"; onConfirm: () => Promise<string | null>; onClose: () => void; raised?: boolean }) {
  const { t } = useI18n();
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState("");

  async function confirm() {
    setBusy(true);
    setError("");
    const failure = await onConfirm();
    if (failure === null) return onClose();
    setError(failure);
    setBusy(false);
  }

  return (
    <Dialog.Root open onOpenChange={(open) => !open && !busy && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className={`fixed inset-0 bg-black/50 backdrop-blur-xs ${raised ? "z-[80]" : "z-40"}`} />
        <Dialog.Content aria-describedby="confirm-message" className={`fixed left-1/2 top-1/2 ${raised ? "z-[90]" : "z-50"} w-[min(26rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 rounded-lg bg-[var(--card)] text-[var(--foreground)] p-6 shadow-lg border border-[var(--border)]`}>
          <div className="space-y-4">
            <Dialog.Title className="text-lg font-semibold">{title}</Dialog.Title>
            <p id="confirm-message" className="text-sm">
              {message}
            </p>
            {error && (
              <p role="alert" className="text-sm text-[var(--destructive)]">
                {error}
              </p>
            )}
            <div className="flex justify-end gap-2">
              {/* Cancel first and focused: a stray Enter does not delete anything */}
              <Button type="button" variant="outline" onClick={onClose} disabled={busy} autoFocus>
                {t("cancel")}
              </Button>
              <Button type="button" variant={tone === "destructive" ? "destructive" : "default"} onClick={() => void confirm()} disabled={busy}>
                {busy ? t("saving") : confirmLabel}
              </Button>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
