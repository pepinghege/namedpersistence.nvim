local Config = require("persistence.config")

local uv = vim.uv or vim.loop

local M = {}
M._active = false
M._sessionname = nil

local e = vim.fn.fnameescape

---@param opts? {branch?: boolean}
function M.current(opts)
  opts = opts or {}
  local name = vim.fn.getcwd():gsub("[\\/:]+", "%%")
  local sessionname = M.sessionname()
  if sessionname then
    name = name .. "%%%" .. sessionname
  elseif Config.options.branch and opts.branch ~= false then
    local branch = M.branch()
    if branch and branch ~= "main" and branch ~= "master" then
      name = name .. "%%" .. branch:gsub("[\\/:]+", "%%")
    end
  end
  return Config.options.dir .. name.. ".vim"
end

function M.setup(opts)
  Config.setup(opts)
  M.start()
end

function M.fire(event)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "Persistence" .. event,
  })
end

-- Check if a session is active
function M.active()
  return M._active
end

function M.start()
  M._active = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("persistence", { clear = true }),
    callback = function()
      M.fire("SavePre")

      if Config.options.need > 0 then
        local bufs = vim.tbl_filter(function(b)
          if vim.bo[b].buftype ~= "" or vim.tbl_contains({ "gitcommit", "gitrebase", "jj" }, vim.bo[b].filetype) then
            return false
          end
          return vim.api.nvim_buf_get_name(b) ~= ""
        end, vim.api.nvim_list_bufs())
        if #bufs < Config.options.need then
          return
        end
      end

      M.save()
      M.fire("SavePost")
    end,
  })
end

function M.stop()
  M._active = false
  pcall(vim.api.nvim_del_augroup_by_name, "persistence")
end

function M.save()
  vim.cmd("mks! " .. e(M.current()))
end

---@param opts? { last?: boolean }
function M.load(opts)
  opts = opts or {}
  ---@type string
  local file
  if opts.last then
    file = M.last()
  else
    file = M.current()
    if vim.fn.filereadable(file) == 0 then
      file = M.current({ branch = false })
    end
  end
  if file and vim.fn.filereadable(file) ~= 0 then
    M.fire("LoadPre")
    vim.cmd("silent! source " .. e(file))
    M.fire("LoadPost")
  end
end

---@return string[]
function M.list()
  local sessions = vim.fn.glob(Config.options.dir .. "*.vim", true, true)
  table.sort(sessions, function(a, b)
    return uv.fs_stat(a).mtime.sec > uv.fs_stat(b).mtime.sec
  end)
  return sessions
end

function M.last()
  return M.list()[1]
end

function M.select()
  ---@type { session: string, dir: string, name?: string, branch?: string }[]
  local items = {}
  local have = {} ---@type table<string, boolean>
  for _, session in ipairs(M.list()) do
    if uv.fs_stat(session) then
      local file = session:sub(#Config.options.dir + 1, -5)
      local branch, index
      local dir, name = unpack(vim.split(file, "%%%", { plain = true }))
      if not name or #name == 0 then
        dir, branch = unpack(vim.split(file, "%%", { plain = true }))
        index = dir
      else
        index = dir .. "_" .. name
      end
      dir = dir:gsub("%%", "/")
      if jit.os:find("Windows") then
        dir = dir:gsub("^(%w)/", "%1:/")
      end
      if not have[index] then
        have[index] = true
        items[#items + 1] = { session = session, dir = dir, name = name, branch = branch }
      end
    end
  end
  vim.ui.select(items, {
    prompt = "Select a session: ",
    format_item = function(item)
      local formatted = ""
      if item.name then
        formatted = "\"" .. item.name .. "\": "
      end
      formatted = formatted .. vim.fn.fnamemodify(item.dir, ":p:~")
      return formatted
    end,
  }, function(item)
    if item then
      vim.fn.chdir(item.dir)
      M.sessionname(item.name)
      M.load()
    end
  end)
end

--- get current branch name
---@return string?
function M.branch()
  if uv.fs_stat(".git") then
    local ret = vim.fn.systemlist("git branch --show-current")[1]
    return vim.v.shell_error == 0 and ret or nil
  end
end

--- remove an existing session
---@param session string
---@param opts? { notify?: boolean }
function M.delete(session, opts)
  if not session then
    return
  end

  local isInConfigDir, startOfFile = string.find(session, Config.options.dir)
  if not isInConfigDir or isInConfigDir ~= 1 then
    vim.notify("Session to be deleted must be inside configured dir (\"" .. Config.options.dir .. "\").", vim.log.levels.ERROR)
    return
  end

  opts = opts or {}

  if vim.fn.filewritable(session) then
    vim.fn.delete(session)
    if opts.notify and startOfFile then -- startOfFile will never be nil (or we would have returned earlier)
      local filename = string.sub(session, startOfFile) -- filename will neither be nil nor empty because of filewritable
      local nameSeparator = string.find(filename, "%%%")
      if nameSeparator then
        local startOfName = nameSeparator + 3
        nameSeparator = string.find(filename, "%%%")
        filename = string.sub(filename, startOfName, nameSeparator)
      else
        filename = string.gsub(filename, "%%", "/")
      end
      vim.notify("Deleted session \"" .. filename .. "\".", vim.log.levels.WARN)
    end
  else
    vim.notify("Missing permission to delete session file (\"" .. session .. "\").", vim.log.levels.ERROR)
  end
end

--- get/set current session name
--- If a name is provided (must consist of at least one character), it is set as the new session name.
--- Also, if a name is provided, the session will be saved immediately.
--- The session name that was stored before this function call is returned, if one was set.
--- If opts.notify is set to true, a notification is generated.
--- If opts.deletedSession is set to true and the current session is already stored, that session is deleted.
---
---@param name? string
---@param opts? { notify?: boolean, deleteOldSession?: boolean }
---@return string?
function M.sessionname(name, opts)
  if not name then
    return M._sessionname
  elseif #name == 0 then
    vim.notify("Empty sessionname is illegal.", vim.log.levels.ERROR)
    return M._sessionname
  end

  opts = opts or {}

  local deletedSession = nil
  if opts.deleteOldSession then
    deletedSession = M.current()
    if vim.fn.filewritable(deletedSession) then
      M.delete(deletedSession)
    end
  end

  local oldName = M._sessionname
  M._sessionname = name or oldName
  M.save()

  if opts.notify and oldName and deletedSession then
    vim.notify("Renamed session from \"" .. oldName .. "\" to \"" .. name .. "\".", vim.log.levels.INFO)
  elseif opts.notify and oldName then
    vim.notify("Continue session \"" .. oldName .. "\" as \"" .. name .. "\".", vim.log.levels.INFO)
  elseif opts.notify and deletedSession then
    vim.notify("Continue session as \"" .. name .. "\".", vim.log.levels.INFO)
  elseif opts.notify then
    vim.notify("Current session stored as \"" .. name .. "\".", vim.log.levels.INFO)
  end

  if oldName then
    return oldName
  end
end

return M
