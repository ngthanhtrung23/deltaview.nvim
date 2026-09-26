local M = {}
local utils = require('deltaview.utils')
local config = require('deltaview.config')
local help = require('deltaview.help')
local _echo_timer = nil
local _cmdline_cr_registered = false
--- @type table<number, fun()> refresh callbacks keyed by bufnr, cleaned up on BufUnload
M._refresh_fns = {}
--- @type table<number, fun(cur_row: number, target_line: number): number|nil>
M._line_redirect_handlers = {}
--- Fold metadata keyed by bufnr → foldstart_row → metadata table.
--- Read by deltaview_foldtext() to render the summary line.
--- @type table<number, table<number, {kind: string, label: string, added: number, removed: number, line_count: number}>>
M._fold_metadata = {}
--- Fold state stashed during BufUnload so BufReadCmd (which fires after BufUnload
--- for acwrite buffers) can pick it up even though _fold_metadata is already cleared.
--- @type table<number, table[]>
M._reload_fold_stash = {}
--- Viewport (winsaveview) stashed during BufUnload for the same reason: by the time
--- BufReadCmd fires, Neovim has cleared the buffer so winsaveview() returns {lnum=1}.
--- @type table<number, table>
M._reload_view_stash = {}
--- @type {rel_path: string|nil, new_line_num: number, data_idx: number} | nil
M._post_revert_target = nil

--- deltaview file diff buffer orchestrator, opens a deltaview diff on top of current window
--- Applies all diff highlights to a buffer (artifact decorations, syntax, word-level diff).
--- @param bufnr number
--- Automatically folds file sections whose changed-line count exceeds the threshold.
--- Called after setup_fold_navigation so that fold options are already configured.
--- Uses the same fold metadata as manual folds, so foldtext and toggle all work normally.
--- @param bufnr number
M.auto_fold_large_files = function(bufnr)
    local threshold = 2000
    local delta_dds = vim.b[bufnr].delta_diff_data_set
    if not delta_dds then return end

    local prev_last_row = 0
    for _, diff_data in ipairs(delta_dds) do
        if not (diff_data.new_path and #diff_data.hunks > 0) then goto next_file end
        local last_hunk = diff_data.hunks[#diff_data.hunks]
        local end_row   = last_hunk.lines[#last_hunk.lines].formatted_diff_line_num + 1
        local start_row = prev_last_row + 1
        prev_last_row   = end_row

        local added, removed = 0, 0
        for _, hunk in ipairs(diff_data.hunks) do
            for _, line in ipairs(hunk.lines) do
                if line.line_type == 'added' then added = added + 1
                elseif line.line_type == 'removed' then removed = removed + 1
                end
            end
        end

        if added + removed > threshold then
            if not M._fold_metadata[bufnr] then M._fold_metadata[bufnr] = {} end
            vim.cmd(start_row .. ',' .. end_row .. 'fold')
            vim.cmd(start_row .. 'foldclose')
            M._fold_metadata[bufnr][start_row] = {
                kind       = 'file',
                label      = diff_data.new_path,
                added      = added,
                removed    = removed,
                line_count = end_row - start_row + 1,
            }
        end
        ::next_file::
    end
end

-- ---------------------------------------------------------------------------
-- Fold-state capture / restore (used by reload_diff_buffer and BufReadCmd)
-- ---------------------------------------------------------------------------

-- Returns a string fingerprint of a file's changed lines (type:old_ln:new_ln:content).
-- Two files produce the same fingerprint iff their changed lines are identical.
-- Only called for folded files at capture/restore time, so cost is bounded by
-- the number of folds the user has actually created.
local function file_changed_lines_fingerprint(diff_data)
    local parts = {}
    for _, hunk in ipairs(diff_data.hunks) do
        for _, line in ipairs(hunk.lines) do
            if line.line_type == 'added' or line.line_type == 'removed' then
                table.insert(parts, line.line_type
                    .. ':' .. (line.old_line_num or 0)
                    .. ':' .. (line.new_line_num or 0)
                    .. ':' .. (line.content or ''))
            end
        end
    end
    return table.concat(parts, '\n')
end

-- Builds a row→identity map for file sections using the same prev_last_row
-- accumulation logic as get_file_sections() inside setup_fold_navigation.
local function build_file_position_map(delta_dds)
    local map = {}
    local prev_last_row = 0
    for _, diff_data in ipairs(delta_dds) do
        local path = diff_data.new_path
        if path and #diff_data.hunks > 0 then
            local last_hunk = diff_data.hunks[#diff_data.hunks]
            local end_row   = last_hunk.lines[#last_hunk.lines].formatted_diff_line_num + 1
            local start_row = prev_last_row + 1
            map[start_row]  = { new_path = path, end_row = end_row }
            prev_last_row   = end_row
        end
    end
    return map
end

-- Builds a list of hunk fold positions using the same first_line_to_header_offset
-- object-identity trick as hunk_fold_info_at() inside setup_fold_navigation.
-- nc_dds reuses the same Lua line objects as delta_dds, so the lookup works.
local function build_hunk_position_list(delta_dds, nc_dds)
    local first_line_to_header_offset = {}
    for _, diff_data in ipairs(delta_dds) do
        local offset = #diff_data.hunks > 1 and 3 or 0
        for _, hunk in ipairs(diff_data.hunks) do
            if #hunk.lines > 0 then
                first_line_to_header_offset[hunk.lines[1]] = offset
            end
        end
    end

    local list = {}
    for file_idx, nc_diff_data in ipairs(nc_dds) do
        for _, hunk in ipairs(nc_diff_data.hunks) do
            if #hunk.lines == 0 then goto continue end
            local first_line    = hunk.lines[1]
            local content_start = first_line.formatted_diff_line_num + 1
            local header_offset = first_line_to_header_offset[first_line] or 0
            table.insert(list, {
                new_path          = delta_dds[file_idx] and delta_dds[file_idx].new_path or '',
                first_new_line_num = first_line.new_line_num,
                first_old_line_num = first_line.old_line_num,
                start_row          = content_start - header_offset,
                end_row            = hunk.lines[#hunk.lines].formatted_diff_line_num + 1,
            })
            ::continue::
        end
    end
    return list
end

--- Captures the currently-closed folds as semantic descriptors independent of
--- buffer line numbers.  Only closed folds are captured (open folds need no
--- restoration).
--- @param bufnr number
--- @return table[] semantic fold list
M.capture_fold_state = function(bufnr)
    local meta_table = M._fold_metadata[bufnr]
    if not meta_table then return {} end

    local delta_dds = vim.b[bufnr].delta_diff_data_set
    local nc_dds    = vim.b[bufnr].no_context_delta_diff_data_set
    if not delta_dds then return {} end

    local file_map  = build_file_position_map(delta_dds)
    local hunk_list = nc_dds and build_hunk_position_list(delta_dds, nc_dds) or {}

    -- Build reverse map: foldstart_row → semantic identity
    local row_to_id = {}
    for start_row, id in pairs(file_map) do
        row_to_id[start_row] = { kind = 'file', new_path = id.new_path }
    end
    for _, hp in ipairs(hunk_list) do
        row_to_id[hp.start_row] = {
            kind               = 'hunk',
            new_path           = hp.new_path,
            first_new_line_num = hp.first_new_line_num,
            first_old_line_num = hp.first_old_line_num,
        }
    end

    -- Build a path→DiffData map for quick fingerprint lookups.
    local path_to_dd = {}
    for _, dd in ipairs(delta_dds) do
        if dd.new_path then path_to_dd[dd.new_path] = dd end
    end


    local result = {}
    for start_row, fold_meta in pairs(meta_table) do
        -- Only capture folds that are actually closed right now.
        -- BufUnload fires while Neovim's fold state is still intact, so
        -- foldclosed() correctly distinguishes open from closed here.
        -- Without this, Tab-opened folds (zO, no delete_fold call) would
        -- still be in the metadata table and get incorrectly re-closed.
        if vim.fn.foldclosed(start_row) == -1 then goto continue end
        local id = row_to_id[start_row]
        if id then
            local extra = {}
            if id.kind == 'file' then
                local dd = path_to_dd[id.new_path]
                if dd then
                    extra.content_fingerprint = file_changed_lines_fingerprint(dd)
                end
            end
            table.insert(result, vim.tbl_extend('force', id, extra, { fold_meta = fold_meta }))
        end
        ::continue::
    end
    return result
end

--- Re-creates and closes folds on a freshly-built buffer from a list of
--- semantic fold descriptors produced by capture_fold_state.
--- Silently skips folds whose file/hunk no longer exists in the new diff.
--- Must be called after setup_fold_navigation and auto_fold_large_files.
--- @param bufnr number
--- @param semantic_folds table[]
M.restore_fold_state = function(bufnr, semantic_folds)
    if not semantic_folds or #semantic_folds == 0 then return end

    local delta_dds = vim.b[bufnr].delta_diff_data_set
    local nc_dds    = vim.b[bufnr].no_context_delta_diff_data_set
    if not delta_dds then return end

    if not M._fold_metadata[bufnr] then M._fold_metadata[bufnr] = {} end

    local file_map  = build_file_position_map(delta_dds)
    local hunk_list = nc_dds and build_hunk_position_list(delta_dds, nc_dds) or {}

    local path_to_dd = {}
    for _, dd in ipairs(delta_dds) do
        if dd.new_path then path_to_dd[dd.new_path] = dd end
    end

    for _, sf in ipairs(semantic_folds) do
        local start_row, end_row

        if sf.kind == 'file' then
            for sr, fd in pairs(file_map) do
                if fd.new_path == sf.new_path then
                    start_row = sr
                    end_row   = fd.end_row
                    break
                end
            end
            -- "Viewed" semantics: if the file's changed lines differ from when
            -- the user folded it, show it unfolded so it gets re-reviewed.
            if start_row and sf.content_fingerprint then
                local dd = path_to_dd[sf.new_path]
                if not dd or file_changed_lines_fingerprint(dd) ~= sf.content_fingerprint then
                    start_row = nil
                end
            end
        else
            for _, hp in ipairs(hunk_list) do
                if hp.new_path           == sf.new_path
                    and hp.first_new_line_num == sf.first_new_line_num
                    and hp.first_old_line_num == sf.first_old_line_num
                then
                    start_row = hp.start_row
                    end_row   = hp.end_row
                    break
                end
            end
        end

        if start_row and end_row then
            if vim.fn.foldclosed(start_row) == -1 then
                vim.cmd(start_row .. ',' .. end_row .. 'fold')
            end
            vim.cmd(start_row .. 'foldclose')
            M._fold_metadata[bufnr][start_row] = sf.fold_meta
        end
    end
end

--- Reloads the diff buffer by re-running the same git diff, then restores fold
--- state and scroll position.  Called directly by the R normal-mode binding
--- (BufReadCmd handles :e).
--- @param bufnr number
M.reload_diff_buffer = function(bufnr)
    local ref             = vim.b[bufnr].delta_ref
    local display_ref     = vim.b[bufnr].delta_display_ref
    local context         = vim.b[bufnr].delta_context
    local path_arg        = vim.b[bufnr].delta_path_arg
    local origin_filepath = vim.b[bufnr].delta_origin_filepath
    if not (ref and context and path_arg) then
        vim.notify('Cannot reload: diff args not found on buffer', vim.log.levels.WARN)
        return
    end
    local folds      = M.capture_fold_state(bufnr)
    local saved_view = vim.fn.winsaveview()
    -- delta_path calls nvim_win_set_buf which switches the window away from this
    -- buffer; bufhidden=wipe then cleans it up automatically — no explicit delete needed.
    local new_bufnr = M.delta_path(ref, context, path_arg, display_ref, origin_filepath)
    if not new_bufnr then return end
    M.restore_fold_state(new_bufnr, folds)
    local lc = vim.api.nvim_buf_line_count(new_bufnr)
    saved_view.lnum    = math.min(saved_view.lnum,    lc)
    saved_view.topline = math.min(saved_view.topline, lc)
    vim.fn.winrestview(saved_view)
end

--- @param ref string git ref to compare against. Can be branch, commit, tag, etc.
--- @return number | nil bufnr buf id of diff buffer
M.deltaview_file = function(ref)
    assert(ref ~= nil)
    local filepath = vim.fn.expand('%:p')
    local cur_bufnr = vim.api.nvim_get_current_buf()
    local cursor_placement = M.get_cursor_placement_current_buffer()
    local og_winline = vim.fn.winline()
    local diff_bufnr = M.open_git_diff_buffer(filepath, ref)
    if diff_bufnr == nil then
        return
    end
    vim.b[diff_bufnr].git_root = vim.b[diff_bufnr].git_root or utils.get_git_root(filepath)
    M.place_cursor_delta_buffer_entry(diff_bufnr, 0, cursor_placement, og_winline, vim.b[diff_bufnr].git_root)
    M.setup_hunk_navigation(diff_bufnr)
    M.setup_winbar(diff_bufnr)
    M.setup_line_number_redirect(diff_bufnr)
    M.setup_fold_navigation(diff_bufnr)
    M.auto_fold_large_files(diff_bufnr)
    local nav_back_and_place_cursor = M.get_delta_buffer_cursor_exit_strategy(diff_bufnr, 0, cur_bufnr)
    if nav_back_and_place_cursor == nil then
        return
    end


    vim.keymap.set('n', 'q', nav_back_and_place_cursor, { buffer = diff_bufnr, silent = true })
    help.register_keybind(diff_bufnr, 'q', 'close diff and return to file', 'keybind')
    vim.keymap.set('n', '<leader>hu', function() M.revert_hunk_under_cursor(diff_bufnr) end, { buffer = diff_bufnr, silent = true })
    help.register_keybind(diff_bufnr, '<leader>hu', 'revert hunk under cursor', 'keybind')
    help.setup_help_keybind(diff_bufnr)
    M._refresh_fns[diff_bufnr] = function()
        local target     = M._post_revert_target
        M._post_revert_target = nil
        local folds      = M._reload_fold_stash[diff_bufnr] or {}
        local saved_view = M._reload_view_stash[diff_bufnr]
        M._reload_fold_stash[diff_bufnr] = nil
        M._reload_view_stash[diff_bufnr] = nil
        local new_bufnr = M.deltaview_file(ref)
        if not new_bufnr then return end
        M.restore_fold_state(new_bufnr, folds)
        if saved_view then
            local lc = vim.api.nvim_buf_line_count(new_bufnr)
            saved_view.lnum    = math.min(saved_view.lnum,    lc)
            saved_view.topline = math.min(saved_view.topline, lc)
            vim.fn.winrestview(saved_view)
        end
        if target then M.place_cursor_after_revert(new_bufnr, target) end
    end
    vim.api.nvim_create_autocmd('BufUnload', { buffer = diff_bufnr, once = true, callback = function()
        M._refresh_fns[diff_bufnr] = nil
    end })
    return diff_bufnr
end

--- delta git diff buffer orchestrator. opens a delta diff on top of current window
--- @param ref string git ref to compare against. Can be branch, commit, tag, etc.
--- @param context number size of context for the diff
--- @param path string path we want to diff
--- @param display_ref string | nil Human-readable ref label for the buffer name (e.g. "origin/master")
--- @return number | nil bufnr buf id of diff buffer
M.delta_path = function(ref, context, path, display_ref, origin_filepath)
    assert(ref ~= nil)
    assert(context ~= nil)
    assert(path ~= nil)
    local cursor_placement = M.get_cursor_placement_current_buffer()
    cursor_placement.filepath = origin_filepath or vim.fn.expand('%:p')
    local og_winline = vim.fn.winline()
    local diff_bufnr = M.open_git_diff_buffer_for_path(path, ref, context, nil, nil, nil, display_ref)
    if diff_bufnr == nil then
        return
    end
    vim.b[diff_bufnr].git_root              = vim.b[diff_bufnr].git_root or utils.get_git_root(path)
    vim.b[diff_bufnr].delta_ref             = ref
    vim.b[diff_bufnr].delta_display_ref     = display_ref
    vim.b[diff_bufnr].delta_context         = context
    vim.b[diff_bufnr].delta_path_arg        = path
    vim.b[diff_bufnr].delta_origin_filepath = cursor_placement.filepath
    -- 'nofile' buffers do not fire BufReadCmd on :e; 'acwrite' does.
    -- Reset modified so :e doesn't trigger E37 "No write since last change".
    vim.api.nvim_set_option_value('buftype', 'acwrite', { buf = diff_bufnr })
    vim.bo[diff_bufnr].modified = false
    vim.api.nvim_create_autocmd('BufWriteCmd', {
        buffer = diff_bufnr,
        callback = function() vim.bo[diff_bufnr].modified = false end,
    })
    M.place_cursor_delta_buffer_entry(diff_bufnr, 0, cursor_placement, og_winline, vim.b[diff_bufnr].git_root)
    M.setup_hunk_navigation(diff_bufnr)
    M.setup_winbar(diff_bufnr)
    M.setup_line_number_redirect(diff_bufnr)
    M.setup_fold_navigation(diff_bufnr)
    M.auto_fold_large_files(diff_bufnr)
    local nav_back_and_place_cursor = M.get_delta_buffer_cursor_exit_strategy(diff_bufnr, 0)
    if nav_back_and_place_cursor == nil then
        return
    end


    vim.keymap.set('n', 'q', nav_back_and_place_cursor, { buffer = diff_bufnr, silent = true })
    help.register_keybind(diff_bufnr, 'q', 'close diff and return to file', 'keybind')
    vim.keymap.set('n', 'o', function()
        local git_root = vim.b[diff_bufnr].git_root
        local cp = M.cursor_placement
        local filepath, target_line, target_col
        if cp and cp.filepath and git_root then
            filepath = git_root .. '/' .. cp.filepath
            target_line = cp.cursor and cp.cursor[1]
            target_col  = cp.cursor and cp.cursor[2]
        else
            -- cursor is on a title/fence line — fall back to first file in diff
            local dds = vim.b[diff_bufnr].delta_diff_data_set
            if dds and git_root then
                for _, diff_data in ipairs(dds) do
                    if diff_data.new_path then
                        filepath = git_root .. '/' .. diff_data.new_path
                        break
                    end
                end
            end
        end
        if filepath == nil then
            vim.notify('No file at cursor position', vim.log.levels.WARN)
            return
        end
        local ok, err = pcall(vim.cmd, 'vs ' .. vim.fn.fnameescape(filepath))
        if not ok then
            vim.notify('Failed to open file: ' .. tostring(err), vim.log.levels.ERROR)
            return
        end
        if target_line then
            pcall(vim.api.nvim_win_set_cursor, 0, { target_line, target_col or 0 })
        end
    end, { buffer = diff_bufnr, silent = true })
    help.register_keybind(diff_bufnr, 'o', 'open file under cursor in vertical split', 'keybind')
    vim.keymap.set('n', '<leader>hu', function() M.revert_hunk_under_cursor(diff_bufnr) end, { buffer = diff_bufnr, silent = true })
    help.register_keybind(diff_bufnr, '<leader>hu', 'revert hunk under cursor', 'keybind')
    help.setup_help_keybind(diff_bufnr)
    M._refresh_fns[diff_bufnr] = function()
        local target     = M._post_revert_target
        M._post_revert_target = nil
        local folds      = M._reload_fold_stash[diff_bufnr] or {}
        local saved_view = M._reload_view_stash[diff_bufnr]
        M._reload_fold_stash[diff_bufnr] = nil
        M._reload_view_stash[diff_bufnr] = nil
        local new_bufnr = M.delta_path(ref, context, path, display_ref)
        if not new_bufnr then return end
        M.restore_fold_state(new_bufnr, folds)
        if saved_view then
            local lc = vim.api.nvim_buf_line_count(new_bufnr)
            saved_view.lnum    = math.min(saved_view.lnum,    lc)
            saved_view.topline = math.min(saved_view.topline, lc)
            vim.fn.winrestview(saved_view)
        end
        if target then M.place_cursor_after_revert(new_bufnr, target) end
    end
    vim.api.nvim_create_autocmd('BufUnload', { buffer = diff_bufnr, once = true, callback = function()
        M._refresh_fns[diff_bufnr] = nil
    end })

    -- Intercept :e (BufReadCmd fires when Neovim tries to re-read the buffer).
    -- Everything runs synchronously: delta_path calls nvim_win_set_buf which switches
    -- the window to the new buffer, and bufhidden=wipe cleans up the old buffer.
    vim.api.nvim_create_autocmd('BufReadCmd', {
        buffer = diff_bufnr,
        callback = function()
            local bufnr           = vim.api.nvim_get_current_buf()
            -- BufUnload fires before BufReadCmd for acwrite; folds + view were stashed there.
            local folds           = M._reload_fold_stash[bufnr] or {}
            local saved_view      = M._reload_view_stash[bufnr] or vim.fn.winsaveview()
            M._reload_fold_stash[bufnr] = nil
            M._reload_view_stash[bufnr] = nil
            local _ref            = vim.b[bufnr].delta_ref
            local _display_ref    = vim.b[bufnr].delta_display_ref
            local _context        = vim.b[bufnr].delta_context
            local _path_arg       = vim.b[bufnr].delta_path_arg
            local _origin         = vim.b[bufnr].delta_origin_filepath
            if not (_ref and _context and _path_arg) then return end
            local new_bufnr = M.delta_path(_ref, _context, _path_arg, _display_ref, _origin)
            if not new_bufnr then return end
            -- Defer fold/viewport restore: fold commands don't take effect while
            -- Neovim is still processing the BufReadCmd event.
            vim.schedule(function()
                M.restore_fold_state(new_bufnr, folds)
                local lc = vim.api.nvim_buf_line_count(new_bufnr)
                saved_view.lnum    = math.min(saved_view.lnum,    lc)
                saved_view.topline = math.min(saved_view.topline, lc)
                vim.fn.winrestview(saved_view)
            end)
        end,
    })
    help.register_keybind(diff_bufnr, ':e', 'reload diff (re-run git diff)', 'keybind')
    -- Fallback binding in case BufReadCmd does not fire for nofile buffers.
    vim.keymap.set('n', 'R', function() M.reload_diff_buffer(diff_bufnr) end,
        { buffer = diff_bufnr, silent = true })
    help.register_keybind(diff_bufnr, 'R', 'reload diff (re-run git diff)', 'keybind')

    return diff_bufnr
end

--- opens a git diff buffer for the specified file against a git ref, using delta.text_diff
--- this diff has unlimited context, and allows for one file
--- @param filepath string The file path to diff
--- @param ref string git ref to compare against. Can be branch, commit, tag, etc.
--- @param winnr number | nil Optional window number to open on.
--- @return number | nil bufnr buf id of diff buffer
M.open_git_diff_buffer = function(filepath, ref, winnr)
    assert(filepath ~= nil)
    local git_root = utils.get_git_root(filepath)
    if vim.fn.filereadable(filepath) == 0 then
        vim.notify('Not on a real file. Cannot open git diff buffer.', vim.log.levels.WARN)
        return
    end
    assert(ref ~= nil)
    local delta = require('delta')

    local is_untracked = utils.is_untracked_file(filepath, git_root)
    local git_data

    if is_untracked ~= true then
        local diff_result = vim.system({ 'git', '-C', git_root, 'diff', '--no-ext-diff', '-U0', ref, '--', filepath }):wait()
        if diff_result.code ~= 0 and diff_result.code ~= 1 then
            vim.notify('Failed to run git diff - ' .. diff_result.stderr, vim.log.levels.ERROR)
            return
        end
        local diffstring = diff_result.stdout

        if diffstring == nil or diffstring == "" then
            vim.notify('No changes detected in current file', vim.log.levels.WARN)
            return
        end

        git_data = delta.parse.get_diff_data_git(diffstring)
    else
        local new_path = filepath:sub(#git_root + 2)
        git_data = {{
            new_path = new_path,
            old_path = nil,
            language = delta.parse.get_language_from_filename(filepath)
        }}
    end

    local file_lines = utils.read_file_lines(git_root .. '/' .. git_data[1].new_path)
    assert(file_lines ~= nil)
    local s2 = table.concat(file_lines, "\n")
    local s1 = ''

    if git_data[1].old_path then
        local show_result
        if git_data[1].new_file ~= true and git_data[1].old_blob_hash then
            show_result = vim.system({ 'git', '-C', git_root, 'cat-file', 'blob', git_data[1].old_blob_hash }):wait()
            if show_result.code ~= 0 and show_result.code ~= 1 then
                vim.notify('Failed to run git cat-file - ' .. show_result.stderr, vim.log.levels.ERROR)
                return
            end
            s1 = show_result.stdout or ''
            -- there exists a trailing newline for some reason with git show
            s1 = s1:gsub('\n+$', '')
        else
            s1 = ''
        end
    end

    local bufnr = delta.text_diff(s1, s2, git_data[1].language, { context = #file_lines })
    if bufnr == nil then
        return -- error already notified
    end
    vim.b[bufnr].source_filepath = filepath

    local success, err = pcall(function()
        vim.api.nvim_win_set_buf(winnr or 0, bufnr)
    end)
    if not success then
        -- i've considered letting this just error instead, because this should only be triggered due to developer error/misuse of function. But I figure the message can be useful anyhow, and maybe this could happen during typical usage.
        vim.notify('Failed to open buffer at window.' .. tostring(err), vim.log.levels.ERROR)
        return
    end
    delta.highlight_delta_artifacts(bufnr)
    delta.syntax_highlight_diff_set(bufnr)
    delta.diff_highlight_diff(bufnr)
    if config.options.line_numbers then
        delta.setup_delta_statuscolumn(bufnr)
    end

    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
    assert(delta_diff_data_set ~= nil)
    --- @cast delta_diff_data_set DiffData[]

    -- displays ref, filename
    local diff_buffer_name = 'deltaview://diff/' .. filepath .. '    '
        .. config.viewconfig().vs .. ' ' .. ref .. '    '
    vim.api.nvim_buf_set_name(bufnr, diff_buffer_name)

    local no_context_delta_diff_data_set = utils.get_separated_diff_data_set_into_hunks_wo_context(delta_diff_data_set)
    -- this buffer variable allows hunk navigation later. having accurate hunk count also allows us to display it in the name
    if utils.diff_data_sets_changed_lines_match(no_context_delta_diff_data_set, delta_diff_data_set) then
        --- @type DiffData[]
        vim.b[bufnr].no_context_delta_diff_data_set = no_context_delta_diff_data_set
        -- adds size of hunks
        diff_buffer_name = diff_buffer_name ..
            config.viewconfig().segment ..
            ' ' .. #no_context_delta_diff_data_set[1].hunks .. '   '
        vim.api.nvim_buf_set_name(bufnr, diff_buffer_name)
    end

    return bufnr
end

--- opens a git diff buffer for the specified path against a git ref, using delta.git_diff
--- this diff has limited context, and allows for multiple files
--- when not used on a file, will exclude untracked files. When used explicitly on an untracked file, will work
--- @param path string The path to diff
--- @param ref string git ref to compare against. Can be branch, commit, tag, etc.
--- @param context number lines of context to show
--- @param winnr number | nil Optional window number to open on.
--- @param buf_name string | nil Optional name to assign to the buffer
--- @param is_untracked boolean | nil Optional untracked status. When provided, skips the git lookup used to determine it.
--- @param display_ref string | nil Human-readable ref label shown in the buffer name (defaults to first 8 chars of ref)
--- @return number | nil bufnr buf id of diff buffer
M.open_git_diff_buffer_for_path = function(path, ref, context, winnr, buf_name, is_untracked, display_ref)
    assert(path ~= nil)
    assert(ref ~= nil)
    assert(context ~= nil)
    local delta = require('delta')
    if is_untracked == nil then
        local git_root = utils.get_git_root(path)
        is_untracked = utils.is_untracked_file(path, git_root)
    end

    --- @type DeltaOpts
    local opts = { context = context, new_file = is_untracked }
    local bufnr = delta.git_diff(ref, path, opts)
    if bufnr == nil then
        return
    end

    local success, err = pcall(function()
        vim.api.nvim_win_set_buf(winnr or 0, bufnr)
    end)
    if not success then
        vim.notify('Failed to open buffer at window.' .. tostring(err), vim.log.levels.ERROR)
        return
    end
    delta.highlight_delta_artifacts(bufnr)
    delta.syntax_highlight_git_diff(bufnr)
    delta.diff_highlight_diff(bufnr)
    if config.options.line_numbers then
        delta.setup_delta_statuscolumn(bufnr)
    end

    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
    assert(delta_diff_data_set ~= nil)
    --- @cast delta_diff_data_set DiffData[]

    -- displays ref label and file count
    local ref_label = display_ref or (ref:sub(1, 8) .. '...')
    local diff_buffer_name = ref_label .. '    '
        .. config.viewconfig().file .. ' ' .. #delta_diff_data_set .. '    '

    vim.api.nvim_buf_set_name(bufnr, buf_name or diff_buffer_name)

    local no_context_delta_diff_data_set = utils.get_separated_diff_data_set_into_hunks_wo_context(delta_diff_data_set)
    -- this buffer variable allows hunk navigation later. having accurate hunk count also allows us to display it in the name
    if utils.diff_data_sets_changed_lines_match(no_context_delta_diff_data_set, delta_diff_data_set) then
        --- @type DiffData[]
        vim.b[bufnr].no_context_delta_diff_data_set = no_context_delta_diff_data_set

        -- display size of hunks if parsing was successful
        local total_hunk_count = 0
        for _, d in ipairs(no_context_delta_diff_data_set) do
            total_hunk_count = total_hunk_count + #d.hunks
        end
        diff_buffer_name = diff_buffer_name ..
            config.viewconfig().segment ..
            ' ' .. total_hunk_count .. '   '
        vim.api.nvim_buf_set_name(bufnr, buf_name or diff_buffer_name)
    end

    return bufnr
end

--- Captures the current window and cursor position before opening a diff buffer
--- Call this before open_delta_lua_git_diff, then pass the result to place_cursor_in_diff_buffer
--- @return CursorPlacement snapshot of the current window and cursor; [1] is row, [2] is col
M.get_cursor_placement_current_buffer = function()
    local winnr = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(winnr)
    return { winnr = winnr, cursor = cursor }
end

--- finds the line in the diff buffer that corresponds to the real file to place the cursor at.
--- @param bufnr number buf_id of diff buffer id
--- @param winnr number win id of diff window id
--- @param cursor_placement CursorPlacement if filepath is not specified, they will try to place the cursor on the first file of the diff. If the diff buffer does not have filepath, but you know the file your cursor was on matches with the diff file, use filepath = nil.
--- @param og_winline number winline of the cursor in the source buffer, used to preserve relative screen position in the diff buffer
--- @param git_root string
M.place_cursor_delta_buffer_entry = function(bufnr, winnr, cursor_placement, og_winline, git_root)
    assert(bufnr ~= nil)
    assert(winnr ~= nil)
    assert(cursor_placement ~= nil)
    assert(og_winline ~= nil)
    assert(git_root ~= nil)
    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
    assert(delta_diff_data_set ~= nil)
    --- @cast delta_diff_data_set DiffData[]

    for _, diff_data in ipairs(delta_diff_data_set) do
        -- when using delta.text_diff, there is no filepath in diff_data to compare to.
        -- in the interest of making this usable with delta.text_diff, we do a fail open (if we can't find a filepath, we try to do a cursor placement anyways)
        local full_path = git_root .. '/' .. (diff_data.new_path or '')
        if cursor_placement.filepath == nil or full_path == cursor_placement.filepath then
            for _, hunk in ipairs(diff_data.hunks) do
                for _, line in ipairs(hunk.lines) do
                    if line.new_line_num == cursor_placement.cursor[1] then
                        local target_lnum = line.formatted_diff_line_num + 1
                        M.set_restview(winnr, og_winline, target_lnum, cursor_placement.cursor[2])
                        if cursor_placement.filepath ~= nil then
                            -- git diff path flow, meaning it is worth alerting the user the file was found
                            vim.notify("File and Cursor synced.", vim.log.levels.INFO)
                        end
                        return
                    end
                end
            end
            -- fallback: just place at top of first hunk of matched filepath
            local success, err = pcall(function()
                vim.api.nvim_win_set_cursor(winnr, { diff_data.hunks[1].lines[1].formatted_diff_line_num + 1, 0 })
                if cursor_placement.filepath ~= nil then
                    -- git diff path flow, meaning it is worth alerting the user the file was found
                    vim.notify("File synced, entering at top of file.", vim.log.levels.INFO)
                end
            end)
            if not success then
                vim.notify('Failed to place cursor.' .. tostring(err), vim.log.levels.ERROR)
            end
            return
        end
    end
    if cursor_placement.filepath == nil then
        -- only worth notifying on non path flow. This notification will be common on path flow
        vim.notify("Corresponding cursor location or filepath could not be found. Cursor will not be placed.",
            vim.log.levels.WARN)
    end
end

--- @type CursorPlacement | nil
M.cursor_placement = nil -- module level upvalue, reusable in multiple module scoped functions


--- Populates the module level upvalue to track the cursor in the delta diff buffer
--- @param bufnr number
--- @param winnr number
M.setup_cursor_placement_tracking = function(bufnr, winnr)
    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
    assert(delta_diff_data_set ~= nil)
    --- @cast delta_diff_data_set DiffData[]

    --- @type table<number, CursorLookupEntry | false>
    local row_lookup = {}
    for _, diff_data in ipairs(delta_diff_data_set) do
        for _, hunk in ipairs(diff_data.hunks) do
            for _, line in ipairs(hunk.lines) do
                if line.new_line_num ~= nil then
                    row_lookup[line.formatted_diff_line_num + 1] = {
                        new_line_num = line.new_line_num,
                        filepath = diff_data.new_path or nil,
                    }
                elseif line.old_line_num ~= nil then
                    -- removed line: new_line_num is nil, use old_line_num as best-effort approximation
                    row_lookup[line.formatted_diff_line_num + 1] = {
                        new_line_num = line.old_line_num,
                        filepath = diff_data.new_path or nil,
                    }
                else
                    row_lookup[line.formatted_diff_line_num + 1] = false
                end
            end
        end
    end

    local populate_cursor_placement = function()
        local pos = vim.api.nvim_win_get_cursor(0)
        local current_row = pos[1]
        local current_col = pos[2]

        local entry = row_lookup[current_row]
        if entry == nil then
            -- not yet cached — row is not a diff line
            row_lookup[current_row] = false
            M.cursor_placement = nil
            return
        end

        if entry == false then
            M.cursor_placement = nil
            return
        end

        M.cursor_placement = {
            winnr = winnr,
            cursor = { entry.new_line_num, current_col },
            filepath = entry.filepath,
        }
    end

    populate_cursor_placement()

    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = bufnr,
        callback = populate_cursor_placement
    })
end

--- returns a function that, when invoked, opens the file to and places the cursor where the cursor was in the diff buffer. The function can fail if the cursor is not in a valid location.
--- @param bufnr number buf_id of diff buffer id
--- @param winnr number win id of the buffer we are exiting to
--- @param alternative_bufnr number | nil buf_id of the buffer id to exit to. If given, is used.
--- @return nil | fun(): boolean strategy strategy function returns a boolean when executed if the window succcessfully exited to anotherb uffer and if the cursor was successfully placed. If used on a delta.text_diff or delta.patch_diff buffer, will not redirect to any filepath given by the buffer, so would prefer to have alternative_bufnr. If used on a delta.git_diff buffer where the filepath is displayed, it will navigate to that before placing the cursor
M.get_delta_buffer_cursor_exit_strategy = function(bufnr, winnr, alternative_bufnr)
    M.setup_cursor_placement_tracking(bufnr, winnr)

    return function()
        local og_winline = vim.fn.winline()

        if M.cursor_placement == nil then
            -- cursor is on a deleted or non-diff line — navigate back without precise cursor placement
            if alternative_bufnr ~= nil then
                local success, err = pcall(function()
                    vim.api.nvim_set_current_buf(alternative_bufnr)
                end)
                if not success then
                    vim.notify('Failed to navigate to alternative buffer' .. tostring(err), vim.log.levels.ERROR)
                    return false
                end
                return true
            end
            -- filepath flow: find which file the cursor is in and open it without cursor placement
            local cur_row = vim.api.nvim_win_get_cursor(0)[1]
            local git_root = vim.b[bufnr].git_root
            local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
            if git_root and delta_diff_data_set then
                for _, diff_data in ipairs(delta_diff_data_set) do
                    if diff_data.new_path then
                        for _, hunk in ipairs(diff_data.hunks) do
                            for _, line in ipairs(hunk.lines) do
                                if line.formatted_diff_line_num + 1 == cur_row then
                                    local success, err = pcall(function()
                                        vim.cmd('e ' .. vim.fn.fnameescape(git_root .. '/' .. diff_data.new_path))
                                    end)
                                    if not success then
                                        vim.notify('Failed to open file: ' .. tostring(err), vim.log.levels.ERROR)
                                        return false
                                    end
                                    return true
                                end
                            end
                        end
                    end
                end
            end
            -- cursor is on a title/fence line with no associated file — close the diff buffer.
            -- If other windows still show the same buffer, only switch this window away
            -- rather than deleting the shared buffer (which would close all windows).
            if #vim.fn.win_findbuf(bufnr) > 1 then
                local alt = vim.fn.bufnr('#')
                if alt ~= -1 and alt ~= bufnr then
                    vim.api.nvim_set_current_buf(alt)
                else
                    vim.cmd('bprevious')
                end
                return true
            end
            local success, err = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            if not success then
                vim.notify('Failed to close diff buffer: ' .. tostring(err), vim.log.levels.ERROR)
                return false
            end
            return true
        end

        if alternative_bufnr ~= nil then
            local success, err = pcall(function()
                vim.api.nvim_set_current_buf(alternative_bufnr)
            end)
            if not success then
                vim.notify('Failed to navigate to alternative buffer' .. tostring(err), vim.log.levels.ERROR)
                return false
            end
            goto place_cursor
        end

        -- filepath ~= nil when on path flow. Relative to git_root, as it is parsed from the git diff
        if M.cursor_placement.filepath ~= nil then
            local git_root = vim.b[bufnr].git_root
            local success, err = pcall(function()
                vim.cmd('e ' .. vim.fn.fnameescape(git_root .. '/' .. M.cursor_placement.filepath))
            end)
            if not success then
                vim.notify('Failed to open file: ' .. git_root .. '/' .. M.cursor_placement.filepath ..
                    ' - ' .. tostring(err), vim.log.levels.ERROR)
                return false
            end
        end

        ::place_cursor::
        M.set_restview(winnr, og_winline, M.cursor_placement.cursor[1], M.cursor_placement.cursor[2])
        M.cursor_placement = nil
        return true
    end
end

--- sets the view state while maintaining the cursor position relative to the top of the window. Accounts for new line wrapping.
--- @param winnr number
--- @param og_winline number original distance between cursor and top of window
--- @param target_row number row of where cursor should be placed 0-based
--- @param target_col number col of where the cursor should be placed 1-based
M.set_restview = function(winnr, og_winline, target_row, target_col)
    local success, err = pcall(function()
        vim.api.nvim_win_call(winnr, function()
            local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winnr))
            target_row = math.max(1, math.min(target_row, line_count))
            vim.api.nvim_win_set_cursor(winnr, { target_row, target_col })
            vim.cmd('normal! zb')

            local topline = target_row

            -- accounting for the cursor being on a wrapped screen line within target_row.
            local sp_cursor_line_start = vim.fn.screenpos(winnr, target_row, 1)
            local sp_cursor = vim.fn.screenpos(winnr, target_row, math.max(1, target_col + 1)) -- col is 1-based
            local cursor_line_offset = (sp_cursor_line_start.row ~= 0 and sp_cursor.row ~= 0)
                and (sp_cursor.row - sp_cursor_line_start.row)
                or 0
            local screen_lines_walked = 1 + cursor_line_offset

            while screen_lines_walked < og_winline and topline > 1 do
                local next_topline = topline - 1
                local line_end_col = math.max(1, vim.fn.col({ next_topline, '$' }) - 1) -- col is 1-based
                local sp_start = vim.fn.screenpos(winnr, next_topline, 1)
                local sp_end = vim.fn.screenpos(winnr, next_topline, line_end_col)
                if sp_start.row == 0 or sp_end.row == 0 then
                    -- there is a bug when this function is called with the cursor on the very last row.
                    -- if you put print statements here, you will observe that sp_start and sp_end return 0
                    -- values when the cursor starts on the last row, and it tries to calculate for the
                    -- second to last row. Root cause is completely unknown.
                    break
                end
                topline = next_topline
                screen_lines_walked = screen_lines_walked + (sp_end.row - sp_start.row + 1)
            end
            vim.fn.winrestview({
                topline = topline,
                lnum = target_row,
                col = target_col,
            })
        end)
    end)
    if not success then
        vim.notify('Failed to place cursor. ' .. tostring(err), vim.log.levels.ERROR)
    end
end

--- Sets up a sticky winbar showing the current file name, updated as the cursor moves.
--- @param bufnr number buf_id of the diff buffer
M.setup_winbar = function(bufnr)
    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
    if not delta_diff_data_set then return end

    -- Build a sorted list of { row, path } where each file's section is considered
    -- to start immediately after the previous file's last hunk line. This ensures
    -- the file header/separator rows (which precede the first hunk) are attributed
    -- to the correct file rather than the previous one.
    local file_ranges = {}
    local file_stats = {}  -- path -> { added, removed }
    local prev_last_row = 0
    for _, diff_data in ipairs(delta_diff_data_set) do
        local path = diff_data.new_path
        if path and #diff_data.hunks > 0 then
            table.insert(file_ranges, { row = prev_last_row + 1, path = path })
            local last_hunk = diff_data.hunks[#diff_data.hunks]
            prev_last_row = last_hunk.lines[#last_hunk.lines].formatted_diff_line_num + 1
            local added, removed = 0, 0
            for _, hunk in ipairs(diff_data.hunks) do
                for _, line in ipairs(hunk.lines) do
                    if line.line_type == 'added' then added = added + 1
                    elseif line.line_type == 'removed' then removed = removed + 1
                    end
                end
            end
            file_stats[path] = { added = added, removed = removed }
        end
    end

    -- Fallback for single-file text_diff buffers (no new_path in diff data)
    local static_path = vim.b[bufnr].source_filepath
    if #file_ranges == 0 and not static_path then return end

    -- For single-file buffers, compute stats from the whole diff data set
    if #file_ranges == 0 and static_path then
        local added, removed = 0, 0
        for _, diff_data in ipairs(delta_diff_data_set) do
            for _, hunk in ipairs(diff_data.hunks or {}) do
                for _, line in ipairs(hunk.lines or {}) do
                    if line.line_type == 'added' then added = added + 1
                    elseif line.line_type == 'removed' then removed = removed + 1
                    end
                end
            end
        end
        file_stats[static_path] = { added = added, removed = removed }
    end

    local get_path_at_row = function(row)
        if #file_ranges == 0 then return static_path end
        local current = file_ranges[1].path
        for _, entry in ipairs(file_ranges) do
            if entry.row <= row then
                current = entry.path
            else
                break
            end
        end
        return current
    end

    local update_winbar = function()
        local win = vim.api.nvim_get_current_win()
        if not vim.api.nvim_win_is_valid(win) then return end
        local row = vim.api.nvim_win_get_cursor(win)[1]
        local path = get_path_at_row(row)
        if not path then
            vim.wo[win].winbar = ''
            return
        end
        local stats = file_stats[path]
        local stats_str = stats and ('  +' .. stats.added .. ' -' .. stats.removed) or ''
        vim.wo[win].winbar = ' ' .. path .. stats_str
    end

    update_winbar()

    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = bufnr,
        callback = update_winbar,
    })

    vim.api.nvim_create_autocmd('BufLeave', {
        buffer = bufnr,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_is_valid(win) then
                vim.wo[win].winbar = ''
            end
        end,
    })
end

--- Sets up `:N` line-number redirect so that `:123<Enter>` in the diff buffer
--- jumps to the buffer row displaying source file line 123 (new_line_num).
--- If source line 123 is not visible in the diff, the cursor does not move.
--- @param bufnr number buf_id of the diff buffer
M.setup_line_number_redirect = function(bufnr)
    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
    if not delta_diff_data_set then return end
    --- @cast delta_diff_data_set DiffData[]

    local single_map = nil    -- table<number, number> for single-file buffers
    local per_file_maps = nil -- table<string, table<number, number>> for multi-file
    local file_ranges = {}    -- { row, path }[] sorted asc (multi-file only)

    local is_multi_file = false
    for _, diff_data in ipairs(delta_diff_data_set) do
        if diff_data.new_path ~= nil then is_multi_file = true; break end
    end

    if is_multi_file then
        per_file_maps = {}
        local prev_last_row = 0
        for _, diff_data in ipairs(delta_diff_data_set) do
            local path = diff_data.new_path
            if path and #diff_data.hunks > 0 then
                local file_map = {}
                for _, hunk in ipairs(diff_data.hunks) do
                    for _, line in ipairs(hunk.lines) do
                        if line.new_line_num ~= nil and not file_map[line.new_line_num] then
                            file_map[line.new_line_num] = line.formatted_diff_line_num + 1
                        end
                    end
                end
                per_file_maps[path] = file_map
                table.insert(file_ranges, { row = prev_last_row + 1, path = path })
                local last_hunk = diff_data.hunks[#diff_data.hunks]
                prev_last_row = last_hunk.lines[#last_hunk.lines].formatted_diff_line_num + 1
            end
        end
    else
        single_map = {}
        for _, diff_data in ipairs(delta_diff_data_set) do
            for _, hunk in ipairs(diff_data.hunks) do
                for _, line in ipairs(hunk.lines) do
                    if line.new_line_num ~= nil and not single_map[line.new_line_num] then
                        single_map[line.new_line_num] = line.formatted_diff_line_num + 1
                    end
                end
            end
        end
    end

    local get_map_at_row = function(cur_row)
        if single_map then return single_map end
        local current_path = file_ranges[1] and file_ranges[1].path
        for _, entry in ipairs(file_ranges) do
            if entry.row <= cur_row then current_path = entry.path
            else break end
        end
        return current_path and per_file_maps[current_path] or nil
    end

    -- Register the global <CR> intercept once for all diff buffers.
    -- Returns <C-c> (cancel cmdline without executing) when a pure number command
    -- is typed in a deltaview buffer, then schedules the real cursor move.
    -- This prevents :N from ever running, eliminating the viewport flicker.
    if not _cmdline_cr_registered then
        _cmdline_cr_registered = true
        vim.keymap.set('c', '<CR>', function()
            if vim.fn.getcmdtype() ~= ':' then
                return vim.api.nvim_replace_termcodes('<CR>', true, false, true)
            end
            local cmdline = vim.fn.getcmdline()
            if not cmdline:match('^%d+$') then
                return vim.api.nvim_replace_termcodes('<CR>', true, false, true)
            end
            local curbuf = vim.api.nvim_get_current_buf()
            local handler = M._line_redirect_handlers[curbuf]
            if not handler then
                return vim.api.nvim_replace_termcodes('<CR>', true, false, true)
            end

            local target = tonumber(cmdline)
            local cur_row = vim.api.nvim_win_get_cursor(0)[1]
            local buf_row = handler(cur_row, target)

            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(curbuf) then return end
                if vim.api.nvim_get_current_buf() ~= curbuf then return end
                if buf_row then
                    vim.api.nvim_win_set_cursor(0, { buf_row, 0 })
                end
            end)

            return vim.api.nvim_replace_termcodes('<C-c>', true, false, true)
        end, { expr = true, noremap = true, silent = true })
    end

    M._line_redirect_handlers[bufnr] = function(cur_row, target_line)
        local map = get_map_at_row(cur_row)
        return map and map[target_line]
    end

    vim.api.nvim_create_autocmd('BufUnload', {
        buffer = bufnr,
        once = true,
        callback = function()
            M._line_redirect_handlers[bufnr] = nil
        end,
    })
end

--- Called by Neovim as the foldtext for deltaview diff buffers.
--- Reads fold metadata from M._fold_metadata to produce a summary line.
--- @return string
M.deltaview_foldtext = function()
    local bufnr  = vim.api.nvim_get_current_buf()
    local fstart = vim.v.foldstart
    local meta   = M._fold_metadata[bufnr] and M._fold_metadata[bufnr][fstart]
    if not meta then return vim.fn.foldtext() end
    local icon = meta.kind == 'file' and '' or '  '
    return string.format('%s %s  · +%d -%d  [%d lines]',
        icon, meta.label, meta.added, meta.removed, meta.line_count)
end

--- Sets up fold keybinds and options for a deltaview diff buffer.
--- <leader>mf folds/unfolds the file section under cursor.
--- <leader>mh folds/unfolds the hunk under cursor.
--- <Tab> opens a closed fold recursively.
--- @param bufnr number buf_id of the diff buffer
M.setup_fold_navigation = function(bufnr)
    local delta_dds = vim.b[bufnr].delta_diff_data_set
    if not delta_dds then return end
    --- @cast delta_dds DiffData[]

    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_option_value('foldmethod',   'manual', { win = win })
    vim.api.nvim_set_option_value('foldenable',   true,     { win = win })
    vim.api.nvim_set_option_value('foldlevel',    99,       { win = win })
    vim.api.nvim_set_option_value('foldminlines', 0,        { win = win })
    vim.api.nvim_set_option_value('foldtext',
        "v:lua.require('deltaview.view').deltaview_foldtext()", { win = win })

    -- Returns {start_row, end_row, diff_data}[] for each file section.
    local get_file_sections = function()
        local sections = {}
        local prev_last_row = 0
        for _, diff_data in ipairs(delta_dds) do
            local path = diff_data.new_path
            if path and #diff_data.hunks > 0 then
                local last_hunk = diff_data.hunks[#diff_data.hunks]
                local end_row   = last_hunk.lines[#last_hunk.lines].formatted_diff_line_num + 1
                table.insert(sections, {
                    start_row = prev_last_row + 1,
                    end_row   = end_row,
                    diff_data = diff_data,
                })
                prev_last_row = end_row
            end
        end
        return sections
    end

    -- Ensures the metadata table exists for bufnr.
    local ensure_meta = function()
        if not M._fold_metadata[bufnr] then
            M._fold_metadata[bufnr] = {}
        end
    end

    -- Deletes the fold at start_row (toggle off). No-op if no fold exists there.
    local delete_fold = function(start_row)
        ensure_meta()
        local save_pos = vim.api.nvim_win_get_cursor(0)
        vim.api.nvim_win_set_cursor(0, { start_row, 0 })
        vim.cmd('normal! zD')
        vim.api.nvim_win_set_cursor(0, save_pos)
        M._fold_metadata[bufnr][start_row] = nil
    end

    -- Creates a fold over [start_row, end_row] (if not already present) and closes it.
    -- If the fold is already closed, this is a no-op.
    local close_fold = function(start_row, end_row, meta)
        ensure_meta()
        if vim.fn.foldclosed(start_row) ~= -1 then return end
        if not M._fold_metadata[bufnr][start_row] then
            vim.cmd(start_row .. ',' .. end_row .. 'fold')
            M._fold_metadata[bufnr][start_row] = meta
        end
        vim.cmd(start_row .. 'foldclose')
    end

    -- Toggles a fold at [start_row, end_row]: closes if open/absent, deletes if closed.
    local toggle_fold = function(start_row, end_row, meta)
        ensure_meta()
        if M._fold_metadata[bufnr][start_row] and vim.fn.foldclosed(start_row) ~= -1 then
            delete_fold(start_row)
        else
            close_fold(start_row, end_row, meta)
        end
    end

    -- Returns hunk fold bounds + metadata for the hunk under cur_row, or nil.
    -- Uses no_context_delta_diff_data_set so that fold boundaries match the visual
    -- hunks seen by ]c/[c navigation (each contiguous block of changes), not the
    -- larger full-dataset hunks that merge nearby changes via context lines.
    local hunk_fold_info_at = function(cur_row)
        local nc_dds = vim.b[bufnr].no_context_delta_diff_data_set
        if not nc_dds then return nil end

        -- Map each full-dataset hunk's first DiffLine object to the header offset
        -- that hunk contributes (3 lines of fence/header if the file is multi-hunk,
        -- else 0). The no-context sub-hunk whose first line matches the full-dataset
        -- hunk's first line inherits that offset; other sub-hunks get 0.
        local first_line_to_header_offset = {}
        for _, diff_data in ipairs(delta_dds) do
            local offset = #diff_data.hunks > 1 and 3 or 0
            for _, hunk in ipairs(diff_data.hunks) do
                if #hunk.lines > 0 then
                    first_line_to_header_offset[hunk.lines[1]] = offset
                end
            end
        end

        for file_idx, nc_diff_data in ipairs(nc_dds) do
            local total_hunks = #nc_diff_data.hunks
            for hunk_idx, hunk in ipairs(nc_diff_data.hunks) do
                if #hunk.lines == 0 then goto next_hunk end
                local content_start = hunk.lines[1].formatted_diff_line_num + 1
                local header_offset = first_line_to_header_offset[hunk.lines[1]] or 0
                local fold_start    = content_start - header_offset
                local fold_end      = hunk.lines[#hunk.lines].formatted_diff_line_num + 1
                if cur_row >= fold_start and cur_row <= fold_end then
                    local added, removed = 0, 0
                    for _, line in ipairs(hunk.lines) do
                        if line.line_type == 'added' then added = added + 1
                        elseif line.line_type == 'removed' then removed = removed + 1
                        end
                    end
                    local filepath = delta_dds[file_idx] and delta_dds[file_idx].new_path or ''
                    local label = string.format('hunk %d/%d @ line %d',
                        hunk_idx, total_hunks, hunk.lines[1].new_line_num or content_start)
                    return fold_start, fold_end, {
                        kind       = 'hunk',
                        label      = filepath .. '  ' .. label,
                        added      = added,
                        removed    = removed,
                        line_count = fold_end - fold_start + 1,
                    }
                end
                ::next_hunk::
            end
        end
        return nil
    end

    -- <leader>mf: toggle the file section fold under cursor
    vim.keymap.set('n', '<leader>mf', function()
        local cur_row  = vim.api.nvim_win_get_cursor(0)[1]
        local sections = get_file_sections()
        for _, s in ipairs(sections) do
            if cur_row >= s.start_row and cur_row <= s.end_row then
                local added, removed = 0, 0
                for _, hunk in ipairs(s.diff_data.hunks) do
                    for _, line in ipairs(hunk.lines) do
                        if line.line_type == 'added' then added = added + 1
                        elseif line.line_type == 'removed' then removed = removed + 1
                        end
                    end
                end
                toggle_fold(s.start_row, s.end_row, {
                    kind       = 'file',
                    label      = s.diff_data.new_path,
                    added      = added,
                    removed    = removed,
                    line_count = s.end_row - s.start_row + 1,
                })
                if vim.fn.foldclosed(s.start_row) ~= -1 then
                    M.jump_to_hunk(bufnr, true)
                end
                return
            end
        end
        vim.notify('No file section at cursor', vim.log.levels.WARN)
    end, { buffer = bufnr, silent = true })
    help.register_keybind(bufnr, '<leader>mf', 'fold/unfold file section', 'keybind')

    -- Like hunk_fold_info_at but uses the full delta_dds dataset, so the fold
    -- range includes the header fences and surrounding context lines.
    local context_hunk_fold_info_at = function(cur_row)
        for file_idx, diff_data in ipairs(delta_dds) do
            local is_multi      = #diff_data.hunks > 1
            local header_offset = is_multi and 3 or 0
            for hunk_idx, hunk in ipairs(diff_data.hunks) do
                if #hunk.lines == 0 then goto next_hunk end
                local content_start = hunk.lines[1].formatted_diff_line_num + 1
                local fold_start    = content_start - header_offset
                local fold_end      = hunk.lines[#hunk.lines].formatted_diff_line_num + 1
                if cur_row >= fold_start and cur_row <= fold_end then
                    local added, removed = 0, 0
                    for _, line in ipairs(hunk.lines) do
                        if line.line_type == 'added' then added = added + 1
                        elseif line.line_type == 'removed' then removed = removed + 1
                        end
                    end
                    local filepath = delta_dds[file_idx] and delta_dds[file_idx].new_path or ''
                    local label = string.format('context %d/%d @ line %d',
                        hunk_idx, #diff_data.hunks, hunk.lines[1].new_line_num or content_start)
                    return fold_start, fold_end, {
                        kind       = 'hunk',
                        label      = filepath .. '  ' .. label,
                        added      = added,
                        removed    = removed,
                        line_count = fold_end - fold_start + 1,
                    }
                end
                ::next_hunk::
            end
        end
        return nil
    end

    -- <leader>mh: toggle hunk fold under cursor (changed lines only, no context)
    vim.keymap.set('n', '<leader>mh', function()
        local cur_row = vim.api.nvim_win_get_cursor(0)[1]
        local fold_start, fold_end, meta = hunk_fold_info_at(cur_row)
        if fold_start then
            toggle_fold(fold_start, fold_end, meta)
            if vim.fn.foldclosed(fold_start) ~= -1 then
                M.jump_to_hunk(bufnr, true)
            end
        else
            vim.notify('No hunk at cursor position', vim.log.levels.WARN)
        end
    end, { buffer = bufnr, silent = true })
    help.register_keybind(bufnr, '<leader>mh', 'fold/unfold hunk', 'keybind')

    -- <leader>mc: toggle context fold (header + context lines + changed lines)
    vim.keymap.set('n', '<leader>mc', function()
        local cur_row = vim.api.nvim_win_get_cursor(0)[1]
        local fold_start, fold_end, meta = context_hunk_fold_info_at(cur_row)
        if fold_start then
            toggle_fold(fold_start, fold_end, meta)
            if vim.fn.foldclosed(fold_start) ~= -1 then
                M.jump_to_hunk(bufnr, true)
            end
        else
            vim.notify('No hunk at cursor position', vim.log.levels.WARN)
        end
    end, { buffer = bufnr, silent = true })
    help.register_keybind(bufnr, '<leader>mc', 'fold/unfold hunk with context', 'keybind')

    -- zc: only closes the hunk fold (never opens/deletes)
    vim.keymap.set('n', 'zc', function()
        local cur_row = vim.api.nvim_win_get_cursor(0)[1]
        local fold_start, fold_end, meta = hunk_fold_info_at(cur_row)
        if fold_start then
            close_fold(fold_start, fold_end, meta)
            if vim.fn.foldclosed(fold_start) ~= -1 then
                M.jump_to_hunk(bufnr, true)
            end
        end
    end, { buffer = bufnr, silent = true })
    help.register_keybind(bufnr, 'zc', 'fold hunk', 'keybind')

    -- <Tab>: open closed fold recursively
    vim.keymap.set('n', '<Tab>', function()
        if vim.fn.foldclosed(vim.api.nvim_win_get_cursor(0)[1]) ~= -1 then
            vim.cmd('normal! zO')
        end
    end, { buffer = bufnr, silent = true })
    help.register_keybind(bufnr, '<Tab>', 'open fold recursively', 'keybind')

    vim.api.nvim_create_autocmd('BufUnload', {
        buffer = bufnr, once = true,
        callback = function()
            -- Stash folds + viewport before clearing metadata: for acwrite buffers
            -- BufUnload fires before BufReadCmd, and by the time BufReadCmd fires
            -- the buffer is empty so winsaveview() would return {lnum=1, topline=1}.
            M._reload_fold_stash[bufnr] = M.capture_fold_state(bufnr)
            M._reload_view_stash[bufnr] = vim.fn.winsaveview()
            M._fold_metadata[bufnr] = nil
        end,
    })
end

--- @param bufnr number
M.setup_hunk_navigation = function(bufnr)
    vim.keymap.set('n', config.options.keyconfig.next_hunk, function()
        M.jump_to_hunk(bufnr, true)
    end, { buffer = bufnr, silent = true })
    help.register_keybind(bufnr, config.options.keyconfig.next_hunk, 'jump to next hunk', 'keybind')

    vim.keymap.set('n', config.options.keyconfig.prev_hunk, function()
        M.jump_to_hunk(bufnr, false)
    end, { buffer = bufnr, silent = true })
    help.register_keybind(bufnr, config.options.keyconfig.prev_hunk, 'jump to previous hunk', 'keybind')

    if config.options.keyconfig.next_diff and config.options.keyconfig.next_diff ~= '' then
        vim.keymap.set('n', config.options.keyconfig.next_diff, function()
            M.jump_to_file(bufnr, true)
        end, { buffer = bufnr, silent = true })
        help.register_keybind(bufnr, config.options.keyconfig.next_diff, 'jump to next file', 'keybind')
    end

    if config.options.keyconfig.prev_diff and config.options.keyconfig.prev_diff ~= '' then
        vim.keymap.set('n', config.options.keyconfig.prev_diff, function()
            M.jump_to_file(bufnr, false)
        end, { buffer = bufnr, silent = true })
        help.register_keybind(bufnr, config.options.keyconfig.prev_diff, 'jump to previous file', 'keybind')
    end
end

--- jumps to a hunk when user is on a diff buffer
--- jumps to the top of each hunk
--- when no more hunks are left to go to, it will cycle through. eg. if at the end, go back to top.
--- @param bufnr number
--- @param forward boolean
M.jump_to_hunk = function(bufnr, forward)
    local no_context_delta_diff_data_set = vim.b[bufnr].no_context_delta_diff_data_set -- data set with 0 context, as to properly distinguish hunks
    if no_context_delta_diff_data_set == nil then
        vim.notify('Something went wrong with parsing. Deltaview feature of hunk navigation will not be available.',
            vim.log.levels.WARN)
        return
    end

    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set -- real data set of buffer
    assert(delta_diff_data_set ~= nil)
    --- @cast delta_diff_data_set DiffData[]
    assert(no_context_delta_diff_data_set ~= nil)
    --- @cast no_context_delta_diff_data_set DiffData[]

    local cursor_placement = M.get_cursor_placement_current_buffer()

    -- used exclusively for messaging in fallback scenarios
    local hunk_prefix = { 0 }
    for i, d in ipairs(no_context_delta_diff_data_set) do
        hunk_prefix[i + 1] = hunk_prefix[i] + #d.hunks
    end
    local total_hunk_count = hunk_prefix[#hunk_prefix]

    local step = forward and 1 or -1
    local data_set_start = forward and 1 or #delta_diff_data_set
    local data_set_end = forward and #delta_diff_data_set or 1
    for data_set_idx = data_set_start, data_set_end, step do
        local diff_data = delta_diff_data_set[data_set_idx]
        local hunk_start = forward and 1 or #diff_data.hunks
        local hunk_end = forward and #diff_data.hunks or 1
        local parsed_hunk_start = forward and 1 or #no_context_delta_diff_data_set[data_set_idx].hunks
        local parsed_hunk_end = forward and #no_context_delta_diff_data_set[data_set_idx].hunks or 1
        for hunk_idx = hunk_start, hunk_end, step do
            local lines = diff_data.hunks[hunk_idx].lines

            local line_start = forward and cursor_placement.cursor[1] + 1 or cursor_placement.cursor[1] - 1
            local line_end = forward and
                lines[1].formatted_diff_line_num + 1 + #lines or
                lines[1].formatted_diff_line_num + 1

            local lines_by_row = {}
            for _, real_line in ipairs(lines) do
                lines_by_row[real_line.formatted_diff_line_num + 1] = real_line
            end

            for line_idx = line_start, line_end, step do
                local real_buf_line = lines_by_row[line_idx]
                if real_buf_line == nil then
                    goto continue
                end

                for parsed_hunk_idx = parsed_hunk_start, parsed_hunk_end, step do
                    local hunk_line = no_context_delta_diff_data_set[data_set_idx].hunks[parsed_hunk_idx]

                    if hunk_line.lines[1].new_line_num == real_buf_line.new_line_num and
                        hunk_line.lines[1].old_line_num == real_buf_line.old_line_num
                    then
                        local target_lnum = real_buf_line.formatted_diff_line_num + 1
                        -- Skip hunks that are inside a closed fold.
                        if vim.fn.foldclosed(target_lnum) ~= -1 then
                            goto continue
                        end
                        local header_lnum = lines[1].formatted_diff_line_num + 1
                        vim.api.nvim_win_set_cursor(0, { header_lnum, 0 })
                        vim.cmd('normal! zt')
                        vim.api.nvim_win_set_cursor(0, { target_lnum, 0 })
                        local file_ui = config.viewconfig().file .. ' '
                            ..  data_set_idx .. '|'
                            .. #delta_diff_data_set .. '  '
                        if #delta_diff_data_set == 1 then
                            file_ui = ''
                        end
                        local hunk_ui = config.viewconfig().segment .. ' '
                            .. hunk_prefix[data_set_idx] + parsed_hunk_idx .. '|'
                            .. total_hunk_count
                        vim.api.nvim_echo({ { 'jumped to  ' .. file_ui .. hunk_ui, 'Normal' }
                        }, false, {})

                        if _echo_timer then
                            _echo_timer:stop()
                            _echo_timer = nil
                        end
                        _echo_timer = vim.defer_fn(function()
                            _echo_timer = nil
                            vim.cmd('echo ""')
                        end, 2000)
                        return
                    end
                end
                ::continue::
            end
        end
    end
    vim.notify('No more hunks', vim.log.levels.INFO)
end

--- Jumps to the next or previous file section in a diff buffer.
--- Scrolls the file title to the top of the window and places the cursor on the
--- first changed line of that file, mirroring the behaviour of jump_to_hunk.
--- @param bufnr number
--- @param forward boolean
M.jump_to_file = function(bufnr, forward)
    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
    local no_context_dds      = vim.b[bufnr].no_context_delta_diff_data_set
    if not delta_diff_data_set then return end

    local cur_row = vim.api.nvim_win_get_cursor(0)[1]

    -- Build file sections list (same boundary logic as get_file_sections).
    local sections = {}
    local prev_last_row = 0
    for i, diff_data in ipairs(delta_diff_data_set) do
        if diff_data.new_path and #diff_data.hunks > 0 then
            local last_hunk = diff_data.hunks[#diff_data.hunks]
            local end_row   = last_hunk.lines[#last_hunk.lines].formatted_diff_line_num + 1
            table.insert(sections, {
                start_row = prev_last_row + 1,
                end_row   = end_row,
                data_idx  = i,
            })
            prev_last_row = end_row
        end
    end

    if #sections == 0 then return end

    -- Find which section the cursor is currently in.
    local cur_section_idx = nil
    for i, s in ipairs(sections) do
        if cur_row >= s.start_row and cur_row <= s.end_row then
            cur_section_idx = i
            break
        end
    end

    -- Pick the target section.
    local target
    if forward then
        local next_idx = cur_section_idx and cur_section_idx + 1 or 1
        target = sections[next_idx]
    else
        local prev_idx = cur_section_idx and cur_section_idx - 1 or #sections
        target = sections[prev_idx]
    end

    if not target then
        vim.notify('No more files', vim.log.levels.INFO)
        return
    end

    -- Find the first changed line in the target file section.
    local first_changed_row = nil
    if no_context_dds then
        local nc = no_context_dds[target.data_idx]
        if nc and #nc.hunks > 0 and #nc.hunks[1].lines > 0 then
            first_changed_row = nc.hunks[1].lines[1].formatted_diff_line_num + 1
        end
    end

    -- Scroll file title to top, then move cursor to first changed line.
    vim.api.nvim_win_set_cursor(0, { target.start_row, 0 })
    vim.cmd('normal! zt')
    if first_changed_row then
        vim.api.nvim_win_set_cursor(0, { first_changed_row, 0 })
    end
end

--- Reverts the hunk under the cursor by applying the inverse patch via git apply.
--- Works for both single-file (deltaview_file) and multi-file (delta_path) diff buffers.
--- @param bufnr number buf_id of the diff buffer
M.revert_hunk_under_cursor = function(bufnr)
    local no_context_diff_data_set = vim.b[bufnr].no_context_delta_diff_data_set
    local delta_diff_data_set = vim.b[bufnr].delta_diff_data_set
    local git_root = vim.b[bufnr].git_root

    if not no_context_diff_data_set or not delta_diff_data_set or not git_root then
        vim.notify('Hunk revert is not available for this buffer', vim.log.levels.WARN)
        return
    end

    local cur_row = vim.api.nvim_win_get_cursor(0)[1]

    for data_idx, diff_data in ipairs(no_context_diff_data_set) do
        for _, hunk in ipairs(diff_data.hunks) do
            local first_row = hunk.lines[1].formatted_diff_line_num + 1
            local last_row = hunk.lines[#hunk.lines].formatted_diff_line_num + 1

            if cur_row >= first_row and cur_row <= last_row then
                -- Determine the file path (relative to git_root)
                local full_diff_data = delta_diff_data_set[data_idx]
                local rel_path = full_diff_data and full_diff_data.new_path
                if not rel_path then
                    local source = vim.b[bufnr].source_filepath
                    if source and vim.startswith(source, git_root .. '/') then
                        rel_path = source:sub(#git_root + 2)
                    end
                end
                if not rel_path then
                    vim.notify('Cannot determine file path for revert', vim.log.levels.ERROR)
                    return
                end

                -- Collect added/removed lines and compute hunk header numbers
                local patch_body = {}
                local first_old_num, first_new_num = nil, nil
                local old_count, new_count = 0, 0

                for _, line in ipairs(hunk.lines) do
                    if line.line_type == 'removed' then
                        first_old_num = first_old_num or line.old_line_num
                        old_count = old_count + 1
                        table.insert(patch_body, '-' .. line.content)
                    elseif line.line_type == 'added' then
                        first_new_num = first_new_num or line.new_line_num
                        new_count = new_count + 1
                        table.insert(patch_body, '+' .. line.content)
                    end
                end

                -- git unified diff @@ header: if count==0, start is the line before the insertion point
                local old_start = first_old_num or math.max(0, (first_new_num or 1) - 1)
                local new_start = first_new_num or first_old_num or 1

                local hunk_header = string.format('@@ -%d,%d +%d,%d @@', old_start, old_count, new_start, new_count)
                local patch = table.concat({
                    'diff --git a/' .. rel_path .. ' b/' .. rel_path,
                    '--- a/' .. rel_path,
                    '+++ b/' .. rel_path,
                    hunk_header,
                    table.concat(patch_body, '\n'),
                    '',
                }, '\n')

                local result = vim.system(
                    { 'git', '-C', git_root, 'apply', '--reverse', '--unidiff-zero', '--whitespace=nowarn' },
                    { stdin = patch }
                ):wait()

                if result.code ~= 0 then
                    vim.notify('Failed to revert hunk: ' .. (result.stderr or ''), vim.log.levels.ERROR)
                    return
                end

                M._post_revert_target = {
                    rel_path = rel_path,
                    new_line_num = first_new_num or first_old_num or 1,
                    data_idx = data_idx,
                }
                local refresh_fn = M._refresh_fns[bufnr]
                vim.schedule(function()
                    vim.api.nvim_buf_delete(bufnr, { force = true })
                    if refresh_fn then refresh_fn() end
                end)
                return
            end
        end
    end

    vim.notify('No changed hunk at cursor position', vim.log.levels.WARN)
end

--- Places the cursor in a freshly-opened diff buffer after a hunk revert.
--- Tries the closest remaining hunk in the same file; falls back to an adjacent file.
--- @param new_bufnr number
--- @param target {rel_path: string|nil, new_line_num: number, data_idx: number}
M.place_cursor_after_revert = function(new_bufnr, target)
    local delta_diff_data_set = vim.b[new_bufnr].delta_diff_data_set
    local no_context_diff_data_set = vim.b[new_bufnr].no_context_delta_diff_data_set
    if not delta_diff_data_set or not no_context_diff_data_set then return end

    -- Returns the buffer row of the hunk closest to target_line in the given data_idx,
    -- or nil if that file has no hunks.
    local function closest_row_in(data_idx, target_line)
        local nc = no_context_diff_data_set[data_idx]
        if not nc or #nc.hunks == 0 then return nil end
        local best_row, best_dist = nil, math.huge
        for _, hunk in ipairs(nc.hunks) do
            local line_num
            for _, l in ipairs(hunk.lines) do
                line_num = l.new_line_num or l.old_line_num
                if line_num then break end
            end
            if line_num then
                local dist = math.abs(line_num - target_line)
                if dist < best_dist then
                    best_dist = dist
                    best_row = hunk.lines[1].formatted_diff_line_num + 1
                end
            end
        end
        return best_row
    end

    -- Find the file index for the target (nil new_path = single-file text_diff, always index 1)
    local same_file_idx = nil
    for i, dd in ipairs(delta_diff_data_set) do
        if dd.new_path == nil or dd.new_path == target.rel_path then
            same_file_idx = i
            break
        end
    end

    local target_row = same_file_idx and closest_row_in(same_file_idx, target.new_line_num)

    if not target_row then
        -- File is gone from diff: walk backwards then forwards for an adjacent file
        for i = target.data_idx - 1, 1, -1 do
            local nc = no_context_diff_data_set[i]
            if nc and #nc.hunks > 0 then
                target_row = nc.hunks[#nc.hunks].lines[1].formatted_diff_line_num + 1
                break
            end
        end
        if not target_row then
            for i = target.data_idx + 1, #no_context_diff_data_set do
                local nc = no_context_diff_data_set[i]
                if nc and #nc.hunks > 0 then
                    target_row = nc.hunks[1].lines[1].formatted_diff_line_num + 1
                    break
                end
            end
        end
    end

    if target_row then
        vim.api.nvim_win_set_cursor(0, { target_row, 0 })
        vim.cmd('normal! zz')
    end
end


return M

--- @alias CursorPlacement { winnr: number, filepath: string | nil, cursor: number[] }

--- @class CursorLookupEntry
--- @field new_line_num number
--- @field filepath string | nil
