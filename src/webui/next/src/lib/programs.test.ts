import { describe, expect, it } from "vitest";
import { ApiError, describeChangeError, makeCopyProgram, makeCreateProgram, makeDeleteProgram, makeExecuteProgram, makeSetProgramActive, makeUpdateProgram, type Program } from "./api";
import { translate, type Translate } from "./i18n";
import { filterPrograms, isListed, isManageable, isValidProgramName, neverRan } from "./programs";

const p = (o: Partial<Program>): Program => ({ id: "1", name: "P", description: "", lastExecuteTime: "2026-10-31 21:00:00", isActive: true, isInternal: false, isOperable: true, isCopy: false, isVisible: true, ...o });

describe("isListed", () => {
  it("lists what the classic status page lists: operable programs that are not copies (and not the system's own)", () => {
    expect(isListed(p({}))).toBe(true);
    expect(isListed(p({ isOperable: false }))).toBe(false);
    expect(isListed(p({ isCopy: true }))).toBe(false);
    expect(isListed(p({ isInternal: true }))).toBe(false);
  });
  it("lists an inactive program too (it can be run by hand)", () => {
    expect(isListed(p({ isActive: false }))).toBe(true);
  });
});

describe("neverRan", () => {
  it("knows the epoch and an empty time as never", () => {
    expect([neverRan(p({ lastExecuteTime: "1970-01-01 01:00:00" })), neverRan(p({ lastExecuteTime: "" })), neverRan(p({}))]).toEqual([true, true, false]);
  });
});

describe("filterPrograms", () => {
  const list = [p({ id: "1", name: "Licht 10", description: "Abends" }), p({ id: "2", name: "Licht 2", description: "Morgens an" }), p({ id: "3", name: "Heizung", isOperable: false }), p({ id: "4", name: "Rollo", description: "licht aus" })];
  it("sorts by name in the user's order (numbers numerically) and leaves out what is not listed", () => {
    expect(filterPrograms(list, "", "de").map((x) => x.name)).toEqual(["Licht 2", "Licht 10", "Rollo"]);
  });
  it("needs every word in the name or the description", () => {
    expect(filterPrograms(list, "licht abends", "de").map((x) => x.id)).toEqual(["1"]);
    expect(filterPrograms(list, "LICHT", "de").map((x) => x.id)).toEqual(["2", "1", "4"]);
    expect(filterPrograms(list, "heizung", "de")).toEqual([]);
  });
});

describe("executeProgram", () => {
  const t: Translate = (k, q) => translate("en", k, q);
  const ok = { id: "1053", executed: true, lastExecuteTime: "2026-10-31 21:08:40" };
  it("posts {id, execute: true} with the session and returns what ReGa reports", async () => {
    let url = "", init: RequestInit | undefined;
    const run = makeExecuteProgram(async (u, i) => ((url = String(u)), (init = i), new Response(JSON.stringify(ok))));
    expect(await run("AbCdEf1234", "1053")).toEqual(ok);
    expect(url).toBe("/api/homematic.cgi/v2/programs");
    expect([init!.method, init!.body]).toEqual(["POST", '{"id":"1053","execute":true}']);
    expect((init!.headers as Record<string, string>)["X-Session-Id"]).toBe("AbCdEf1234");
  });
  it("reports a program that did not run (executed false) as an answer, not an error", async () => {
    expect((await makeExecuteProgram(async () => new Response(JSON.stringify({ ...ok, executed: false })))("s", "1")).executed).toBe(false);
  });
  it("turns the server's refusals into the words of a change", async () => {
    const fail = (status: number) => makeExecuteProgram(async () => new Response(JSON.stringify({ error: { code: 400, message: "x" } }), { status }))("s", "1").catch((e) => e);
    expect(describeChangeError(await fail(403), t)).toBe(t("errNotAllowed"));
    expect(describeChangeError(await fail(404), t)).toBe(t("errGone"));
    expect(describeChangeError(new ApiError(0, "x", 0), t)).toBe(t("errUnreachable"));
  });
  it("rejects an answer without executed", async () => {
    await expect(makeExecuteProgram(async () => new Response("{}"))("s", "1")).rejects.toBeInstanceOf(ApiError);
  });
});


describe("switching a program on or off", () => {
  const t: Translate = (k, p) => translate("en", k, p);
  it("posts id and a boolean and returns the flag the CCU holds", async () => {
    let init: RequestInit | undefined;
    let url = "";
    const set = makeSetProgramActive(async (u, i) => ((url = String(u)), (init = i), new Response(JSON.stringify({ id: "7", isActive: false }))));
    expect(await set("sid", "7", false)).toEqual({ id: "7", isActive: false });
    expect(url).toContain("/programs");
    expect(JSON.parse(String(init?.body))).toEqual({ id: "7", active: false });
  });
  it("tells that only an administrator may (403) and that the program is gone (404)", async () => {
    const refused = await makeSetProgramActive(async () => new Response(JSON.stringify({ error: { code: 400, message: "access denied" } }), { status: 403 }))("sid", "7", true).catch((e) => e);
    const gone = await makeSetProgramActive(async () => new Response(JSON.stringify({ error: { code: 501, message: "program not found" } }), { status: 404 }))("sid", "7", true).catch((e) => e);
    expect(refused).toBeInstanceOf(ApiError);
    expect(describeChangeError(refused, t)).toBe("You are not allowed to do this.");
    expect(describeChangeError(gone, t)).toBe("This item does not exist any more.");
  });
  it("rejects an answer without the flag", async () => {
    await expect(makeSetProgramActive(async () => new Response(JSON.stringify({ id: "7" })))("sid", "7", true)).rejects.toBeInstanceOf(ApiError);
  });
});

describe("managing programs", () => {
  it("lists for an administrator what is not a copy and not the system's own, operable or not", () => {
    const list = [p({ id: "1", name: "B" }), p({ id: "2", name: "A", isOperable: false }), p({ id: "3", isCopy: true }), p({ id: "4", isInternal: true })];
    expect(isManageable(list[1])).toBe(true);
    expect(filterPrograms(list, "", "de", true).map((x) => x.id)).toEqual(["2", "1"]);
    expect(filterPrograms(list, "", "de").map((x) => x.id)).toEqual(["1"]);
  });
  it("accepts the names the server accepts", () => {
    expect([isValidProgramName("Licht an"), isValidProgramName(""), isValidProgramName(" x"), isValidProgramName("x "), isValidProgramName("a\nb"), isValidProgramName("x".repeat(100)), isValidProgramName("x".repeat(101))]).toEqual([true, false, false, false, false, true, false]);
  });

  const managed = { id: "2001", name: "Neu", description: "Text", isActive: false, isVisible: true, isOperable: false };
  it("creates a program: POST {create, name, description}", async () => {
    let url = "", init: RequestInit | undefined;
    const out = await makeCreateProgram(async (u, i) => ((url = String(u)), (init = i), new Response(JSON.stringify(managed))))("AbCdEf1234", "Neu", "Text");
    expect([url, init!.method, JSON.parse(String(init!.body))]).toEqual(["/api/homematic.cgi/v2/programs", "POST", { create: true, name: "Neu", description: "Text" }]);
    expect(out).toEqual(managed);
  });
  it("leaves an empty description out of the request", async () => {
    let init: RequestInit | undefined;
    await makeCreateProgram(async (_u, i) => ((init = i), new Response(JSON.stringify(managed))))("x", "Neu");
    expect(JSON.parse(String(init!.body))).toEqual({ create: true, name: "Neu" });
  });
  it("copies: POST {id, copy, name}", async () => {
    let init: RequestInit | undefined;
    await makeCopyProgram(async (_u, i) => ((init = i), new Response(JSON.stringify(managed))))("x", "7", "Kopie");
    expect(JSON.parse(String(init!.body))).toEqual({ id: "7", copy: true, name: "Kopie" });
  });
  it("changes only what is given: PUT {id, ...fields}", async () => {
    let init: RequestInit | undefined;
    const out = await makeUpdateProgram(async (_u, i) => ((init = i), new Response(JSON.stringify(managed))))("x", "7", { isVisible: false });
    expect([init!.method, JSON.parse(String(init!.body))]).toEqual(["PUT", { id: "7", isVisible: false }]);
    expect(out.id).toBe("2001");
  });
  it("deletes: DELETE ?id=", async () => {
    let url = "", init: RequestInit | undefined;
    const out = await makeDeleteProgram(async (u, i) => ((url = String(u)), (init = i), new Response('{"id":"7","deleted":true}')))("x", "7");
    expect([url, init!.method, out]).toEqual(["/api/homematic.cgi/v2/programs?id=7", "DELETE", { id: "7", deleted: true }]);
  });
  it("refuses an answer that is not a program, and passes a refusal on", async () => {
    await expect(makeCreateProgram(async () => new Response("{}"))("x", "Neu")).rejects.toBeInstanceOf(ApiError);
    await expect(makeDeleteProgram(async () => new Response("{}"))("x", "7")).rejects.toBeInstanceOf(ApiError);
    const refused = makeUpdateProgram(async () => new Response(JSON.stringify({ error: { code: 404, message: "name already in use" } }), { status: 409 }));
    await expect(refused("x", "7", { name: "T" })).rejects.toMatchObject({ status: 409 });
  });
  it("tells a name that is taken from other refusals", () => {
    const t = ((k: string) => k) as Translate;
    expect(describeChangeError(new ApiError(404, "name already in use", 409), t)).toBe("errNameInUse");
  });
});
