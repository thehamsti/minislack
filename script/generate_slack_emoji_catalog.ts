type SkinVariation = {
  unified: string;
};

type EmojiRecord = {
  short_names: string[];
  skin_variations?: Record<string, SkinVariation> | null;
  unified: string;
};

const [sourcePath, outputPath] = Bun.argv.slice(2);
if (!sourcePath || !outputPath) {
  throw new Error(
    "usage: bun script/generate_slack_emoji_catalog.ts emoji.json output.swift",
  );
}

const records = (await Bun.file(sourcePath).json()) as EmojiRecord[];
const modifierByTone = {
  2: "1F3FB",
  3: "1F3FC",
  4: "1F3FD",
  5: "1F3FE",
  6: "1F3FF",
} as const;

function swiftUnicode(unified: string): string {
  return unified
    .split("-")
    .map((scalar) => `\\u{${scalar}}`)
    .join("");
}

const lines = [
  "// Generated from iamcal/emoji-data v16.0.0.",
  "// Copyright (c) 2013 Cal Henderson. See THIRD_PARTY_NOTICES.md.",
  "// Regenerate with script/generate_slack_emoji_catalog.ts.",
  "",
  "enum SlackEmojiCatalog {",
];

const sortedRecords = records.sort((left, right) =>
  left.short_names[0].localeCompare(right.short_names[0]),
);
const shortcodes = [
  ...new Set(sortedRecords.flatMap((record) => record.short_names)),
];
lines.push("    static let shortcodes: [String] = [");
for (let index = 0; index < shortcodes.length; index += 8) {
  lines.push(
    `        ${shortcodes
      .slice(index, index + 8)
      .map((shortcode) => JSON.stringify(shortcode))
      .join(", ")},`,
  );
}
lines.push(
  "    ]",
  "",
  "    static func unicode(for shortcode: String, skinTone: Int? = nil) -> String? {",
  "        switch shortcode {",
);

for (const record of sortedRecords) {
  const aliases = record.short_names
    .map((alias) => JSON.stringify(alias))
    .join(", ");
  lines.push(`        case ${aliases}:`);

  if (record.skin_variations) {
    lines.push("            switch skinTone {");
    for (const [tone, modifier] of Object.entries(modifierByTone)) {
      const variation = record.skin_variations[modifier];
      if (variation) {
        lines.push(
          `            case ${tone}: "${swiftUnicode(variation.unified)}"`,
        );
      }
    }
    lines.push(
      `            default: "${swiftUnicode(record.unified)}"`,
      "            }",
    );
  } else {
    lines.push(`            "${swiftUnicode(record.unified)}"`);
  }
}

lines.push(
  "        default:",
  "            nil",
  "        }",
  "    }",
  "}",
  "",
);

await Bun.write(outputPath, lines.join("\n"));
