local M = {}

local sign_ns = vim.api.nvim_create_namespace("runme_signs")
local status_ns = vim.api.nvim_create_namespace("runme_status")

-- per-buffer map of cell index -> status extmark id
---@type table<integer, table<integer, integer>>
local status_marks = {}

function M.setup_highlights()
	vim.api.nvim_set_hl(0, "RunmeSign", { default = true, link = "DiagnosticSignInfo" })
	vim.api.nvim_set_hl(0, "RunmeRunning", { default = true, link = "DiagnosticSignWarn" })
	vim.api.nvim_set_hl(0, "RunmeOk", { default = true, link = "DiagnosticSignOk" })
	vim.api.nvim_set_hl(0, "RunmeFailed", { default = true, link = "DiagnosticSignError" })
end

-- Redraw play-button signs for every runnable cell.
---@param cells RunmeCell[]
function M.refresh_signs(bufnr, cells)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local sign = require("runme").config.ui.sign
	vim.api.nvim_buf_clear_namespace(bufnr, sign_ns, 0, -1)
	for _, cell in ipairs(cells) do
		pcall(vim.api.nvim_buf_set_extmark, bufnr, sign_ns, cell.start_row, 0, {
			sign_text = sign,
			sign_hl_group = "RunmeSign",
		})
	end
end

-- Show a status as virtual text on the cell's fence line. The status stays
-- until the next run of that cell (the extmark moves along with edits).
---@param state "running"|"ok"|"failed"
---@param code integer? exit code for failed runs
function M.set_status(bufnr, cell, state, code)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	status_marks[bufnr] = status_marks[bufnr] or {}
	local previous = status_marks[bufnr][cell.index]
	if previous then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, status_ns, previous)
	end

	local text, hl
	if state == "running" then
		text, hl = "⟳ running…", "RunmeRunning"
	elseif state == "ok" then
		text, hl = "✓ " .. os.date("%H:%M:%S"), "RunmeOk"
	else
		text, hl = string.format("✗ exit %d %s", code or -1, os.date("%H:%M:%S")), "RunmeFailed"
	end

	local ok, mark = pcall(vim.api.nvim_buf_set_extmark, bufnr, status_ns, cell.start_row, 0, {
		virt_text = { { text, hl } },
		virt_text_pos = "eol",
	})
	if ok then
		status_marks[bufnr][cell.index] = mark
	end
end

return M
