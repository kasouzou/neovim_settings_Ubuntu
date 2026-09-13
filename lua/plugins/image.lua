return {
    {
        "3rd/image.nvim",
        build = false, -- READMEの指示通り、magick_cliを使う場合はビルドを走らせない設定にするっす
        dependencies = {
            -- Lua用の画像処理バインディングをビルドするためにluarocksが必要っす
            { "vhyrro/luarocks.nvim", priority = 1000, config = true },
        },
        opts = {
            backend = "sixel", -- WezTermはKittyプロトコルに対応してるのでこれで固定っす！ （※公式READMEに基づき、WezTermでより安定するsixelに変更したっす）
            processor = "magick_cli",
            -- Linux環境に合わせて大文字の拡張子（*.JPG, *.PNGなど）もパターンに明示的に追加したっす！
            hijack_file_patterns = { "*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp", "*.avif", "*.PNG", "*.JPG", "*.JPEG", "*.GIF", "*.WEBP" },
            integrations = {
                markdown = {
                    enabled = true,
                    clear_in_insert_mode = false,
                    download_remote_images = true, -- リモート（URL）の画像も自動ダウンロードして表示するっす
                    only_render_image_at_cursor = false,
                    filetypes = { "markdown", "vimwiki" },
                },
            },
            max_width = nil,
            max_height = nil,
            max_width_window_percentage = nil,
            max_height_window_percentage = 50, -- 画像がデカすぎるときにウィンドウの50%に収める設定っす
            window_overlap_clear_enabled = false,
            pipe_path = nil,
        },
        config = function(_, opts)
            require("image").setup(opts)
            require("config.pdf_preview").setup()
        end,
    },
}
