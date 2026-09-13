local M = {}

local augroup = vim.api.nvim_create_augroup("PdfPreview", { clear = true })
local rendering = {}
local watchers = {}
local refresh_pending = {}
local pdf_state = {}

local function one_line(text)
    local result = (text or "")
        :gsub("[\r\n]+", " ")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    if #result > 360 then
        return result:sub(1, 357) .. "…"
    end
    return result
end

local function show_error(path, detail)
    local message = string.format("PDF プレビュー失敗: %s — %s", vim.fn.fnamemodify(path, ":t"), one_line(detail))
    vim.api.nvim_echo({ { message, "ErrorMsg" } }, true, {})
    vim.notify(message, vim.log.levels.ERROR, { title = "PDF Preview" })
end

local function get_page_count(path)
    if vim.fn.executable("pdfinfo") == 1 then
        local lines = vim.fn.systemlist({ "pdfinfo", path })
        for _, line in ipairs(lines) do
            local pages = line:match("^Pages:%s*(%d+)")
            if pages then return tonumber(pages) end
        end
    end

    -- macOS Homebrew installations often provide ImageMagick but not pdfinfo.
    if vim.fn.executable("magick") == 1 then
        local lines = vim.fn.systemlist({ "magick", "identify", "-ping", "-format", "%n\n", path })
        local pages = tonumber(lines[1])
        if pages and pages > 0 then return pages end
    elseif vim.fn.executable("identify") == 1 then
        local lines = vim.fn.systemlist({ "identify", "-ping", "-format", "%n\n", path })
        local pages = tonumber(lines[1])
        if pages and pages > 0 then return pages end
    end
end

local function renderer_command(path, output, page)
    if vim.fn.executable("pdftoppm") == 1 then
        local prefix = output:gsub("%.png$", "")
        return { "pdftoppm", "-f", tostring(page), "-l", tostring(page), "-singlefile", "-r", "144", "-png", path, prefix }
    end
    if vim.fn.executable("magick") == 1 then
        return { "magick", "-density", "144", path .. "[" .. (page - 1) .. "]", "-strip", "-quality", "90", output }
    end
    if vim.fn.executable("convert") == 1 then
        return { "convert", "-density", "144", path .. "[" .. (page - 1) .. "]", "-strip", "-quality", "90", output }
    end
end

local function prepare_buffer(buf, win)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, true, { "" })
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nowrite"
    vim.bo[buf].filetype = "image_nvim"
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_win_call(win, function()
            vim.opt_local.colorcolumn = "0"
            vim.opt_local.cursorline = false
            vim.opt_local.number = false
            vim.opt_local.signcolumn = "no"
        end)
    end
end

local preview_pdf
local render_png

local function set_page_keymaps(buf, win)
    local function move(delta)
        if not vim.api.nvim_win_is_valid(win) then return end
        local state = pdf_state[buf]
        if not state then return end
        local page = state.page + delta
        if state.pages and (page < 1 or page > state.pages) then
            vim.api.nvim_echo({ { string.format("PDF: %d / %d ページ（これ以上ありません）", state.page, state.pages), "WarningMsg" } }, false, {})
            return
        end
        vim.api.nvim_echo({ { string.format("PDF ページ %d を読み込み中…", page), "ModeMsg" } }, false, {})
        preview_pdf(buf, win, page)
    end

    for _, lhs in ipairs({ "]", "<Right>" }) do
        vim.keymap.set("n", lhs, function() move(1) end, { buffer = buf, silent = true, nowait = true, desc = "次のPDFページ" })
    end
    for _, lhs in ipairs({ "[", "<Left>" }) do
        vim.keymap.set("n", lhs, function() move(-1) end, { buffer = buf, silent = true, nowait = true, desc = "前のPDFページ" })
    end
end

preview_pdf = function(buf, win, requested_page, force_page_count)
    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" or path:lower():sub(-4) ~= ".pdf" or rendering[buf] then return end

    local stat = vim.uv.fs_stat(path)
    if not stat then
        show_error(path, "ファイルを読み取れません")
        return
    end

    local state = pdf_state[buf] or { page = 1, pages = nil }
    pdf_state[buf] = state
    if force_page_count or not state.pages then
        state.pages = get_page_count(path)
    end
    local page = requested_page or state.page or 1
    if state.pages then page = math.max(1, math.min(page, state.pages)) end

    local cache_dir = vim.fn.stdpath("cache") .. "/pdf-preview"
    vim.fn.mkdir(cache_dir, "p")
    local output = string.format("%s/%s-page-%d.png", cache_dir, vim.fn.sha256(path .. stat.mtime.sec .. stat.size), page)
    local command = renderer_command(path, output, page)
    if not command then
        show_error(path, "PDF 変換コマンドがありません（pdftoppm または ImageMagick が必要です）")
        return
    end

    rendering[buf] = true
    vim.api.nvim_echo({ { string.format("PDF ページ %d%sを画像に変換中…", page, state.pages and (" / " .. state.pages) or ""), "ModeMsg" } }, false, {})
    vim.system(command, { text = true }, function(result)
        vim.schedule(function()
            rendering[buf] = nil
            if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then return end
            if vim.api.nvim_win_get_buf(win) ~= buf then return end
            if result.code ~= 0 or vim.fn.filereadable(output) == 0 then
                local detail = result.stderr ~= "" and result.stderr or result.stdout
                if detail == "" then detail = "変換コマンドが終了コード " .. result.code .. " を返しました" end
                show_error(path, detail)
                return
            end

            state.page = page
            render_png(output, win, buf, path, page, state.pages)
        end)
    end)
end

render_png = function(output, win, buf, path, page, pages)
    local image = require("image")
    for _, old_image in ipairs(image.get_images({ window = win, buffer = buf })) do
        old_image:clear()
    end

    prepare_buffer(buf, win)
    local ok, new_image = pcall(image.from_file, output, { window = win, buffer = buf, x = 0, y = 0 })
    if not ok or not new_image then
        show_error(path, new_image or "PNG プレビューの準備に失敗しました")
        return
    end
    new_image:render()
    set_page_keymaps(buf, win)
    vim.api.nvim_echo({ { string.format("PDF ページ %d%s — [ / ] または ← / → で移動", page, pages and (" / " .. pages) or ""), "ModeMsg" } }, false, {})
end

local function watch_pdf(buf, win)
    local path = vim.api.nvim_buf_get_name(buf)
    if watchers[buf] or path == "" then return end

    local directory = vim.fn.fnamemodify(path, ":h")
    local filename = vim.fn.fnamemodify(path, ":t")
    local watcher = vim.uv.new_fs_event()
    local ok, err = watcher:start(directory, {}, function(watch_err, changed_name)
        if watch_err then
            vim.schedule(function() show_error(path, watch_err) end)
            return
        end
        if changed_name and changed_name ~= filename then return end
        if refresh_pending[buf] then return end

        refresh_pending[buf] = true
        vim.defer_fn(function()
            refresh_pending[buf] = nil
            if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_echo({ { "PDF の更新を再描画中…", "ModeMsg" } }, false, {})
                preview_pdf(buf, win, nil, true)
            end
        end, 500)
    end)

    if not ok then
        watcher:close()
        show_error(path, "PDF 更新の監視を開始できません: " .. tostring(err))
        return
    end
    watchers[buf] = watcher
end

function M.setup()
    vim.api.nvim_create_autocmd({ "BufWinEnter", "TabEnter" }, {
        group = augroup,
        pattern = { "*.pdf", "*.PDF" },
        callback = function(event)
            local win = vim.api.nvim_get_current_win()
            vim.schedule(function()
                if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == event.buf then
                    preview_pdf(event.buf, win)
                    watch_pdf(event.buf, win)
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = augroup,
        pattern = { "*.pdf", "*.PDF" },
        callback = function(event)
            if watchers[event.buf] then watchers[event.buf]:close() end
            watchers[event.buf] = nil
            refresh_pending[event.buf] = nil
            pdf_state[event.buf] = nil
            rendering[event.buf] = nil
        end,
    })
end

return M
