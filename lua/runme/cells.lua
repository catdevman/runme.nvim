local M = {}

-- per-buffer reconciled data from `runme list --json`
---@type table<integer, table[]>
M.listed = {}

local function node_text(node, bufnr)
	local get = vim.treesitter.get_node_text or vim.treesitter.query.get_node_text
	return get(node, bufnr)
end

---@param info string fence info string, e.g. `sh { name=hello }`
---@return string? lang, string? name
local function parse_info(info)
	local lang = info:match("^%s*([^%s{`]+)")
	local name = info:match("name%s*=%s*([^%s,}\"']+)")
	return lang, name
end

---@class RunmeCell
---@field index integer 0-based index matching `runme run --index`
---@field name string? cell name from `{ name=... }` or reconciled from runme
---@field lang string? fence language
---@field start_row integer 0-based row of the opening fence
---@field end_row integer 0-based row of the closing fence

-- Fallback scanner for when no treesitter markdown parser is available.
---@return RunmeCell[]
local function scan_cells(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local cells = {}
	local open
	for i, line in ipairs(lines) do
		local fence, info = line:match("^%s*(```+)%s*(.*)$")
		if fence then
			if open == nil then
				open = { start_row = i - 1, info = info }
			else
				if open.info ~= "" then
					local lang, name = parse_info(open.info)
					cells[#cells + 1] = {
						index = #cells,
						name = name,
						lang = lang,
						start_row = open.start_row,
						end_row = i - 1,
					}
				end
				open = nil
			end
		end
	end
	return cells
end

---@return RunmeCell[]
local function ts_cells(bufnr)
	local parser = vim.treesitter.get_parser(bufnr, "markdown")
	local tree = parser:parse()[1]
	local parse_query = vim.treesitter.query.parse or vim.treesitter.query.parse_query
	local query = parse_query("markdown", "(fenced_code_block) @block")
	local cells = {}
	for _, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
		local info
		for child in node:iter_children() do
			if child:type() == "info_string" then
				info = node_text(child, bufnr)
				break
			end
		end
		if info and info ~= "" then
			local lang, name = parse_info(info)
			local start_row, _, end_row, end_col = node:range()
			if end_col == 0 then
				end_row = end_row - 1
			end
			cells[#cells + 1] = {
				index = #cells,
				name = name,
				lang = lang,
				start_row = start_row,
				end_row = end_row,
			}
		end
	end
	return cells
end

-- Runnable cells for a buffer, in document order. Positions come from
-- treesitter (or a plain scan); names for unnamed cells are filled in from
-- the last `runme list --json` reconcile when the counts line up.
---@return RunmeCell[]
function M.get(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ok, cells = pcall(ts_cells, bufnr)
	if not ok then
		cells = scan_cells(bufnr)
	end

	local listed = M.listed[bufnr]
	if listed and #listed == #cells then
		for i, cell in ipairs(cells) do
			cell.name = cell.name or listed[i].name
		end
	end
	return cells
end

---@return RunmeCell? cell under the cursor in the current window
function M.at_cursor(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	for _, cell in ipairs(M.get(bufnr)) do
		if row >= cell.start_row and row <= cell.end_row then
			return cell
		end
	end
end

-- Asynchronously refresh M.listed[bufnr] from `runme list --json` so that
-- cell names/count reflect what runme itself parses from the file on disk.
function M.reconcile(bufnr, on_done)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local config = require("runme").config
	local file = vim.api.nvim_buf_get_name(bufnr)
	if file == "" or vim.fn.executable(config.runme_path) == 0 then
		return
	end

	local stdout = {}
	vim.fn.jobstart({
		config.runme_path,
		"list",
		"--json",
		"--allow-unnamed",
		"--filename",
		vim.fn.fnamemodify(file, ":t"),
	}, {
		cwd = vim.fn.fnamemodify(file, ":h"),
		stdout_buffered = true,
		on_stdout = function(_, data)
			stdout = data or {}
		end,
		on_exit = function(_, code)
			if code ~= 0 then
				return
			end
			local ok, decoded = pcall(vim.json.decode, table.concat(stdout, "\n"))
			if ok and type(decoded) == "table" then
				M.listed[bufnr] = decoded
				if on_done then
					on_done(decoded)
				end
			end
		end,
	})
end

return M
