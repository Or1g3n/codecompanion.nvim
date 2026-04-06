local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        patch_review = require("codecompanion.interactions.chat.tools.builtin.insert_edit_into_file.patch_review")
      ]])
    end,
    post_once = child.stop,
  },
})

T["PatchReview"] = new_set()

T["PatchReview"]["builds unified patch with file headers"] = function()
  local patch = child.lua([[
    return patch_review.build_unified_patch({
      filepath = "/tmp/example.lua",
      from_lines = { "local x = 1" },
      to_lines = { "local x = 2" },
    })
  ]])

  h.expect_match(patch, "^%-%-%- a/")
  h.expect_match(patch, "^.-\n%+%+%+ b/")
  h.expect_match(patch, "@@")
end

T["PatchReview"]["parses unified patch hunks"] = function()
  local result = child.lua([[
    local patch_text = [[
--- a/example.lua
+++ b/example.lua
@@ -1,1 +1,1 @@
-local x = 1
+local x = 2
]]
    return patch_review.parse_unified_patch({ patch_text = patch_text })
  ]])

  h.eq(true, result.ok)
  h.eq("example.lua", result.patch.old_path)
  h.eq("example.lua", result.patch.new_path)
  h.eq(1, #result.patch.hunks)
end

T["PatchReview"]["applies parsed patch to source lines"] = function()
  local result = child.lua([[
    local parsed = patch_review.parse_unified_patch({
      patch_text = [[
--- a/example.lua
+++ b/example.lua
@@ -1,2 +1,2 @@
 local x = 1
-return x
+return x + 1
]]
    })

    if not parsed.ok then
      return parsed
    end

    return patch_review.apply_patch({
      patch = parsed.patch,
      source_lines = { "local x = 1", "return x" },
      expected_path = "/tmp/example.lua",
    })
  ]])

  h.eq(true, result.ok)
  h.eq({ "local x = 1", "return x + 1" }, result.new_lines)
  h.eq(1, #result.hunk_ranges)
end

T["PatchReview"]["fails validation on path mismatch"] = function()
  local result = child.lua([[
    local parsed = patch_review.parse_unified_patch({
      patch_text = [[
--- a/wrong.lua
+++ b/wrong.lua
@@ -1,1 +1,1 @@
-local x = 1
+local x = 2
]]
    })

    return patch_review.validate_patch({
      patch = parsed.patch,
      expected_path = "/tmp/example.lua",
      source_lines = { "local x = 1" },
    })
  ]])

  h.eq(false, result.ok)
  h.expect_match(result.error, "does not match expected file")
end

T["PatchReview"]["fails apply on stale source mismatch"] = function()
  local result = child.lua([[
    local parsed = patch_review.parse_unified_patch({
      patch_text = [[
--- a/example.lua
+++ b/example.lua
@@ -1,1 +1,1 @@
-local x = 1
+local x = 2
]]
    })

    return patch_review.apply_patch({
      patch = parsed.patch,
      source_lines = { "local x = 99" },
      expected_path = "/tmp/example.lua",
    })
  ]])

  h.eq(false, result.ok)
  h.expect_match(result.error, "mismatch")
end

T["PatchReview"]["computes stable patch hash"] = function()
  local result = child.lua([[
    local one = patch_review.compute_patch_hash({ patch_text = "abc" })
    local two = patch_review.compute_patch_hash({ patch_text = "abc" })
    local three = patch_review.compute_patch_hash({ patch_text = "abcd" })
    return { one = one, two = two, three = three }
  ]])

  h.eq(result.one, result.two)
  h.not_eq(result.one, result.three)
end

return T
