import { headers } from "next/headers";

// Always render fresh — the form submits via query string.
export const dynamic = "force-dynamic";

type Result =
  | { ok: true; access_token: string; expires_in: number }
  | { ok: false; status: number; error: string };

async function testRoute(userId: string): Promise<Result> {
  const h = await headers();
  const host = h.get("host") ?? "localhost:3000";
  const proto = h.get("x-forwarded-proto") ?? "http";

  const res = await fetch(`${proto}://${host}/api/user-token`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: userId }),
    cache: "no-store",
  });

  const data = (await res.json()) as Record<string, unknown>;
  if (!res.ok) {
    return {
      ok: false,
      status: res.status,
      error: String(data.error ?? "Unknown error"),
    };
  }
  return {
    ok: true,
    access_token: String(data.access_token),
    expires_in: Number(data.expires_in),
  };
}

export default async function Home({
  searchParams,
}: {
  searchParams: Promise<{ user_id?: string }>;
}) {
  const { user_id } = await searchParams;
  const tooShort = user_id !== undefined && user_id.length < 6;
  const result = user_id && !tooShort ? await testRoute(user_id) : null;

  return (
    <div className="flex flex-col flex-1 items-center justify-center bg-zinc-50 font-sans dark:bg-black">
      <main className="flex w-full max-w-xl flex-col gap-8 py-24 px-8">
        <div className="flex flex-col gap-2">
          <h1 className="text-2xl font-semibold tracking-tight text-black dark:text-zinc-50">
            Mint user token
          </h1>
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            Submits a <code>user_id</code> to <code>POST /api/user-token</code>.
          </p>
        </div>

        <form method="get" className="flex flex-col gap-3 sm:flex-row">
          <input
            type="text"
            name="user_id"
            defaultValue={user_id ?? ""}
            placeholder="user_id"
            required
            minLength={6}
            className="flex-1 rounded-md border border-black/[.12] bg-white px-3 py-2 text-sm text-black outline-none focus:border-black/40 dark:border-white/[.18] dark:bg-zinc-900 dark:text-zinc-50"
          />
          <button
            type="submit"
            className="rounded-md bg-foreground px-5 py-2 text-sm font-medium text-background transition-colors hover:bg-[#383838] dark:hover:bg-[#ccc]"
          >
            Mint token
          </button>
        </form>

        {tooShort && (
          <div className="rounded-md border border-red-600/30 bg-red-50 p-4 text-sm dark:bg-red-950/30">
            <p className="font-medium text-red-800 dark:text-red-300">
              user_id must be at least 6 characters
            </p>
          </div>
        )}

        {result && (
          <div
            className={`flex flex-col gap-2 rounded-md border p-4 text-sm ${
              result.ok
                ? "border-green-600/30 bg-green-50 dark:bg-green-950/30"
                : "border-red-600/30 bg-red-50 dark:bg-red-950/30"
            }`}
          >
            {result.ok ? (
              <>
                <p className="font-medium text-green-800 dark:text-green-300">
                  Success — expires in {result.expires_in}s
                </p>
                <pre className="overflow-x-auto whitespace-pre-wrap break-all text-xs text-zinc-700 dark:text-zinc-300">
                  {result.access_token}
                </pre>
              </>
            ) : (
              <p className="font-medium text-red-800 dark:text-red-300">
                Error {result.status}: {result.error}
              </p>
            )}
          </div>
        )}
      </main>
    </div>
  );
}
