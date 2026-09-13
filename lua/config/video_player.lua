local M = {}

local group = vim.api.nvim_create_augroup("ExternalVideoPlayer", { clear = true })
local jobs = {}
local initialized = {}
local REMOTE_VIDEO_HOST = "mac-mini-m4"

local function base64_encode(data)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local result = {}
    for i = 1, #data, 3 do
        local a = data:byte(i) or 0
        local b = data:byte(i + 1) or 0
        local c = data:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        result[#result + 1] = alphabet:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result + 1] = alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        if i + 1 <= #data then
            result[#result + 1] = alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
        else
            result[#result + 1] = "="
        end
        if i + 2 <= #data then
            result[#result + 1] = alphabet:sub(n % 64 + 1, n % 64 + 1)
        else
            result[#result + 1] = "="
        end
    end
    return table.concat(result)
end

local function notify_local_player(path)
    -- SSH_CONNECTION はリモートシェルでのみ設定されるため、ローカル
    -- 動画を開いたときには通知を送らない。
    if not vim.env.SSH_CONNECTION or vim.env.SSH_CONNECTION == "" then return end
    if not ssh_local_mirror_enabled() then return end
    local token = tostring(vim.uv.hrtime())
    local value = REMOTE_VIDEO_HOST .. "\t" .. path .. "\t" .. token
    local sequence = string.char(27) .. "]1337;SetUserVar=CODEX_REMOTE_VIDEO=" .. base64_encode(value) .. string.char(7)
    -- v:stderr はNeovimが接続している端末へ直接書き込むチャンネル。
    vim.fn.chansend(vim.v.stderr, sequence)
end

local function video_name(buf)
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

local function show_error(message)
    vim.api.nvim_echo({ { message, "ErrorMsg" } }, true, {})
    vim.notify(message, vim.log.levels.ERROR, { title = "Video Player" })
end

local function prepare_buffer(buf)
    local output_note
    if vim.env.SSH_CONNECTION then
        output_note = "  SSH経由：接続元PCへストリーミング再生します。"
    else
        output_note = "  再生は、この Neovim を実行しているホストから出力されます。"
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "",
        "  Video Player",
        "",
        "  File:   " .. video_name(buf),
        "  Status: 外部ウィンドウで再生中",
        "",
        "  ffplay のウィンドウを閉じると再生終了",
        "  f       フルスクリーン切り替え",
        "  Space   一時停止 / 再開",
        "  ← / →  10秒戻る / 進む",
        "  q       このバッファを閉じる",
        "",
        output_note,
    })
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "video_player"
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
    vim.opt_local.signcolumn = "no"
end

local function open_video(buf)
    if initialized[buf] then return end
    initialized[buf] = true
    local path = vim.api.nvim_buf_get_name(buf)
    prepare_buffer(buf)

    -- SSH中はリモート側のffplayを起動せず、WezTermへ通知して接続元PCで
    -- ストリーミング再生するため、ここでffplayの存在を検査しない。
    if (not vim.env.SSH_CONNECTION or vim.env.SSH_CONNECTION == "") and vim.fn.executable("ffplay") ~= 1 then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "  Status: エラー（ffplay が見つかりません）" })
        vim.bo[buf].modifiable = false
        show_error("動画再生には ffplay が必要です: " .. path)
        return
    end

    notify_local_player(path)
    if vim.env.SSH_CONNECTION and vim.env.SSH_CONNECTION ~= "" then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "  Status: 接続元PCへストリーミング再生を開始しました" })
        vim.bo[buf].modifiable = false
        return
    end

    local stderr = {}
    local job = vim.fn.jobstart({
        "ffplay",
        "-autoexit",
        "-loglevel",
        "error",
        "-window_title",
        video_name(buf),
        path,
    }, {
        stderr_buffered = true,
        stdout_buffered = true,
        on_stderr = function(_, data)
            if data then stderr = data end
        end,
        on_exit = function(_, code)
            vim.schedule(function()
                if jobs[buf] ~= job then return end
                jobs[buf] = nil
                if not vim.api.nvim_buf_is_valid(buf) then return end
                if code == 0 or code == 255 then
                    vim.bo[buf].modifiable = true
                    vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "  Status: 再生終了" })
                    vim.bo[buf].modifiable = false
                else
                    local detail = table.concat(stderr, " "):gsub("%s+", " ")
                    if detail == "" then detail = "ffplay が終了コード " .. code .. " を返しました" end
                    vim.bo[buf].modifiable = true
                    vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "  Status: エラー: " .. detail })
                    vim.bo[buf].modifiable = false
                    show_error("動画再生失敗: " .. detail)
                end
            end)
        end,
    })

    if job <= 0 then
        show_error("ffplay を起動できません: " .. path)
        return
    end
    jobs[buf] = job
end

local patterns = {
    "*.mp4", "*.mkv", "*.mov", "*.avi", "*.webm", "*.wmv", "*.m4v", "*.flv",
    "*.ts", "*.mts", "*.m2ts", "*.3gp", "*.ogv",
    "*.MP4", "*.MKV", "*.MOV", "*.AVI", "*.WEBM", "*.WMV", "*.M4V", "*.FLV",
    "*.TS", "*.MTS", "*.M2TS", "*.3GP", "*.OGV",
}

function M.setup()
    vim.api.nvim_create_autocmd("BufReadCmd", {
        group = group,
        pattern = patterns,
        callback = function(event)
            open_video(event.buf)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        pattern = patterns,
        callback = function(event)
            local job = jobs[event.buf]
            if job then vim.fn.jobstop(job) end
            jobs[event.buf] = nil
            initialized[event.buf] = nil
        end,
    })
end

return M
