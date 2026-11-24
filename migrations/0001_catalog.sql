-- D1 Catalog Schema for cc-mesh-bridge

CREATE TABLE IF NOT EXISTS packages (
  slug TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  version TEXT NOT NULL,
  r2_key TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  author TEXT,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS schematics (
  slug TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  format TEXT NOT NULL,
  r2_key TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  tags_json TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS items (
  item_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  mod_id TEXT NOT NULL,
  tags_json TEXT NOT NULL DEFAULT '[]',
  nbt_hash TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS recipes (
  recipe_id TEXT PRIMARY KEY,
  recipe_type TEXT NOT NULL,
  output_item_id TEXT NOT NULL,
  output_count INTEGER NOT NULL DEFAULT 1,
  machine TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS recipe_ingredients (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  recipe_id TEXT NOT NULL,
  ingredient_id TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  slot TEXT NOT NULL DEFAULT '',
  UNIQUE(recipe_id, ingredient_id, slot),
  FOREIGN KEY(recipe_id) REFERENCES recipes(recipe_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_recipes_output_item_id ON recipes(output_item_id);
CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_ingredient_id ON recipe_ingredients(ingredient_id);
CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_recipe_id ON recipe_ingredients(recipe_id);

CREATE TABLE IF NOT EXISTS device_api_specs (
  type_name TEXT PRIMARY KEY,
  methods_json TEXT NOT NULL,
  spec_json TEXT NOT NULL,
  spec_markdown TEXT NOT NULL,
  generated_by TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
