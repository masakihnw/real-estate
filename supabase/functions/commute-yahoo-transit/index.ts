import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OFFICES: Record<string, { address: string; name: string }> = {
  playground: { address: "千代田区（勤務地）", name: "オフィスA" },
  m3career: { address: "港区虎ノ門4-1-28", name: "オフィスB株式会社" },
};

const BATCH_SIZE = 20;
const MAX_MINUTES = 120;
const REQUEST_DELAY_MS = 2000;

interface CommuteResult {
  minutes: number;
  summary: string;
  transfers: number;
}

function getNextWeekdayDate(): string {
  const now = new Date();
  const jst = new Date(now.getTime() + 9 * 3600000);
  const day = jst.getUTCDay();
  let add = 1;
  if (day === 5) add = 3;
  if (day === 6) add = 2;
  if (day === 0) add = 1;
  const next = new Date(jst.getTime() + add * 86400000);
  const y = next.getUTCFullYear();
  const m = String(next.getUTCMonth() + 1).padStart(2, "0");
  const d = String(next.getUTCDate()).padStart(2, "0");
  return `${y}${m}${d}`;
}

async function fetchCommuteTime(
  fromAddress: string,
  toAddress: string,
  date: string,
): Promise<CommuteResult | null> {
  const url = new URL("https://transit.yahoo.co.jp/search/result");
  url.searchParams.set("from", fromAddress);
  url.searchParams.set("to", toAddress);
  url.searchParams.set("type", "4");
  url.searchParams.set("dt", date);
  url.searchParams.set("tm", "0900");

  const res = await fetch(url.toString(), {
    headers: {
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
      "Accept-Language": "ja",
    },
  });

  if (!res.ok) return null;

  const html = await res.text();

  const routeMatch = html.match(
    /id="route01"(.*?)(?:id="route02"|id="routeDetail")/s,
  );
  if (!routeMatch) return null;

  const section = routeMatch[1];

  const summaryMatch = section.match(
    /class="summary"[^>]*>(.*?)<\/li>/s,
  );
  if (!summaryMatch) return null;

  const summaryText = summaryMatch[1].replace(/<[^>]+>/g, " ").trim();

  let minutes: number | null = null;
  const hourMinMatch = summaryText.match(/(\d+)時間(\d+)分/);
  if (hourMinMatch) {
    minutes = parseInt(hourMinMatch[1]) * 60 + parseInt(hourMinMatch[2]);
  } else {
    const minMatch = summaryText.match(/(\d+)分/);
    if (minMatch) {
      minutes = parseInt(minMatch[1]);
    }
  }

  if (minutes === null || minutes > MAX_MINUTES) return null;

  const transferMatch = section.match(/乗換[：:](\d+)回/);
  const transfers = transferMatch ? parseInt(transferMatch[1]) : 0;

  const depArr = summaryText.match(/(\d{1,2}:\d{2})\s*発.*?(\d{1,2}:\d{2})\s*着/);
  const routeDesc = depArr
    ? `Yahoo路線情報 (${depArr[1]}発→${depArr[2]}着, 乗換${transfers}回)`
    : `Yahoo路線情報 (朝9:00到着, 乗換${transfers}回)`;

  return { minutes, summary: routeDesc, transfers };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Missing authorization" }), {
      status: 401,
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  let batchSize = BATCH_SIZE;
  try {
    const body = await req.json();
    if (body.batch_size) batchSize = Math.min(body.batch_size, 50);
  } catch {
    // use defaults
  }

  const { data: listings, error: queryError } = await supabase.rpc(
    "get_commute_targets",
    { p_limit: batchSize },
  );

  if (queryError) {
    return new Response(JSON.stringify({ error: queryError.message }), {
      status: 500,
    });
  }

  if (!listings || listings.length === 0) {
    return new Response(
      JSON.stringify({ message: "No listings to process", processed: 0 }),
    );
  }

  const date = getNextWeekdayDate();
  const results: Array<{
    id: number;
    name: string;
    playground: number | null;
    m3career: number | null;
    status: string;
  }> = [];

  for (const listing of listings) {
    const commuteInfo: Record<string, unknown> = {};
    let pgMin: number | null = null;
    let m3Min: number | null = null;

    for (const [key, office] of Object.entries(OFFICES)) {
      const result = await fetchCommuteTime(
        listing.ss_address,
        office.address,
        date,
      );

      if (result) {
        commuteInfo[key] = {
          minutes: result.minutes,
          summary: result.summary,
          calculatedAt: new Date().toISOString(),
          source: "yahoo_transit",
          transfers: result.transfers,
        };
        if (key === "playground") pgMin = result.minutes;
        if (key === "m3career") m3Min = result.minutes;
      }

      await sleep(REQUEST_DELAY_MS);
    }

    if (Object.keys(commuteInfo).length > 0) {
      const { error: updateError } = await supabase
        .from("enrichments")
        .update({ commute_info: commuteInfo })
        .eq("listing_id", listing.id);

      results.push({
        id: listing.id,
        name: listing.name,
        playground: pgMin,
        m3career: m3Min,
        status: updateError ? `ERROR: ${updateError.message}` : "OK",
      });
    } else {
      results.push({
        id: listing.id,
        name: listing.name,
        playground: null,
        m3career: null,
        status: "SKIP (no route found)",
      });
    }
  }

  const succeeded = results.filter((r) => r.status === "OK").length;
  const skipped = results.filter((r) => r.status.startsWith("SKIP")).length;
  const errors = results.filter((r) => r.status.startsWith("ERROR")).length;

  return new Response(
    JSON.stringify({
      date,
      total: results.length,
      succeeded,
      skipped,
      errors,
      results,
    }),
    { headers: { "Content-Type": "application/json" } },
  );
});
