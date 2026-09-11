local all_branches = {}

vim.schedule(function()
    -- fetch git branches once at setup time
    local result = vim.system({'git', 'branch', '--format=%(refname:short)'}):wait()
    if result.code == 0 and result.stdout ~= '' then
        all_branches = vim.split(result.stdout, "\n", { trimempty = true })
    end
end)

--- Filter git refs based on user input (case insensitive)
--- @param refs table List of git refs
--- @param arg_lead string User's partial input
--- @return table Filtered list of refs
local filter_refs = function(refs, arg_lead)
    local filtered = {}
    local arg_lead_lower = string.lower(arg_lead)
    for _, ref in ipairs(refs) do
        if vim.startswith(string.lower(ref), arg_lead_lower) then
            table.insert(filtered, ref)
        end
    end
    return filtered
end

--- @param ref_arg_position number position of the ref in the arguments list of the user command
local ref_complete = function(ref_arg_position)
    return function(arg_lead, cmd_line, _)
        local args = vim.split(cmd_line, '%s+')
        if #args == ref_arg_position then
            local refs = { 'HEAD' }
            for _, branch in ipairs(all_branches) do
                table.insert(refs, branch)
            end
            return filter_refs(refs, arg_lead)
        end
        return {}
    end
end

--- Run git merge-base <ref> HEAD and return the resulting commit hash, or nil on error.
--- @param ref string git ref (branch, tag, commit, etc.)
--- @return string | nil
local get_merge_base = function(ref)
    local result = vim.system({ 'git', 'merge-base', ref, 'HEAD' }):wait()
    if result.code ~= 0 then
        vim.notify('Failed to get merge base for ' .. ref .. ': ' .. result.stderr, vim.log.levels.ERROR)
        return nil
    end
    return vim.trim(result.stdout)
end

-- :Diff command — view current file's diff vs merge-base of <ref>
vim.api.nvim_create_user_command('Diff', function(args)
    local ref = args.args ~= '' and args.args or 'master'
    local base = get_merge_base(ref)
    if base == nil then return end
    local ok, err = pcall(require('deltaview.view').deltaview_file, base)
    if not ok then
        vim.notify('Diff failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
end, {
    nargs = '?',
    complete = ref_complete(2),
    desc = 'Show diff of current file vs merge-base of <ref> (default: master)',
})

-- :Diffall command — view all changed files' diffs vs merge-base of <ref>
vim.api.nvim_create_user_command('Diffall', function(args)
    local ref = args.args ~= '' and args.args or 'master'
    local base = get_merge_base(ref)
    if base == nil then return end
    local state = require('deltaview.state')
    local ok, err = pcall(require('deltaview.view').delta_path, base, state.default_context, vim.fn.getcwd())
    if not ok then
        vim.notify('Diffall failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
end, {
    nargs = '?',
    complete = ref_complete(2),
    desc = 'Show all file diffs vs merge-base of <ref> (default: master)',
})
