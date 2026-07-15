local cells = require("runme.cells")
local server = require("runme.server")
local ui = require("runme.ui")

local M = {
	-- last successfully launched cell: { bufnr = ..., cell = ... }
	last = nil,
	output = { win = nil, job = nil },
}

local function err(msg)
	vim.notify(msg, vim.log.levels.ERROR, { title = "runme" })
end

local function config()
	return require("runme").config
end

local function check_binary()
	if vim.fn.executable(config().runme_path) == 0 then
		err(
			string.format(
				"could not execute runme binary in path=%s . make sure you have the right config",
				config().runme_path
			)
		)
		return false
	end
	return true
end

-- Write the buffer if needed: runme reads the file from disk.
local function ensure_saved(bufnr)
	if not vim.bo[bufnr].modified then
		return true
	end
	if config().auto_save then
		local ok = pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent write")
		end)
		return ok
	end
	err("buffer has unsaved changes; runme runs the file on disk (set auto_save = true to write automatically)")
	return false
end

local function output_win()
	if M.output.win and vim.api.nvim_win_is_valid(M.output.win) then
		return M.output.win
	end
	local current = vim.api.nvim_get_current_win()
	vim.cmd("botright " .. config().output.height .. "split")
	M.output.win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(current)
	return M.output.win
end

-- Run `args` in a terminal inside the shared output split.
---@param opts { cwd: string, focus: boolean?, on_exit: fun(code: integer)? }
local function run_in_terminal(args, opts)
	-- stop a still-running previous run instead of letting the buffer wipe SIGHUP it
	if M.output.job and vim.fn.jobwait({ M.output.job }, 0)[1] == -1 then
		vim.fn.jobstop(M.output.job)
	end
	local win = output_win()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(win, buf)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_win_call(win, function()
		M.output.job = vim.fn.termopen(args, {
			cwd = opts.cwd,
			on_exit = function(_, code)
				if opts.on_exit then
					opts.on_exit(code)
				end
			end,
		})
	end)
	if opts.focus then
		vim.api.nvim_set_current_win(win)
		vim.cmd("startinsert")
	end
end

---@param cell RunmeCell
function M.run_cell(bufnr, cell)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not check_binary() then
		return
	end
	local file = vim.api.nvim_buf_get_name(bufnr)
	if file == "" then
		return err("buffer has no file name; save it first")
	end
	if not ensure_saved(bufnr) then
		return
	end

	ui.set_status(bufnr, cell, "running")
	server.ensure(function()
		local args = {
			config().runme_path,
			"run",
			"--index",
			tostring(cell.index),
			"--allow-unnamed",
			"--filename",
			vim.fn.fnamemodify(file, ":t"),
		}
		if config().skip_prompts then
			table.insert(args, "--skip-prompts")
		end
		vim.list_extend(args, server.run_args())
		run_in_terminal(args, {
			cwd = vim.fn.fnamemodify(file, ":h"),
			on_exit = function(code)
				ui.set_status(bufnr, cell, code == 0 and "ok" or "failed", code)
			end,
		})
		M.last = { bufnr = bufnr, cell = cell }
	end)
end

-- Run the cell under the cursor.
function M.run()
	local cell = cells.at_cursor()
	if not cell then
		return err("no runnable block under cursor")
	end
	M.run_cell(vim.api.nvim_get_current_buf(), cell)
end

---@param offset 1|-1
---@return RunmeCell? the cell jumped to
local function jump(offset)
	local all = cells.get()
	if #all == 0 then
		err("no runnable blocks in buffer")
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	-- when inside a cell, jump relative to that cell rather than the cursor row
	local containing
	for _, cell in ipairs(all) do
		if row >= cell.start_row and row <= cell.end_row then
			containing = cell
			break
		end
	end
	local target
	if offset > 0 then
		local after = containing and containing.end_row or row
		for _, cell in ipairs(all) do
			if cell.start_row > after then
				target = cell
				break
			end
		end
		target = target or all[1] -- wrap
	else
		local before = containing and containing.start_row or row
		for i = #all, 1, -1 do
			if all[i].start_row < before then
				target = all[i]
				break
			end
		end
		target = target or all[#all] -- wrap
	end
	vim.api.nvim_win_set_cursor(0, { math.min(target.start_row + 2, target.end_row + 1), 0 })
	return target
end

-- Move the cursor to the next/previous runnable block (wraps around).
function M.next()
	jump(1)
end

function M.prev()
	jump(-1)
end

-- Jump to the next runnable block and run it.
function M.run_next()
	local cell = jump(1)
	if cell then
		M.run_cell(vim.api.nvim_get_current_buf(), cell)
	end
end

-- Rerun the last cell that was run.
function M.rerun()
	if not M.last or not vim.api.nvim_buf_is_valid(M.last.bufnr) then
		return err("nothing has been run yet")
	end
	M.run_cell(M.last.bufnr, M.last.cell)
end

-- Run every cell in the current file, top to bottom, in one invocation.
function M.run_all()
	local bufnr = vim.api.nvim_get_current_buf()
	if not check_binary() then
		return
	end
	local file = vim.api.nvim_buf_get_name(bufnr)
	if file == "" then
		return err("buffer has no file name; save it first")
	end
	if not ensure_saved(bufnr) then
		return
	end
	server.ensure(function()
		local args = {
			config().runme_path,
			"run",
			"--all",
			"--allow-unnamed",
			"--filename",
			vim.fn.fnamemodify(file, ":t"),
		}
		if config().skip_prompts then
			table.insert(args, "--skip-prompts")
		end
		vim.list_extend(args, server.run_args())
		run_in_terminal(args, { cwd = vim.fn.fnamemodify(file, ":h") })
	end)
end

local function project_root()
	local file = vim.api.nvim_buf_get_name(0)
	local dir = file ~= "" and vim.fn.fnamemodify(file, ":h") or vim.loop.cwd()
	local git = vim.fs.find(".git", { upward = true, path = dir })[1]
	return git and vim.fs.dirname(git) or dir
end

-- Pick and run a task from any markdown file in the project.
function M.tasks()
	if not check_binary() then
		return
	end
	local root = project_root()
	local stdout = {}
	vim.fn.jobstart({ config().runme_path, "list", "--json", "--allow-unnamed", "--project", root }, {
		cwd = root,
		stdout_buffered = true,
		on_stdout = function(_, data)
			stdout = data or {}
		end,
		on_exit = function(_, code)
			if code ~= 0 then
				return err("runme list failed for project " .. root)
			end
			local ok, tasks = pcall(vim.json.decode, table.concat(stdout, "\n"))
			if not ok or type(tasks) ~= "table" or #tasks == 0 then
				return err("no runnable tasks found in project " .. root)
			end
			vim.ui.select(tasks, {
				prompt = "Run task",
				format_item = function(task)
					return string.format("%s (%s)", task.name, task.file)
				end,
			}, function(task)
				if not task then
					return
				end
				server.ensure(function()
					-- scope to the task's file so duplicate names across files stay unambiguous
					local args = {
						config().runme_path,
						"run",
						task.name,
						"--allow-unnamed",
						"--filename",
						vim.fn.fnamemodify(task.file, ":t"),
					}
					vim.list_extend(args, server.run_args())
					run_in_terminal(args, { cwd = root .. "/" .. vim.fn.fnamemodify(task.file, ":h") })
				end)
			end)
		end,
	})
end

-- Open the interactive runme TUI for a markdown file.
function M.tui(file)
	if not check_binary() then
		return
	end
	file = file or vim.api.nvim_buf_get_name(0)
	if file == "" then
		return err("buffer has no file name")
	end
	run_in_terminal({ config().runme_path, "--filename", vim.fn.fnamemodify(file, ":t") }, {
		cwd = vim.fn.fnamemodify(file, ":h"),
		focus = true,
	})
end

return M
