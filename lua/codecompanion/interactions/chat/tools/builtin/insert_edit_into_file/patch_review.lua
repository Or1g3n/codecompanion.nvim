local hash = require("codecompanion.utils.hash")
local labels = require("codecompanion.interactions.chat.tools.labels")
local ui_utils = require("codecompanion.utils.ui")

local fmt = string.format

local M = {}

---@return string
local function cwd_root()
  return vim.fs.normalize(vim.fn.getcwd())
end

---@param path string
---@return string
local function to_relpath(path)
  if type(path) ~= "string" or path == "" then
    return "buffer"
  end
  local absolute = vim.fs.normalize(path)
  local root = cwd_root()
  if absolute:sub(1, #root) == root then
    local stripped = absolute:sub(#root + 1)
    stripped = stripped:gsub("^[/\\]", "")
    if stripped ~= "" then
      return stripped
    end
  end
  return vim.fn.fnamemodify(absolute, ":t")
end

---@param left string
---@param right string
---@return boolean
local function paths_match(left, right)
  if type(left) ~= "string" or type(right) ~= "string" or left == "" or right == "" then
    return false
  end

  local normalized_left = vim.fs.normalize(left)
  local normalized_right = vim.fs.normalize(right)
  if normalized_left == normalized_right then
    return true
  end

  local left_tail = to_relpath(left)
  local right_tail = to_relpath(right)
  return left_tail == right_tail
end

---@param line string
---@return table|nil
local function parse_hunk_header(line)
  local from_start, from_count, to_start, to_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not from_start or not to_start then
    return nil
  end

  return {
    from_start = tonumber(from_start),
    from_count = tonumber(from_count ~= "" and from_count or "1"),
    to_start = tonumber(to_start),
    to_count = tonumber(to_count ~= "" and to_count or "1"),
    lines = {},
    header = line,
  }
end

---@param opts { filepath: string, from_lines: string[], to_lines: string[] }
---@return string
function M.build_unified_patch(opts)
  -- Use vim.text.diff when available, with fallback to vim.diff for compatibility.
  ---@diagnostic disable-next-line: deprecated
  local diff_fn = vim.text.diff or vim.diff
  local relative_path = to_relpath(opts.filepath)
  local from_text = table.concat(opts.from_lines or {}, "\n")
  local to_text = table.concat(opts.to_lines or {}, "\n")
  local unified = diff_fn(from_text, to_text, { result_type = "unified", ctxlen = 3, algorithm = "myers" }) or ""

  return fmt("--- a/%s\n+++ b/%s\n%s", relative_path, relative_path, unified)
end

---@param opts { patch_text: string }
---@return { ok: boolean, error?: string, patch?: table }
function M.parse_unified_patch(opts)
  if type(opts.patch_text) ~= "string" or vim.trim(opts.patch_text) == "" then
    return { ok = false, error = "Patch text is empty" }
  end

  local lines = vim.split(opts.patch_text, "\n", { plain = true })
  local patch = {
    old_path = nil,
    new_path = nil,
    hunks = {},
    text = opts.patch_text,
  }

  local index = 1
  if lines[index] and lines[index]:match("^%-%-%- ") then
    patch.old_path = lines[index]:gsub("^%-%-%- [ab]/", ""):gsub("^%-%-%- ", "")
    index = index + 1
  end
  if lines[index] and lines[index]:match("^%+%+%+ ") then
    patch.new_path = lines[index]:gsub("^%+%+%+ [ab]/", ""):gsub("^%+%+%+ ", "")
    index = index + 1
  end

  local current_hunk = nil
  while index <= #lines do
    local line = lines[index]
    index = index + 1

    if line:match("^@@ ") then
      local parsed = parse_hunk_header(line)
      if not parsed then
        return { ok = false, error = "Invalid hunk header: " .. line }
      end
      current_hunk = parsed
      table.insert(patch.hunks, current_hunk)
    elseif current_hunk then
      if line == "" then
        table.insert(current_hunk.lines, { type = "context", text = "" })
      else
        local prefix = line:sub(1, 1)
        local text = line:sub(2)

        if prefix == " " then
          table.insert(current_hunk.lines, { type = "context", text = text })
        elseif prefix == "+" then
          table.insert(current_hunk.lines, { type = "add", text = text })
        elseif prefix == "-" then
          table.insert(current_hunk.lines, { type = "delete", text = text })
        elseif line:match("^\\ No newline at end of file") then
          -- intentionally ignored
        else
          return { ok = false, error = "Malformed patch line: " .. line }
        end
      end
    end
  end

  if #patch.hunks == 0 then
    return { ok = false, error = "No hunks found in patch" }
  end

  return { ok = true, patch = patch }
end

---@param opts { patch: table, source_lines: string[], expected_path?: string }
---@return { ok: boolean, error?: string, new_lines?: string[], files_touched?: string[], hunk_ranges?: table[] }
function M.apply_patch(opts)
  local patch = opts.patch
  if type(patch) ~= "table" or type(patch.hunks) ~= "table" then
    return { ok = false, error = "Invalid patch structure" }
  end

  local source_lines = vim.deepcopy(opts.source_lines or {})
  local output_lines = {}
  local source_index = 1
  local hunk_ranges = {}

  for _, hunk in ipairs(patch.hunks) do
    local target_source_index = math.max(hunk.from_start, 1)
    while source_index < target_source_index do
      table.insert(output_lines, source_lines[source_index] or "")
      source_index = source_index + 1
    end

    local output_start = #output_lines + 1
    for _, hunk_line in ipairs(hunk.lines) do
      if hunk_line.type == "context" then
        local source_line = source_lines[source_index] or ""
        if source_line ~= hunk_line.text then
          return {
            ok = false,
            error = fmt(
              "Patch context mismatch near hunk %s (expected %q, got %q)",
              hunk.header,
              hunk_line.text,
              source_line
            ),
          }
        end
        table.insert(output_lines, source_line)
        source_index = source_index + 1
      elseif hunk_line.type == "delete" then
        local source_line = source_lines[source_index] or ""
        if source_line ~= hunk_line.text then
          return {
            ok = false,
            error = fmt(
              "Patch deletion mismatch near hunk %s (expected %q, got %q)",
              hunk.header,
              hunk_line.text,
              source_line
            ),
          }
        end
        source_index = source_index + 1
      elseif hunk_line.type == "add" then
        table.insert(output_lines, hunk_line.text)
      else
        return { ok = false, error = "Unknown hunk operation: " .. tostring(hunk_line.type) }
      end
    end

    table.insert(hunk_ranges, {
      from_start = hunk.from_start,
      from_count = hunk.from_count,
      to_start = output_start,
      to_count = (#output_lines - output_start) + 1,
    })
  end

  while source_index <= #source_lines do
    table.insert(output_lines, source_lines[source_index] or "")
    source_index = source_index + 1
  end

  local files_touched = {}
  if patch.new_path then
    table.insert(files_touched, patch.new_path)
  elseif opts.expected_path then
    table.insert(files_touched, to_relpath(opts.expected_path))
  end

  return {
    ok = true,
    new_lines = output_lines,
    files_touched = files_touched,
    hunk_ranges = hunk_ranges,
  }
end

---@param opts { patch: table, expected_path: string, source_lines: string[] }
---@return { ok: boolean, error?: string }
function M.validate_patch(opts)
  if type(opts.patch) ~= "table" then
    return { ok = false, error = "Missing patch data" }
  end

  if opts.patch.old_path and opts.patch.new_path and opts.patch.old_path ~= opts.patch.new_path then
    return { ok = false, error = "Multi-file patch edits are not supported" }
  end

  local patch_path = opts.patch.new_path or opts.patch.old_path
  if patch_path and opts.expected_path and not paths_match(patch_path, opts.expected_path) then
    return {
      ok = false,
      error = fmt("Patch target `%s` does not match expected file `%s`", patch_path, to_relpath(opts.expected_path)),
    }
  end

  local result = M.apply_patch({
    patch = opts.patch,
    source_lines = opts.source_lines or {},
    expected_path = opts.expected_path,
  })
  if not result.ok then
    return { ok = false, error = result.error }
  end

  return { ok = true }
end

---@param opts { patch_text: string }
---@return number
function M.compute_patch_hash(opts)
  return hash.hash(opts.patch_text or "")
end

---@param opts { patch_text: string, title: string, on_accept: fun(edited_patch_text: string), on_cancel: fun() }
---@return number
function M.open_editable_patch_buffer(opts)
  local lines = vim.split(opts.patch_text or "", "\n", { plain = true })
  local bufnr, _ = ui_utils.create_float(lines, {
    width = 0.9,
    height = 0.8,
    ft = "diff",
    ignore_keymaps = true,
    title = opts.title,
  })

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false

  local keys = labels.keymaps()
  vim.keymap.set("n", keys.accept, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    opts.on_accept(text)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Accept edited patch" })

  vim.keymap.set("n", keys.reject, function()
    opts.on_cancel()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Cancel edited patch" })

  vim.keymap.set("n", keys.cancel, function()
    opts.on_cancel()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Cancel edited patch" })

  return bufnr
end

return M
