// The navigation of the new UI, object-centric: one entry per object (devices, rooms, ...) where the classic
// menu has a status page under "Status and control" and an editor under "Settings". Each entry lists the classic
// menu entries it replaces (menu/submenu ids of www/webui/js/mainmenu/{admin,user}.js); nav.test.ts reads the
// real files, so every classic entry is either mapped here or dropped on purpose, and the level an entry needs
// is the one the classic menu gives it. Entries that are not built yet stay here (ready: false) and are not shown.
import type { Level } from "./api";
import type { MessageKey } from "./messages";

export type Group = "objects" | "system";
export type MinLevel = "USER" | "ADMIN";

interface Base {
  id: string;
  group: Group;
  /** The lowest user level that sees the entry (the classic menu decides, see nav.test.ts). */
  minLevel: MinLevel;
  /** The classic menu entries it replaces: "menu/submenu", or "menu" for a top-level action. Empty: new in this UI (none yet). */
  classic: readonly string[];
}
export type NavItem = (Base & { ready: true; labelKey: MessageKey }) | (Base & { ready: false });

export const NAV: readonly NavItem[] = [
  { id: "overview", group: "objects", minLevel: "USER", classic: ["menuStartPage"], ready: true, labelKey: "overview" },
  { id: "favourites", group: "objects", minLevel: "USER", classic: ["menuControlPage/submenuFavorites", "menuSettingsPage/submenuFavorites"], ready: true, labelKey: "favourites" },
  { id: "rooms", group: "objects", minLevel: "USER", classic: ["menuControlPage/submenuRooms", "menuSettingsPage/submenuRooms"], ready: true, labelKey: "rooms" },
  { id: "devices", group: "objects", minLevel: "USER", classic: ["menuControlPage/submenuDevices", "menuSettingsPage/submenuDevices"], ready: true, labelKey: "devices" },
  { id: "groups", group: "objects", minLevel: "ADMIN", classic: ["menuSettingsPage/submenuCreateGroups"], ready: true, labelKey: "groups" },
  { id: "functions", group: "objects", minLevel: "USER", classic: ["menuControlPage/submenuFunction", "menuSettingsPage/submenuFunction"], ready: true, labelKey: "functions" },
  { id: "programs", group: "objects", minLevel: "USER", classic: ["menuControlPage/submenuPrograms", "menuProgramsLinksPage/submenuProgramsLinks"], ready: true, labelKey: "programs" },
  { id: "sysvars", group: "objects", minLevel: "USER", classic: ["menuControlPage/submenuSysVar", "menuSettingsPage/submenuSysVar"], ready: true, labelKey: "sysvars" },
  { id: "diagrams", group: "objects", minLevel: "USER", classic: ["menuControlPage/submenuDiagramListPage", "menuSettingsPage/submenuCreateDiagram"], ready: false },
  { id: "connections", group: "objects", minLevel: "ADMIN", classic: ["menuProgramsLinksPage/submenuDirectLinks"], ready: false },
  // new in upstream Base (HMScriptExecutor, 2026-11): the classic "run a script" dialog for administrators
  { id: "scripts", group: "objects", minLevel: "ADMIN", classic: ["menuProgramsLinksPage/submenuScriptExecutor"], ready: false },
  { id: "log", group: "system", minLevel: "USER", classic: ["menuControlPage/submenuSysProtocol"], ready: true, labelKey: "log" },
  // adding devices: the inbox of new devices and the teach-in action of the classic header
  { id: "inbox", group: "system", minLevel: "ADMIN", classic: ["menuSettingsPage/submenuDeviceInbox", "menuNewDevicesPage"], ready: false },
  { id: "firmware", group: "system", minLevel: "ADMIN", classic: ["menuSettingsPage/submenuDeviceFirmwareInformation"], ready: false },
  { id: "users", group: "system", minLevel: "USER", classic: ["menuSettingsPage/submenuUserManagement"], ready: false },
  { id: "control", group: "system", minLevel: "ADMIN", classic: ["menuSettingsPage/submenuSysControl"], ready: false },
  // the classic Help page is the system information (version, uptime, addresses): an "About" of the user menu later
  { id: "about", group: "system", minLevel: "USER", classic: ["menuHelpPage"], ready: false },
];

/** The top-level classic entries that only open a landing page of cards; the object entries above replace them. */
export const CLASSIC_LANDING_PAGES: readonly string[] = ["menuControlPage", "menuProgramsLinksPage", "menuSettingsPage"];

const RANK: Record<Level, number> = { NONE: 0, GUEST: 1, USER: 2, ADMIN: 8 };
export const canSee = (item: { minLevel: MinLevel }, level: Level): boolean => RANK[level] >= RANK[item.minLevel];

export interface NavGroup {
  group: Group;
  items: (NavItem & { ready: true })[];
}

export interface NavView {
  groups: NavGroup[];
  /** True when the user's level has entries that are not built yet: the nav then points to the classic UI. */
  hasMore: boolean;
}

export interface NavCustomConfig {
  order?: string[];
  hidden?: string[];
}

/** What the user sees: the built entries of the user's level, in groups; guests get nothing (the classic menu has none). */
export function navFor(level: Level, custom?: NavCustomConfig | null): NavView {
  const visible = NAV.filter((i) => canSee(i, level));
  let ready = visible.filter((i): i is NavItem & { ready: true } => i.ready);

  if (custom) {
    if (custom.hidden && custom.hidden.length > 0) {
      const hiddenSet = new Set(custom.hidden);
      ready = ready.filter((i) => i.id === "overview" || !hiddenSet.has(i.id));
    }
    if (custom.order && custom.order.length > 0) {
      const orderMap = new Map(custom.order.map((id, idx) => [id, idx]));
      ready.sort((a, b) => {
        const aIdx = orderMap.has(a.id) ? orderMap.get(a.id)! : 999;
        const bIdx = orderMap.has(b.id) ? orderMap.get(b.id)! : 999;
        return aIdx - bIdx;
      });
    }
  }

  return {
    groups: (["objects", "system"] as const)
      .map((group) => ({ group, items: ready.filter((i) => i.group === group) }))
      .filter((g) => g.items.length > 0),
    hasMore: visible.some((i) => !i.ready),
  };
}

export const READY_IDS: readonly string[] = NAV.filter((i) => i.ready).map((i) => i.id);

/** The pages the header indicators open. They are not in the navigation: the classic UI reaches them only from its header. */
export const INDICATOR_ROUTES: readonly string[] = ["alarms", "services"];

/** The classic header shows the alarm and service counters to everyone but guests. */
export const showsIndicators = (level: Level): boolean => level === "USER" || level === "ADMIN";
