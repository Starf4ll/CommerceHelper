/// Embedded default data files for restore-defaults support.
/// This file lives in assets/ so that @embedFile can reference goods.json
/// and routes.json (which are siblings in the same directory).
pub const DEFAULT_GOODS_JSON: []const u8 = @embedFile("goods.json");
pub const DEFAULT_ROUTES_JSON: []const u8 = @embedFile("routes.json");
