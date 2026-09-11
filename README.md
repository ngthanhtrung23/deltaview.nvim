# deltaview.nvim

An inline git diff viewer for Neovim with two-tier diff highlighting and syntax highlighting inspired by the [delta](https://github.com/dandavison/delta) pager.

![DeltaView Screenshot](https://github.com/user-attachments/assets/d4d1e8aa-7fd1-4759-b658-45ca468c18fa)

## Why?

Alternative inline/unified diff viewers in the neovim plugin ecosystem tend to use virtual lines to display negative changes. Cursors cannot land on virtual lines, which disrupts scrolling. You cannot yank lines of code that were deleted. With a large block of negative changes that does not fit in the window's viewport, you cannot see the full extent of the changes.

This plugin creates inline diffs as readonly, separate buffers without virtual lines. You are able to use lsp features while reviewing changes, yank deleted lines of code, and navigate around a pull request as you would your normal files.

The key to what allows this approach to achieve (workflow wise) what other plugins achieve by creating diffs as highlights + virtual lines inside your buffers is the cursor placement, that allows you to jump into (and out of) a diff without losing your spot.

Another notable design difference from other diff viewers is the two tier highlighting. Instead of character level diffing, it is word level diffing, and more precisely, it is token level diffing. Token parsing is achieved using the same Tree-sitter parser used for highlighting, resulting in less noisy second tier highlights.

## Features

- **Inline diff viewing**: Lay lightweight diffs over your buffers to quickly view and unview changes
- **Two-tier highlighting**: Two tier diff highlighting, treesitter syntax highlighting
- **Cursor maintenance**: Opening a diff keeps your cursor where it was, and exiting a diff keeps your cursor where it was. Easily transition between reading and writing.
- **Quick Navigation**: Jump between hunks with `]c` / `[c`, between files with `]f` / `[f`
- **Sticky filename**: A winbar always shows which file the cursor is currently in when viewing a multi-file diff.
- **Source line navigation**: Type `:123` inside a diff buffer to jump to source line 123. If that line is not visible in the diff, the cursor does not move.
- **Mark as Viewed**: Fold individual hunks (`<leader>mh` / `zc`), hunks with context (`<leader>mc`), or entire file sections (`<leader>mf`) to a single summary line. Press `<Tab>` to unfold recursively.
- **Hunk Revert**: Revert the hunk under cursor back to HEAD with `<leader>hu`.
- **Large diff handling**: File sections with > 2000 changed lines are auto-folded to a summary line.
- **Flexible comparisons**: Compare against any git ref (HEAD, branches, commits, tags) using merge-base semantics

## Requirements

- Neovim >= 0.10
- Git

*NOTE*
- This plugin does not use [delta](https://github.com/dandavison/delta), and it is not a dependency

## Usage

### Commands

#### `:Diff [ref]`

Opens the diff view for the current file against the merge-base of `<ref>` and `HEAD`. This is equivalent to `git diff <ref>...HEAD` for the current file — i.e., "what changes did I make relative to where I branched off from `<ref>`?" Defaults to `origin/master` if no ref is given.

The cursor is placed at the matching location on entry and restored on exit.

```vim
:Diff                   " Compare current file vs merge-base of origin/master
:Diff HEAD              " Compare current file vs HEAD
:Diff develop           " Compare vs merge-base of develop branch
:Diff abc1234           " Compare vs merge-base of a specific commit
```

#### `:Diffall [ref]`

Opens the diff view for all changed files in the current working directory against the merge-base of `<ref>` and `HEAD`. Same merge-base semantics as `:Diff`. Defaults to `origin/master`.

```vim
:Diffall                " Show all changed files vs merge-base of master
:Diffall HEAD           " Show all files changed since HEAD
:Diffall develop        " Show all files changed vs merge-base of develop
```

### Keybinds

When viewing a diff (`:Diff` or `:Diffall`):

| Key                    | Action                                       |
| ---------------------- | -------------------------------------------- |
| `q`                    | Return to source file                        |
| `]c`                   | Next hunk (scrolls hunk header to top)       |
| `[c`                   | Previous hunk (scrolls hunk header to top)   |
| `]f`                   | Next file section                            |
| `[f`                   | Previous file section                        |
| `<leader>hu`           | Revert hunk under cursor to HEAD             |
| `<leader>mh` / `zc`   | Fold/unfold hunk (changed lines only)        |
| `<leader>mc`           | Fold/unfold hunk including context lines     |
| `<leader>mf`           | Fold/unfold entire file section              |
| `<Tab>`                | Open fold under cursor recursively           |
| `d?`                   | Open the help legend                         |

## Installation

[vim.pack](https://github.com/neovim/neovim/pull/34009)

```lua
vim.pack.add('https://github.com/kokusenz/deltaview.nvim')
```

Or your favorite plugin manager, such as [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    'kokusenz/deltaview.nvim',
}
```

## Configuration

### Full Configuration Example

```lua
require('deltaview').setup({
    -- disable nerd font icons if uninstalled (defaults to true)
    use_nerdfonts = false,

    -- will show the delta style line numbers in the statuscolumn.
    line_numbers = false,

    -- custom keybindings for diff buffers
    keyconfig = {
        -- navigate between hunks
        next_hunk = "]c",
        prev_hunk = "[c",

        -- navigate between file sections (Diffall only)
        next_diff = "]f",
        prev_diff = "[f",

        -- open help legend
        help_legend = "d?"
    }
})

-- for configuration of how the diff buffers look
require('delta').setup({
    -- default lines of context around each hunk.
    context = 3,

    highlighting = {
        -- minimum Levenshtein similarity (0.0–1.0) for two lines to be
        -- paired for word-level highlighting. The lower the number, the
        -- less similar two lines have to be to get word level
        -- highlighting. Matches delta's --max-line-distance option.
        max_similarity_threshold = 0.6,
    },

    -- Highlight group definitions, separated by background type.
    -- Each group accepts `fg`, `bg`, and `default` (boolean).
    -- When `default = true` the group will not override default colors
    -- To write a custom color, include default = false
    -- the examples have default = false, but the colors are the defaults
    highlight_groups = {
        dark = {
            DeltaDiffAddedLine = {
                bg = '#002800',  -- dark green background
                default = false
            },
            DeltaDiffRemovedLine = {
                bg = '#3f0001',  -- dark red background
                default = false
            },
            DeltaDiffAddedWord = {
                bg = '#006000',  -- brighter green
                default = false
            },
            DeltaDiffRemovedWord = {
                bg = '#901011',  -- brighter red
                default = false
            },
            DeltaTitle = {
                fg = '#24acd4',  -- light blue
                default = false
            },
            DeltaLineNrAdded = {
                fg = '#008400',  -- darker green for added line numbers
                default = false
            },
            DeltaLineNrRemoved = {
                fg = '#800202',  -- darker red for removed line numbers
                default = false
            },
            DeltaLineNrContext = {
                fg = '#444444',  -- darker gray for context line numbers
                default = false
            }
        },
        light = {
            DeltaDiffAddedLine = {
                bg = '#cfffd0',  -- light green background
                default = false
            },
            DeltaDiffRemovedLine = {
                bg = '#ffdee2',  -- light red background
                default = false
            },
            DeltaDiffAddedWord = {
                bg = '#9df0a2',  -- darker green (word level)
                default = false
            },
            DeltaDiffRemovedWord = {
                bg = '#ffc1bf',  -- darker red (word level)
                default = false
            },
            DeltaTitle = {
                fg = '#0088aa',  -- darker blue for light backgrounds
                default = false
            },
            DeltaLineNrAdded = {
                fg = '#008400',  -- darker green for added line numbers
                default = false
            },
            DeltaLineNrRemoved = {
                fg = '#800202',  -- darker red for removed line numbers
                default = false
            },
            DeltaLineNrContext = {
                fg = '#444444',  -- darker gray for context line numbers
                default = false
            }
        },
    },
})
```

## Troubleshooting
- `:help deltaview`
- Reach out via an issue
- Read the changelog for changes or breaking changes
