local M = {}

local group = vim.api.nvim_create_augroup("TerminalAudioPlayer", { clear = true })
local sessions = {}
local BAR_WIDTH = 48
local PROGRESS_LINE = 6

local function filename(buf)
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~")
end

local function format_time(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function current_position(session)
    if not session.job or not session.started_at then return session.position end
    return math.min(session.duration, session.position + (vim.uv.hrtime() - session.started_at) / 1e9)
end

local function set_screen(buf, status)
    local session = sessions[buf]
    if not session or not vim.api.nvim_buf_is_valid(buf) then return end
    local position = current_position(session)
    local ratio = session.duration > 0 and math.min(1, position / session.duration) or 0
    local filled = math.floor(ratio * BAR_WIDTH)
    local bar = string.rep("█", filled) .. string.rep("░", BAR_WIDTH - filled)
    local time = session.duration > 0 and string.format("%s / %s", format_time(position), format_time(session.duration)) or "長さを取得できません"

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "", "  Audio Player", "", "  File:   " .. filename(buf), "  Status: " .. status,
        "  [" .. bar .. "]  " .. time, "", "  <Space> / <Enter>  再生・一時停止",
        "  s                  停止して先頭へ戻る", "  進捗バーをクリック  その位置へ移動",
        "  q                  バッファを閉じる", "", "  再生は、この Neovim を実行しているホストから出力されます。",
    })
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
end

local function stop_timer(session)
    if session.timer then session.timer:stop() end
end

local function start_timer(buf)
    local session = sessions[buf]
    if not session then return end
    if not session.timer then session.timer = vim.uv.new_timer() end
    session.timer:start(0, 200, vim.schedule_wrap(function()
        local current = sessions[buf]
        if not current or not current.job then
            stop_timer(session)
            return
        end
        set_screen(buf, "再生中")
    end))
end

local function stop_job(session)
    if not session.job then return end
    session.position = current_position(session)
    local job = session.job
    session.job = nil
    session.started_at = nil
    stop_timer(session)
    vim.fn.jobstop(job)
end

local function start(session, buf)
    if vim.fn.executable("ffplay") ~= 1 then
        local message = "音声再生に ffplay が必要です"
        set_screen(buf, "エラー: " .. message)
        vim.api.nvim_echo({ { message, "ErrorMsg" } }, true, {})
        return
    end

    local errors = {}
    local job = vim.fn.jobstart({ "ffplay", "-nodisp", "-autoexit", "-loglevel", "error", "-ss", string.format("%.3f", session.position), session.path }, {
        stderr_buffered = true,
        on_stderr = function(_, data)
            if data then errors = data end
        end,
        on_exit = function(_, code)
            vim.schedule(function()
                if sessions[buf] ~= session or session.job ~= job then return end
                session.job = nil
                session.started_at = nil
                stop_timer(session)
                if session.paused then return end
                if code == 0 then
                    session.position = session.duration
                    set_screen(buf, "再生終了")
                else
                    local detail = table.concat(errors, " "):gsub("%s+", " ")
                    if detail == "" then detail = "ffplay が終了コード " .. code .. " を返しました" end
                    set_screen(buf, "エラー: " .. detail)
                    vim.api.nvim_echo({ { "音声再生失敗: " .. detail, "ErrorMsg" } }, true, {})
                    vim.notify("音声再生失敗: " .. detail, vim.log.levels.ERROR, { title = "Audio Player" })
                end
            end)
        end,
    })
    if job <= 0 then
        local message = "ffplay を起動できません"
        set_screen(buf, "エラー: " .. message)
        vim.api.nvim_echo({ { message, "ErrorMsg" } }, true, {})
        return
    end
    session.job = job
    session.started_at = vim.uv.hrtime()
    session.paused = false
    set_screen(buf, "再生中")
    start_timer(buf)
end

local function toggle(buf)
    local session = sessions[buf]
    if not session then return end
    if session.job then
        session.paused = true
        stop_job(session)
        set_screen(buf, "一時停止")
    else
        if session.duration > 0 and session.position >= session.duration then session.position = 0 end
        start(session, buf)
    end
end

local function reset(buf)
    local session = sessions[buf]
    if not session then return end
    stop_job(session)
    session.position = 0
    session.paused = false
    set_screen(buf, "停止")
end

local function seek(buf, ratio)
    local session = sessions[buf]
    if not session or session.duration <= 0 then return end
    local was_playing = session.job ~= nil
    stop_job(session)
    session.position = math.max(0, math.min(session.duration, session.duration * ratio))
    if was_playing then start(session, buf) else set_screen(buf, "一時停止") end
end

local function probe_duration(path)
    if vim.fn.executable("ffprobe") ~= 1 then return 0 end
    local result = vim.system({ "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", path }, { text = true }):wait()
    return result.code == 0 and tonumber(result.stdout) or 0
end

local function open_audio(buf)
    local path = vim.api.nvim_buf_get_name(buf)
    sessions[buf] = { path = path, position = 0, duration = probe_duration(path), paused = false }
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "audio_player"
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
    vim.opt_local.signcolumn = "no"
    set_screen(buf, "待機中")
    local opts = { buffer = buf, silent = true }
    vim.keymap.set("n", "<Space>", function() toggle(buf) end, opts)
    vim.keymap.set("n", "<CR>", function() toggle(buf) end, opts)
    vim.keymap.set("n", "s", function() reset(buf) end, opts)
    vim.keymap.set("n", "q", function() vim.cmd("bdelete") end, opts)
    vim.keymap.set("n", "<LeftMouse>", function()
        local mouse = vim.fn.getmousepos()
        if mouse.line ~= PROGRESS_LINE then return end
        seek(buf, (mouse.column - 4) / BAR_WIDTH)
    end, opts)
end

function M.setup()
    vim.opt.mouse = "a"
    local patterns = { "*.mp3", "*.m4a", "*.aac", "*.wav", "*.flac", "*.ogg", "*.opus", "*.wma", "*.MP3", "*.M4A", "*.AAC", "*.WAV", "*.FLAC", "*.OGG", "*.OPUS", "*.WMA" }
    vim.api.nvim_create_autocmd("BufReadCmd", { group = group, pattern = patterns, callback = function(event) open_audio(event.buf) end })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        pattern = patterns,
        callback = function(event)
            local session = sessions[event.buf]
            if session then
                stop_job(session)
                if session.timer then session.timer:close() end
            end
            sessions[event.buf] = nil
        end,
    })
end

return M
