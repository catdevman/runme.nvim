# runme.nvim

Jupyter-style notebook UX for [runme](https://github.com/runmedev/runme) runbooks, in Neovim.

Every fenced code block in a markdown file gets a play button (`▶`) in the sign
column. Run the cell under your cursor, cycle between runnable cells, rerun the
last one — and because every run is routed through a per-Neovim `runme server`
session, exported environment variables persist from cell to cell, just like a
notebook kernel.

## Features

- `▶` sign on every runnable code block, with status virtual text after runs
  (`⟳ running…`, `✓ 14:03:22`, `✗ exit 1 14:03:25`). Statuses stay until the
  cell is run again and move along with your edits.
- Session persistence: `export FOO=bar` in one cell, `echo $FOO` in the next.
- Cell discovery via treesitter (falls back to a plain scanner), reconciled
  with `runme list --json` on save so names match what runme itself parses.
- Project-wide task picker across all markdown files (`vim.ui.select`).
- The classic runme TUI is still there.
- Auto-installs the pinned runme release (v3.17.2 from `runmedev/runme`) if no
  binary is found.

## Setup

```lua
require("runme").setup({
	-- everything below is optional; defaults shown
	runme_path = vim.fn.exepath("runme"),
	install_path = vim.env.HOME .. "/.local/bin",
	version = "3.17.2",       -- release installed when runme is missing
	auto_save = true,          -- write modified buffer before a run (runme reads from disk)
	skip_prompts = true,       -- don't prompt interactively for exported variables
	output = { height = 12 },  -- shared output split height
	server = {
		enabled = true,        -- session persistence across cell runs
		address = nil,         -- default: unix socket under stdpath("run")
		tls_dir = vim.fn.stdpath("data") .. "/runme/tls",
	},
	ui = { sign = "▶" },
})
```

## Usage

No default keymaps — bind the Lua API to whatever you like:

```lua
local runme = require("runme")
vim.keymap.set("n", "]r", runme.next, { desc = "next runnable cell" })
vim.keymap.set("n", "[r", runme.prev, { desc = "previous runnable cell" })
vim.keymap.set("n", "<leader>rr", runme.run, { desc = "run cell under cursor" })
vim.keymap.set("n", "<leader>rn", runme.run_next, { desc = "run next cell" })
vim.keymap.set("n", "<leader>rl", runme.rerun, { desc = "rerun last cell" })
vim.keymap.set("n", "<leader>ra", runme.run_all, { desc = "run all cells" })
vim.keymap.set("n", "<leader>rt", runme.tasks, { desc = "pick a project task" })
```

Everything is also reachable through one command:

| Command | API | Action |
| --- | --- | --- |
| `:Runme run` | `runme.run()` | run the cell under the cursor |
| `:Runme next` / `:Runme prev` | `runme.next()` / `runme.prev()` | jump between runnable cells (wraps) |
| `:Runme run-next` | `runme.run_next()` | jump to the next cell and run it |
| `:Runme rerun` | `runme.rerun()` | rerun the last-run cell |
| `:Runme run-all` | `runme.run_all()` | run every cell in the file |
| `:Runme tasks` | `runme.tasks()` | pick a task from any markdown file in the project |
| `:Runme` / `:Runme tui` | `runme.tui()` | open the runme TUI |
| `:Runme install` | `runme.install()` | (re)install the pinned runme release |

Cells are runme code blocks — name them for nicer output:

```sh { name=hello }
$ echo "hello world"
```

```sh { name=more }
$ echo "hello more"
```

## Notes

- runme executes the file on disk; with `auto_save = false` you'll be warned
  about unsaved changes instead of the buffer being written for you.
- Session persistence needs the `runme server` sidecar (started lazily, one
  per Neovim instance, stopped on exit). If it can't start, runs still work —
  each in an isolated session — and you'll get a one-time warning.
- Duplicate task names in different files are fine in the picker: runs are
  scoped to the chosen file.
