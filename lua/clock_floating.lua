-- lua/clock_floating.lua
-- ClockFloating: a small Neovim plugin that shows a large ASCII/block digital clock
-- Single-file plugin, idiomatic Neovim Lua, no external deps.
--
-- Key features:
-- - Toggle with require('clock_floating').toggle() (mapping example below uses <leader>ck)
-- - Centered floating window overlay, keeps buffer visible via winblend
-- - Optional shadow window to give a subtle 3D effect
-- - Timer-driven update (default 1s) with proper cleanup
-- - Reacts to VimResized to stay centered
-- - Simple config table to override defaults
--
-- Implementation notes:
-- - Two floating windows are used: a shadow (behind) and the main window (above).
-- - Highlight groups are created for main digits and shadow. These support both GUI and TTY.
-- - Digits are defined as arrays of strings using block characters; there's a 'scale' option
--   to approximate larger digits (duplicate rows/cols).
-- - Uses vim.loop.new_timer for regular updates and an autocmd for resizing and cleanup.
-- - Minimal, terminal-friendly color choices by default (dark theme); user can supply light theme.

local M = {}

local default_cfg = {
  min_neovim = "0.8",
  winblend = 40,                 -- transparency of the floating window (0-100)
  shadow_winblend = 60,          -- transparency for shadow
  interval = 1000,               -- update interval in ms
  fg = "#a8ff60",                -- main digit color (default greenish)
  shadow_fg = "#2b5d1a",         -- shadow color (darker)
  font = "JetBrains Mono",       -- suggested font (for the image rendering); terminal unaffected
  scale = 1,                     -- integer scale: 1 = normal, 2 = large-ish
  padding = 2,                   -- padding characters around digits
  border = "none",               -- floating window border style
  use_shadow = true,             -- create a shadow window behind the main clock
  -- behavior settings:
  min_cols = 30,                 -- if terminal smaller than this, hide clock
  min_rows = 8,
}

-- ASCII / block-digit font: each digit is an array of strings. Use block chars for boldness.
-- The colon ":" is included.
local digit_map = {
  ["0"] = {
    " █████ ",
    "█     █",
    "█     █",
    "█     █",
    " █████ ",
  },
  ["1"] = {
    "   █   ",
    "  ██   ",
    "   █   ",
    "   █   ",
    "  ███  ",
  },
  ["2"] = {
    " █████ ",
    "█     █",
    "    ██ ",
    "  ██   ",
    "███████",
  },
  ["3"] = {
    " █████ ",
    "█     █",
    "   ███ ",
    "█     █",
    " █████ ",
  },
  ["4"] = {
    "█   ██ ",
    "█   ██ ",
    "███████",
    "    ██ ",
    "    ██ ",
  },
  ["5"] = {
    "███████",
    "█      ",
    "██████ ",
    "      █",
    "██████ ",
  },
  ["6"] = {
    " █████ ",
    "█      ",
    "██████ ",
    "█     █",
    " █████ ",
  },
  ["7"] = {
    "███████",
    "█    ██",
    "    ██ ",
    "   ██  ",
    "  ██   ",
  },
  ["8"] = {
    " █████ ",
    "█     █",
    " █████ ",
    "█     █",
    " █████ ",
  },
  ["9"] = {
    " █████ ",
    "█     █",
    " ██████",
    "      █",
    " █████ ",
  },
  [":"] = {
    "       ",
    "   ██  ",
    "       ",
    "   ██  ",
    "       ",
  },
}

-- internal state
local state = {
  cfg = vim.tbl_deep_extend("force", {}, default_cfg),
  timer = nil,
  bufs = { main = nil, shadow = nil },
  wins = { main = nil, shadow = nil },
  active = false,
  augroup = nil,
}

-- helper to create highlight groups (works for GUI and TTY): ClockFloatingMain, ClockFloatingShadow
local function create_highlights(cfg)
  -- main digits highlight
  vim.cmd(string.format(
    "highlight default ClockFloatingMain guifg=%s guibg=NONE ctermfg=154 ctermbg=NONE",
    cfg.fg
  ))
  -- shadow highlight (darker)
  vim.cmd(string.format(
    "highlight default ClockFloatingShadow guifg=%s guibg=NONE ctermfg=22 ctermbg=NONE",
    cfg.shadow_fg
  ))
end

-- scale a single row horizontally by repeating characters
local function hscale_row(row, scale)
  if scale <= 1 then return row end
  local out = {}
  for ch in row:gmatch(".") do
    out[#out+1] = ch:rep(scale)
  end
  return table.concat(out)
end

-- scale array of rows vertically and horizontally
local function scale_block(block, scale)
  local scaled = {}
  for _, row in ipairs(block) do
    local h = hscale_row(row, scale)
    for i = 1, scale do
      scaled[#scaled+1] = h
    end
  end
  return scaled
end

-- Build the multiline string / buffer lines for a time string "HH:MM:SS"
local function build_clock_lines(time_str, cfg)
  local chars = {}
  for ch in time_str:gmatch(".") do
    table.insert(chars, ch)
  end

  -- For each character, get its block lines (scaled)
  local blocks = {}
  for _, ch in ipairs(chars) do
    local block = digit_map[ch] or digit_map[" "]
    blocks[#blocks+1] = scale_block(block, cfg.scale)
  end

  -- number of rows in a block (should be consistent)
  local rows = #blocks[1]

  local pad = string.rep(" ", cfg.padding)
  local lines = {}
  for r = 1, rows do
    local parts = {}
    for i = 1, #blocks do
      parts[#parts+1] = blocks[i][r] or string.rep(" ", #blocks[1][r])
    end
    lines[#lines+1] = pad .. table.concat(parts, " ") .. pad
  end
  return lines
end

-- compute float window size for buffer lines
local function compute_size(lines)
  local h = #lines
  local w = 0
  for _, l in ipairs(lines) do
    local len = vim.fn.strdisplaywidth(l)
    if len > w then w = len end
  end
  return h, w
end

-- create a scratch buffer
local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "clockfloating")
  return buf
end

-- open floating window with given lines and options. returns (buf, win)
local function open_floating(lines, opts)
  local buf = make_buf()
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  local win = vim.api.nvim_open_win(buf, false, opts)
  -- make window options
  vim.api.nvim_win_set_option(win, "winblend", opts.winblend or 0)
  vim.api.nvim_win_set_option(win, "wrap", false)
  vim.api.nvim_win_set_option(win, "cursorline", false)
  vim.api.nvim_win_set_option(win, "signcolumn", "no")
  vim.api.nvim_win_set_option(win, "foldcolumn", "0")
  return buf, win
end

-- center config calculation
local function make_center_config(lines, cfg, offset_row, offset_col)
  local rows, cols = compute_size(lines)
  local ui_cols = vim.o.columns
  local ui_rows = vim.o.lines - vim.o.cmdheight -- approximate
  local row = math.max(0, math.floor((ui_rows - rows) / 2) + (offset_row or 0))
  local col = math.max(0, math.floor((ui_cols - cols) / 2) + (offset_col or 0))
  return {
    relative = "editor",
    row = row,
    col = col,
    width = cols,
    height = rows,
    style = "minimal",
    border = cfg.border,
  }
end

-- update function (rebuilds lines and updates buffers/wins)
local function render_once()
  if not state.active then return end
  local cfg = state.cfg

  -- hide if terminal too small
  if vim.o.columns < cfg.min_cols or (vim.o.lines - vim.o.cmdheight) < cfg.min_rows then
    -- close windows if open
    if state.wins.main and vim.api.nvim_win_is_valid(state.wins.main) then
      pcall(vim.api.nvim_win_close, state.wins.main, true)
      state.wins.main = nil
      state.bufs.main = nil
    end
    if state.wins.shadow and vim.api.nvim_win_is_valid(state.wins.shadow) then
      pcall(vim.api.nvim_win_close, state.wins.shadow, true)
      state.wins.shadow = nil
      state.bufs.shadow = nil
    end
    return
  end

  local timestr = os.date("%H:%M:%S")
  local lines = build_clock_lines(timestr, cfg)

  -- main config
  local main_cfg = make_center_config(lines, cfg, 0, 0)
  main_cfg.winblend = cfg.winblend

  -- shadow config (offset slightly)
  local shadow_cfg = nil
  if cfg.use_shadow then
    shadow_cfg = vim.deepcopy(main_cfg)
    shadow_cfg.row = shadow_cfg.row + 1
    shadow_cfg.col = shadow_cfg.col + 2
    shadow_cfg.winblend = cfg.shadow_winblend
  end

  -- create highlights (idempotent)
  create_highlights(cfg)

  -- (1) create or update shadow first
  if cfg.use_shadow then
    if not (state.wins.shadow and vim.api.nvim_win_is_valid(state.wins.shadow)) then
      -- open new shadow window (behind main)
      local buf_s, win_s = open_floating(lines, shadow_cfg)
      -- use winhl to map Normal to ClockFloatingShadow
      vim.api.nvim_win_set_option(win_s, "winhl", "Normal:ClockFloatingShadow")
      state.bufs.shadow = buf_s
      state.wins.shadow = win_s
    else
      -- update lines and position
      if state.bufs.shadow and vim.api.nvim_buf_is_valid(state.bufs.shadow) then
        vim.api.nvim_buf_set_option(state.bufs.shadow, "modifiable", true)
        vim.api.nvim_buf_set_lines(state.bufs.shadow, 0, -1, false, lines)
        vim.api.nvim_buf_set_option(state.bufs.shadow, "modifiable", false)
      end
      -- reposition: close & reopen to ensure centering or use nvim_win_set_config if available
      if not pcall(function() vim.api.nvim_win_set_config(state.wins.shadow, shadow_cfg) end) then
        pcall(vim.api.nvim_win_close, state.wins.shadow, true)
        state.bufs.shadow, state.wins.shadow = open_floating(lines, shadow_cfg)
        vim.api.nvim_win_set_option(state.wins.shadow, "winhl", "Normal:ClockFloatingShadow")
      end
    end
  end

  -- (2) create or update main window (on top)
  if not (state.wins.main and vim.api.nvim_win_is_valid(state.wins.main)) then
    local buf_m, win_m = open_floating(lines, main_cfg)
    vim.api.nvim_win_set_option(win_m, "winhl", "Normal:ClockFloatingMain")
    state.bufs.main = buf_m
    state.wins.main = win_m
  else
    if state.bufs.main and vim.api.nvim_buf_is_valid(state.bufs.main) then
      vim.api.nvim_buf_set_option(state.bufs.main, "modifiable", true)
      vim.api.nvim_buf_set_lines(state.bufs.main, 0, -1, false, lines)
      vim.api.nvim_buf_set_option(state.bufs.main, "modifiable", false)
    end
    if not pcall(function() vim.api.nvim_win_set_config(state.wins.main, main_cfg) end) then
      pcall(vim.api.nvim_win_close, state.wins.main, true)
      state.bufs.main, state.wins.main = open_floating(lines, main_cfg)
      vim.api.nvim_win_set_option(state.wins.main, "winhl", "Normal:ClockFloatingMain")
    end
  end
end

-- start the update timer
local function start_timer()
  if state.timer and not state.timer:is_closing() then return end
  local t = vim.loop.new_timer()
  -- first render immediately
  render_once()
  t:start(0, state.cfg.interval, vim.schedule_wrap(function()
    -- schedule_wrap ensures we run on main loop
    if not state.active then
      if t and not t:is_closing() then
        pcall(t:stop, t)
        pcall(t:close, t)
      end
      return
    end
    render_once()
  end))
  state.timer = t
end

-- stop timer & close windows
local function stop_and_cleanup()
  if state.timer and not state.timer:is_closing() then
    pcall(state.timer.stop, state.timer)
    pcall(state.timer.close, state.timer)
    state.timer = nil
  end
  if state.wins.main and vim.api.nvim_win_is_valid(state.wins.main) then
    pcall(vim.api.nvim_win_close, state.wins.main, true)
  end
  if state.wins.shadow and vim.api.nvim_win_is_valid(state.wins.shadow) then
    pcall(vim.api.nvim_win_close, state.wins.shadow, true)
  end
  state.wins.main = nil
  state.wins.shadow = nil
  state.bufs.main = nil
  state.bufs.shadow = nil
end

-- Toggle API
function M.toggle()
  if state.active then
    state.active = false
    stop_and_cleanup()
  else
    state.active = true
    -- create an augroup for autocmds if not present
    if not state.augroup then
      state.augroup = vim.api.nvim_create_augroup("ClockFloatingAG", { clear = false })
      -- re-render on resize
      vim.api.nvim_create_autocmd({ "VimResized" }, {
        group = state.augroup,
        callback = function() vim.schedule(function() if state.active then render_once() end end) end,
      })
      -- cleanup on exit
      vim.api.nvim_create_autocmd({ "VimLeavePre", "BufDelete" }, {
        group = state.augroup,
        callback = function() stop_and_cleanup() end,
      })
    end
    start_timer()
  end
end

-- setup function to accept user config
function M.setup(user_cfg)
  if user_cfg and type(user_cfg) == "table" then
    state.cfg = vim.tbl_deep_extend("force", {}, default_cfg, user_cfg)
  end
  -- ensure highlights created now
  create_highlights(state.cfg)

  -- create a global mapping if not already present
  -- We create lazy mapping to call require('clock_floating').toggle()
  -- Note: user may prefer to map themselves - this is just a safe default.
  if vim.fn.exists(":ClockFloatingToggle") == 0 then
    -- Create a user command as convenience
    vim.api.nvim_create_user_command("ClockFloatingToggle", function()
      require("clock_floating").toggle()
    end, { desc = "Toggle floating ASCII clock" })
  end

  -- do not auto-map <leader>ck here because many users prefer to do it in init.lua;
  -- however provide a helper in the module to set mapping. We'll set a fallback safe mapping:
  if vim.g.clock_floating_map_default ~= false then
    -- set mapping only if not already mapped
    local existing = vim.fn.maparg("<leader>ck", "n")
    if existing == "" then
      vim.keymap.set("n", "<leader>ck", function() require("clock_floating").toggle() end, { desc = "Toggle ClockFloating" })
    end
  end
end

-- convenience function to return whether active
function M.is_active() return state.active end

-- Allow programmatic start/stop
function M.start() if not state.active then M.toggle() end end
function M.stop() if state.active then M.toggle() end end

-- expose functions for the user's `init.lua`
return M

