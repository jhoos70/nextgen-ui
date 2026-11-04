import type { Program } from "./api";

/** The programs the classic status page lists: those users may operate, not the copies of the editor, not the system's own. */
export const isListed = (p: Program): boolean => p.isOperable && !p.isCopy && !p.isInternal;

/** "" for a program that never ran (the epoch), as the classic list shows a dash there. */
export const neverRan = (p: Program): boolean => p.lastExecuteTime === "" || p.lastExecuteTime.startsWith("1970-");

/** The programs an administrator manages: all but the editor's copies and the system's own, whether users may operate them or not. */
export const isManageable = (p: Program): boolean => !p.isCopy && !p.isInternal;

/** A program name the server accepts: 1 to 100 characters, no control characters, no space at the start or end. */
export const PROGRAM_NAME_MAX = 100;
export const PROGRAM_INFO_MAX = 1000;
export const isValidProgramName = (name: string): boolean => name.length > 0 && name === name.trim() && name.length <= PROGRAM_NAME_MAX && !/[\u0000-\u001f\u007f]/.test(name);

/** Programs whose name or description contains every word of the query (case-insensitive), by name in the user's language. `manage` lists what an administrator manages instead of what users operate. */
export function filterPrograms(programs: Program[], query: string, lang: string, manage = false): Program[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  return programs
    .filter((p) => (manage ? isManageable(p) : isListed(p)) && words.every((w) => `${p.name} ${p.description}`.toLowerCase().includes(w)))
    .sort((a, b) => a.name.localeCompare(b.name, lang, { numeric: true }));
}
