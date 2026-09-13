-- ~/.config/nvim/lua/config/lazy.lua
-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
    local lazyrepo = "https://github.com/folke/lazy.nvim.git"
    local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
    if vim.v.shell_error ~= 0 then
        vim.api.nvim_echo({
            { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
            { out,                            "WarningMsg" },
            { "\nPress any key to exit..." },
        }, true, {})
        vim.fn.getchar()
        os.exit(1)
    end
end
vim.opt.rtp:prepend(lazypath)

-- 【基本設定】
vim.opt.termguicolors = true  -- フルカラーを有効にする
vim.opt.number = true         -- 行番号を表示
vim.opt.relativenumber = true -- 現在行からの相対的な番号を表示
vim.opt.cursorline = true     -- 現在行をハイライト

-- 【キーマップ共通設定】
local keymap = vim.keymap.set
local opts = { noremap = true, silent = true }

-- 【Esc対策マッピング】
-- QWERTY配列の右手ホームポジションで最もスムーズに抜けられる設定っす！
keymap('i', 'jj', '<Esc>', opts)

-- 【表示・検索系】
vim.opt.ignorecase = true -- 検索時に大文字小文字を区別しない
vim.opt.smartcase = true  -- 検索文字に大文字が含まれていたら区別する
vim.opt.incsearch = true  -- 検索文字を入力してるそばからヒットさせる
vim.opt.wrapscan = true   -- ファイルの最後まで検索したら最初に戻る
vim.opt.hlsearch = true   -- 検索結果をハイライトする（消したい時は :noh）
-- vim.opt.guicursor = "n-i:ver25" -- ノーマルモードでのカーソルを補足して文字のどちら側にいるのかわかるようにする。

-- 【編集系】
vim.opt.expandtab = true          -- タブ入力を空白に変換
vim.opt.shiftwidth = 4            -- 自動インデントの幅
vim.opt.tabstop = 4               -- タブが占める幅
vim.opt.smartindent = true        -- 改行時に自動でインデントを入れる
vim.opt.clipboard = "unnamedplus" -- クリップボードをOS（Mac/Ubuntu）と共有
-- ビジュアルモード（選択中）で Tab を押すと右へ、S-Tab で左へ（選択範囲を維持）
keymap('v', '<Tab>', '>gv', opts)
keymap('v', '<S-Tab>', '<gv', opts)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Setup lazy.nvim
require("lazy").setup({
    spec = {
        -- import your plugins
        { import = "plugins" },
    },
    install = { colorscheme = { "habamax" } },
    checker = { enabled = true },
})

-- set transparent background for floats/terminal buffers
vim.api.nvim_set_hl(0, "Normal", { bg = "NONE" })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "NONE" })
vim.api.nvim_set_hl(0, "SignColumn", { bg = "NONE" })
vim.api.nvim_set_hl(0, "Terminal", { bg = "NONE" })


-- 【VS Code風ファイルタブ切り替え】
keymap('n', '<S-h>', ':bprevious<CR>', opts) -- 左のファイルタブへ移動
keymap('n', '<S-l>', ':bnext<CR>', opts)     -- 右のファイルタブへ移動
keymap('n', 'tc', function()
    local current_buf = vim.api.nvim_get_current_buf()

    -- NvimTreeの上で誤爆したときは何もしないガードっす
    if vim.bo[current_buf].filetype == "NvimTree" then
        return
    end

    local buffers = vim.fn.getbufinfo({ buflisted = 1 })
    if #buffers <= 1 then
        vim.cmd("enew")
        vim.cmd("bd " .. current_buf)
    else
        vim.cmd("bnext")
        vim.cmd("bd " .. current_buf)
    end
end, opts) -- 現在のファイルタブを閉じる

----------------------------------------------------
-- 【NEW】ファイルタブの並び順を入れ替える設定っす！
----------------------------------------------------
-- Alt + h で、今見ているタブを「左」に移動させるっす
keymap('n', '<A-h>', ':BufferLineMovePrev<CR>', opts)
-- Alt + l で、今見ているタブを「右」に移動させるっす
keymap('n', '<A-l>', ':BufferLineMoveNext<CR>', opts)

-- テキスト変更時やインサートモードを抜けた時に自動保存

-- 【自動保存 ＆ LilyPondコンパイルの一体化設定】
-- LilyPondは楽譜を書くためのフリーソフトです
-- コンパイル処理の連打防止用変数と、出力バッファをグローバルに保持しておくっす
local lilypond_job_id = nil
local lilypond_out_buf = nil

-- 【自動保存 ＆ LilyPondコンパイルの一体化設定】
-- LilyPondは楽譜を書くためのフリーソフトです
vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
    pattern = "*",
    callback = function()
        -- 1. 変更があり、かつ通常のファイルバッファの場合のみ保存を実行
        if vim.bo.modified and vim.bo.buftype == "" then
            vim.cmd("write")

            -- 2. もし保存したファイルがLilyPond(.ly)だった場合、その直後に非同期コンパイルを実行
            if vim.fn.expand("%:e") == "ly" then
                -- 編集中のファイルの階層から親ディレクトリに向かって main.ly を探索（プロジェクトルートの特定）
                local current_file_dir = vim.fn.expand("%:p:h")
                local main_file = vim.fs.find("main.ly", { upward = true, path = current_file_dir })[1]
                local target_file = main_file or vim.fn.expand("%:p")

                -- 前回のコンパイル処理がまだ終わっていなければキャンセル（多重実行によるフリーズ防止）
                if lilypond_job_id then
                    vim.fn.jobstop(lilypond_job_id)
                end

                -- リアルタイム出力用の専用バッファ（画面）を準備
                if not lilypond_out_buf or not vim.api.nvim_buf_is_valid(lilypond_out_buf) then
                    lilypond_out_buf = vim.api.nvim_create_buf(false, true)
                    vim.api.nvim_buf_set_name(lilypond_out_buf, "LilyPond_Output")
                end

                -- 画面下部に10行分のスペースで分割表示（すでに表示されていれば何もしないっす）
                local win_found = false
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_get_buf(win) == lilypond_out_buf then
                        win_found = true
                        break
                    end
                end

                if not win_found then
                    local cur_win = vim.api.nvim_get_current_win()
                    vim.cmd("botright 10split")
                    local new_win = vim.api.nvim_get_current_win()
                    vim.api.nvim_win_set_buf(new_win, lilypond_out_buf)
                    vim.api.nvim_set_current_win(cur_win) -- フォーカスは元のコード編集画面に戻すっす
                end

                -- コンパイル開始時にバッファの中身をリセットしてヘッダーを表示
                vim.api.nvim_buf_set_lines(lilypond_out_buf, 0, -1, false, {
                    "--- LilyPond コンパイル開始 ---",
                    "Target: " .. target_file,
                    "--------------------------------"
                })

                -- ログを行単位でバッファに追記していく関数
                local append_log = function(_, data)
                    if not data then return end

                    local lines = {}
                    for _, v in ipairs(data) do
                        table.insert(lines, v)
                    end

                    -- Neovimの仕様で末尾に空文字列が必ず入るため除去
                    if lines[#lines] == "" then
                        table.remove(lines, #lines)
                    end

                    if #lines > 0 then
                        local line_count = vim.api.nvim_buf_line_count(lilypond_out_buf)
                        vim.api.nvim_buf_set_lines(lilypond_out_buf, line_count, line_count, false, lines)

                        -- ウィンドウを一番下まで自動スクロール
                        for _, win in ipairs(vim.api.nvim_list_wins()) do
                            if vim.api.nvim_win_get_buf(win) == lilypond_out_buf then
                                local new_count = vim.api.nvim_buf_line_count(lilypond_out_buf)
                                vim.api.nvim_win_set_cursor(win, { new_count, 0 })
                            end
                        end
                    end
                end

                -- コンパイル処理の実行（stdout_bufferedをfalseにしてリアルタイム出力）
                lilypond_job_id = vim.fn.jobstart({ "lilypond", target_file }, {
                    stdout_buffered = false,
                    stderr_buffered = false,
                    on_stdout = append_log,
                    on_stderr = append_log,
                    on_exit = function(_, code)
                        if code == 0 then
                            -- コンパイル成功時は出力ウィンドウを閉じるっす
                            for _, win in ipairs(vim.api.nvim_list_wins()) do
                                if vim.api.nvim_win_get_buf(win) == lilypond_out_buf then
                                    vim.api.nvim_win_close(win, true)
                                    break
                                end
                            end
                            vim.notify("LilyPond: コンパイル成功！", vim.log.levels.INFO)
                        else
                            -- エラー時はログが確認できるようにウィンドウを残すっす
                            local line_count = vim.api.nvim_buf_line_count(lilypond_out_buf)
                            vim.api.nvim_buf_set_lines(lilypond_out_buf, line_count, line_count, false,
                                { "", "=== エラー終了 ===" })
                        end
                        lilypond_job_id = nil
                    end
                })
            end
        end
    end,
})
