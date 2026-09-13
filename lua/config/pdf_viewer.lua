local M = {}

local group = vim.api.nvim_create_augroup("ExternalPdfViewer", { clear = true })
local jobs = {}
local initialized = {}
local REMOTE_PDF_HOST = "mac-mini-m4"

local function is_ssh()
    return vim.env.SSH_CONNECTION ~= nil and vim.env.SSH_CONNECTION ~= ""
end

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
        result[#result + 1] = i + 1 <= #data and alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
        result[#result + 1] = i + 2 <= #data and alphabet:sub(n % 64 + 1, n % 64 + 1) or "="
    end
    return table.concat(result)
end

local function pdf_name(buf)
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

local function show_error(message)
    vim.api.nvim_echo({ { message, "ErrorMsg" } }, true, {})
    vim.notify(message, vim.log.levels.ERROR, { title = "PDF Viewer" })
end

local function viewer_command(path)
    if vim.fn.executable("zathura") == 1 then
        return { "zathura", path }, "Zathura"
    end
    if vim.fn.has("mac") == 1 and vim.fn.executable("open") == 1 then
        return { "open", "-a", "Preview", path }, "Preview"
    end
    if vim.fn.executable("evince") == 1 then
        return { "evince", path }, "Evince"
    end
    if vim.fn.executable("okular") == 1 then
        return { "okular", path }, "Okular"
    end
    if vim.fn.executable("xdg-open") == 1 then
        return { "xdg-open", path }, "既定のPDFビューア"
    end
end

local function set_status(buf, status)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines < 6 then
        lines = { "", "  PDF Viewer", "", "  File: " .. pdf_name(buf), "", "" }
    end
    lines[5] = "  Status: " .. status
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

local function prepare_buffer(buf)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "",
        "  PDF Viewer",
        "",
        "  File:   " .. pdf_name(buf),
        "  Status: 起動中…",
        "",
        "  PDFは外部ビューアで表示します。",
        "  LilyPondなどで更新すると、ビューア側へ反映されます。",
        "",
        "  q       このバッファを閉じる",
    })
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "pdf_viewer"
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
    vim.opt_local.signcolumn = "no"
end

local function notify_remote(path)
    local token = tostring(vim.uv.hrtime())
    local value = REMOTE_PDF_HOST .. "\t" .. path .. "\t" .. token
    local sequence = string.char(27) .. "]1337;SetUserVar=CODEX_REMOTE_PDF=" .. base64_encode(value) .. string.char(7)
    vim.fn.chansend(vim.v.stderr, sequence)
end

local function open_pdf(buf)
    if initialized[buf] then return end
    initialized[buf] = true
    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" then return end

    local remote = is_ssh()
    local command, label = viewer_command(path)
    if not remote and not command then
        initialized[buf] = nil
        show_error("PDFビューアが見つかりません。Zathura、Evince、またはOSの既定ビューアをインストールしてください")
        return
    end

    vim.b[buf].pdf_external_viewer = true
    prepare_buffer(buf)

    if remote then
        notify_remote(path)
        set_status(buf, "接続元PCのPDFビューアへ転送中（更新を監視）")
        return
    end

    local stderr = {}
    local job = vim.fn.jobstart(command, {
        detach = true,
        stderr_buffered = true,
        on_stderr = function(_, data) if data then stderr = data end end,
        on_exit = function(_, code)
            vim.schedule(function()
                if jobs[buf] ~= job then return end
                jobs[buf] = nil
                if not vim.api.nvim_buf_is_valid(buf) then return end
                if code == 0 or code == 255 then
                    set_status(buf, label .. "を終了しました")
                else
                    local detail = table.concat(stderr, " "):gsub("%s+", " ")
                    if detail == "" then detail = "終了コード " .. code end
                    set_status(buf, "エラー: " .. detail)
                    show_error("PDFビューアの起動に失敗しました: " .. detail)
                end
            end)
        end,
    })
    if job <= 0 then
        vim.b[buf].pdf_external_viewer = nil
        show_error("PDFビューアを起動できません: " .. path)
        return
    end
    jobs[buf] = job
    set_status(buf, label .. "で表示中")
end

function M.setup()
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = group,
        pattern = { "*.pdf", "*.PDF" },
        callback = function(event)
            if vim.api.nvim_buf_is_valid(event.buf) then open_pdf(event.buf) end
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        pattern = { "*.pdf", "*.PDF" },
        callback = function(event)
            local job = jobs[event.buf]
            if job then vim.fn.jobstop(job) end
            jobs[event.buf] = nil
            initialized[event.buf] = nil
        end,
    })
end

return M
