import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface ImageEntry {
  url: string;
  label: string;
}

interface ClassifiedImage {
  url: string;
  label: string;
  category: string;
  is_junk: boolean;
  quality_score: number;
  thumbnail_score: number;
  brief_description: string;
}

interface CategoryRule {
  category: string;
  patterns: string[];
  is_junk: boolean;
  quality_score: number;
  thumbnail_score: number;
}

const CATEGORY_RULES: CategoryRule[] = [
  {
    category: "floor_plan",
    patterns: ["間取図", "間取り"],
    is_junk: false,
    quality_score: 0.8,
    thumbnail_score: 0.25,
  },
  {
    category: "exterior",
    patterns: ["外観", "エントランス"],
    is_junk: false,
    quality_score: 0.7,
    thumbnail_score: 0.85,
  },
  {
    category: "interior",
    patterns: [
      "室内",
      "リビング",
      "居室",
      "キッチン",
      "ダイニング",
      "和室",
      "洋室",
      "LDK",
      "DK",
    ],
    is_junk: false,
    quality_score: 0.7,
    thumbnail_score: 0.8,
  },
  {
    category: "water",
    patterns: ["浴室", "バス", "トイレ", "洗面", "水回り", "脱衣"],
    is_junk: false,
    quality_score: 0.5,
    thumbnail_score: 0.5,
  },
  {
    category: "view",
    patterns: ["眺望", "バルコニー", "ベランダ", "展望"],
    is_junk: false,
    quality_score: 0.6,
    thumbnail_score: 0.6,
  },
  {
    category: "common_area",
    patterns: [
      "共用部",
      "エントランスホール",
      "中庭",
      "ロビー",
      "ジム",
      "ラウンジ",
    ],
    is_junk: false,
    quality_score: 0.5,
    thumbnail_score: 0.5,
  },
  {
    category: "surroundings",
    patterns: ["周辺", "公園", "学校", "スーパー", "商業", "駅前"],
    is_junk: false,
    quality_score: 0.4,
    thumbnail_score: 0.4,
  },
];

function classifyImage(image: ImageEntry): ClassifiedImage {
  const label = image.label || "";

  for (const rule of CATEGORY_RULES) {
    if (rule.patterns.some((p) => label.includes(p))) {
      return {
        url: image.url,
        label,
        category: rule.category,
        is_junk: false,
        quality_score: rule.quality_score,
        thumbnail_score: rule.thumbnail_score,
        brief_description: label,
      };
    }
  }

  return {
    url: image.url,
    label,
    category: "junk",
    is_junk: true,
    quality_score: 0.1,
    thumbnail_score: 0.1,
    brief_description: label || "unclassified",
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  let batchSize = 200;
  try {
    const body = await req.json();
    if (body.batch_size) batchSize = Math.min(body.batch_size, 500);
  } catch {
    // use defaults
  }

  const { data: prompt, error: promptError } = await supabase.rpc(
    "get_active_prompt",
    { p_module: "image_analyzer" },
  );

  if (promptError) {
    return new Response(
      JSON.stringify({ error: `get_active_prompt failed: ${promptError.message}` }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const promptHash = prompt?.[0]?.prompt_hash ?? "edge-function";
  const promptVersion = prompt?.[0]?.version ?? 1;

  const { data: listings, error: listingsError } = await supabase.rpc(
    "get_listings_for_ai",
    { p_module: "image_analyzer", p_config: { max_items_per_run: batchSize } },
  );

  if (listingsError) {
    return new Response(
      JSON.stringify({ error: `get_listings_for_ai failed: ${listingsError.message}` }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  if (!listings || listings.length === 0) {
    return new Response(
      JSON.stringify({ message: "No listings to process", processed: 0 }),
      { headers: { "Content-Type": "application/json" } },
    );
  }

  let totalImages = 0;
  let totalJunk = 0;
  let succeeded = 0;
  let errors = 0;
  const errorDetails: Array<{ listing_id: number; error: string }> = [];

  for (const row of listings) {
    const data = row.listing_data;
    const images: ImageEntry[] = data.suumo_images || [];
    const classified = images.map(classifyImage);

    totalImages += classified.length;
    totalJunk += classified.filter((c) => c.is_junk).length;

    const { error: upsertError } = await supabase.rpc(
      "upsert_ai_enrichment",
      {
        p_listing_id: row.listing_id,
        p_module: "image_analyzer",
        p_result: classified,
        p_model: "edge-function-label-match",
        p_prompt_hash: promptHash,
        p_prompt_version: promptVersion,
        p_source: "edge_function",
      },
    );

    if (upsertError) {
      errors++;
      errorDetails.push({
        listing_id: row.listing_id,
        error: upsertError.message,
      });
    } else {
      succeeded++;
    }
  }

  let junkRemoved = 0;
  const { data: cleanupResult, error: cleanupError } = await supabase.rpc(
    "batch_cleanup_junk_images",
  );

  if (!cleanupError && cleanupResult) {
    junkRemoved = cleanupResult.reduce(
      (sum: number, r: { removed_count: number }) => sum + r.removed_count,
      0,
    );
  }

  return new Response(
    JSON.stringify({
      processed: listings.length,
      succeeded,
      errors,
      total_images: totalImages,
      total_junk: totalJunk,
      junk_removed: junkRemoved,
      cleanup_error: cleanupError?.message ?? null,
      error_details: errorDetails.length > 0 ? errorDetails : undefined,
    }),
    { headers: { "Content-Type": "application/json" } },
  );
});
