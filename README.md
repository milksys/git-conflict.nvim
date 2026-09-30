# git-conflict.nvim

https://user-images.githubusercontent.com/22454918/159362564-a66d8c23-f7dc-4d1d-8e88-c5c73a49047e.mov

A plugin to visualise and resolve conflicts in neovim.
This plugin was inspired by [conflict-marker.vim](https://github.com/rhysd/conflict-marker.vim)

> [!NOTE]
> This is a maintained fork of [akinsho/git-conflict.nvim](https://github.com/akinsho/git-conflict.nvim).

## Status

This plugin is under active development, it should generally work, but you're likely to
encounter some bugs during usage.

## Requirements

- `git`
- `nvim 0.11+`

## Installation

```lua
-- packer.nvim
use {'milksys/git-conflict.nvim', tag = "*", config = function()
  require('git-conflict').setup()
end}

-- lazy.nvim
{'milksys/git-conflict.nvim', version = "*", config = true}
```

I recommend using the {tag|version} field of your package manager, so your version of this plugin is only updated when a new tag is pushed as `main` itself might be **unstable**.

## Configuration

```lua
{
  default_mappings = true, -- disable buffer local mapping created by this plugin
  default_commands = true, -- disable commands created by this plugin
  disable_diagnostics = false, -- This will disable the diagnostics in a buffer whilst it is conflicted
  list_opener = 'copen', -- command or function to open the conflicts list
  show_keymap_hints = false, -- show the default mappings next to the conflict labels
  word_diff = true, -- highlight the words that differ between the current and incoming changes
  operation_labels = true, -- describe each side based on the merge/rebase/cherry-pick in progress
  hide_ancestor = false, -- hide the base section of diff3 conflicts (see GitConflictToggleAncestor)
  on_file_resolved = nil, -- 'stage' | 'prompt' | function(bufnr, path), run on save once a file has no conflicts left
  picker = nil, -- 'snacks' | 'telescope' | 'fzf-lua' | 'select', detected automatically by default
  highlights = { -- They must have background color, otherwise the default color will be used
    incoming = 'DiffAdd',
    current = 'DiffText',
  }
}
```

### Labels during a rebase

During a rebase git's "ours" is the branch being rebased onto and "theirs" is your own commit,
which is easy to get the wrong way round. With `operation_labels` the labels say what each side
is, e.g. `(Current changes: rebasing onto main)` and `(Incoming changes: your commit from feature)`.
Merges, cherry-picks and reverts are described as well.

### Staging resolved files

Set `on_file_resolved = 'stage'` to `git add` a file when it is saved without any conflict markers
left, or `'prompt'` to be asked first. A function receives the buffer and path instead.

## Commands

- `GitConflictChooseOurs` — Select the current changes.
- `GitConflictChooseTheirs` — Select the incoming changes.
- `GitConflictChooseBoth` — Select both changes.
- `GitConflictChooseBothReverse` — Select both changes, incoming first.
- `GitConflictChooseBase` — Select the base (ancestor) changes, requires `merge.conflictStyle=diff3`.
- `GitConflictChooseNone` — Select none of the changes.
- `GitConflictChooseCursor` — Keep the section the cursor is in (ours, base or theirs).
- `GitConflictNextConflict` — Move to the next conflict.
- `GitConflictPrevConflict` — Move to the previous conflict.
- `GitConflictNextFile` — Open the next conflicted file at its first conflict.
- `GitConflictPrevFile` — Open the previous conflicted file at its last conflict.
- `GitConflictPreview` — Preview each way of resolving the conflict under the cursor in a floating
  window (`<Tab>`/`<S-Tab>` to cycle, `<CR>` to apply, `q` to close).
- `GitConflictToggleAncestor` — Hide or show the base section of diff3 conflicts.
- `GitConflictPick` — Pick a conflict from every conflicted file with
  [snacks](https://github.com/folke/snacks.nvim), [telescope](https://github.com/nvim-telescope/telescope.nvim),
  [fzf-lua](https://github.com/ibhagwan/fzf-lua) or `vim.ui.select`.
- `GitConflictListQf` — Get all conflict to quickfix
- `GitConflictRefresh` — Re-read the list of conflicted files from git

The `GitConflictChoose{Ours,Theirs,Both,BothReverse,Base,None}` commands accept a range
(e.g. `:'<,'>GitConflictChooseOurs` or `:%GitConflictChooseTheirs`), which resolves every
conflict inside it, and a bang (`:GitConflictChooseOurs!`) which resolves every conflict in the
buffer. In visual mode the default mappings resolve every conflict inside the selection.

### Listing conflicts

You can list conflicts in the quick fix list using the `GitConflictListQf` command

<img width="475" alt="Screen Shot 2022-03-27 at 12 03 43" src="https://user-images.githubusercontent.com/22454918/160278511-705a0361-a387-4fc1-8b20-bd799bf85b82.png">

quickfix displayed using [nvim-pqf](https://github.com/yorickpeterse/nvim-pqf)

## Autocommands

When a conflict is detected by this plugin a `User` autocommand is fired
called `GitConflictDetected`. When this is resolved another command is
fired called `GitConflictResolved`.

Each event fires once per change of state (including when git reports the file as resolved,
e.g. after `git add` or `git merge --abort`) and carries the buffer in `args.data.bufnr`.

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'GitConflictDetected',
  callback = function(args)
    local bufnr = args.data.bufnr
    vim.notify('Conflict detected in ' .. vim.api.nvim_buf_get_name(bufnr))
  end
})
```

## Mappings

This plugin offers default buffer local mappings inside conflicted files. This is primarily because applying these mappings only to relevant buffers
is impossible through global mappings. A user can however disable these by setting `default_mappings = false` anyway and create global mappings as shown below.
The default mappings are:

- <kbd>c</kbd><kbd>o</kbd> — choose ours
- <kbd>c</kbd><kbd>t</kbd> — choose theirs
- <kbd>c</kbd><kbd>b</kbd> — choose both
- <kbd>c</kbd><kbd>0</kbd> — choose none
- <kbd>]</kbd><kbd>x</kbd> — move to next conflict
- <kbd>[</kbd><kbd>x</kbd> — move to previous conflict
- <kbd>]</kbd><kbd>X</kbd> — open the next conflicted file
- <kbd>[</kbd><kbd>X</kbd> — open the previous conflicted file

Choosing a side can be repeated with <kbd>.</kbd>, e.g. <kbd>c</kbd><kbd>o</kbd> <kbd>]</kbd><kbd>x</kbd> <kbd>.</kbd>.
The file mappings stay available until git considers the file resolved, so you can move on to
the next file straight after resolving the last conflict.

If you would rather not use these then you can specify your own mappings, an empty string
disables a mapping.

```lua
require'git-conflict'.setup {
  default_mappings = {
    ours = 'o',
    theirs = 't',
    none = '0',
    both = 'b',
    both_reverse = 'B', -- not mapped by default
    next = 'n',
    prev = 'p',
    next_file = 'N',
    prev_file = 'P',
  },
}
```

or alternatively, set `default_mappings = false` and apply the mappings yourself

<details><summary>example manual mappings</summary>

```lua
vim.keymap.set({ 'n', 'x' }, 'co', '<Plug>(git-conflict-ours)')
vim.keymap.set({ 'n', 'x' }, 'ct', '<Plug>(git-conflict-theirs)')
vim.keymap.set({ 'n', 'x' }, 'cb', '<Plug>(git-conflict-both)')
vim.keymap.set({ 'n', 'x' }, 'cB', '<Plug>(git-conflict-both-reverse)')
vim.keymap.set({ 'n', 'x' }, 'c0', '<Plug>(git-conflict-none)')
vim.keymap.set('n', 'cc', '<Plug>(git-conflict-cursor)') -- keep the side under the cursor
vim.keymap.set('n', '[x', '<Plug>(git-conflict-prev-conflict)')
vim.keymap.set('n', ']x', '<Plug>(git-conflict-next-conflict)')
vim.keymap.set('n', '[X', '<Plug>(git-conflict-prev-file)')
vim.keymap.set('n', ']X', '<Plug>(git-conflict-next-file)')
vim.keymap.set('n', 'cp', '<Plug>(git-conflict-preview)')
```

</details>

## Statusline

`status()` returns the number of conflicts in the buffer and the number of conflicted files in
its repository, e.g. for [lualine](https://github.com/nvim-lualine/lualine.nvim):

```lua
sections = {
  lualine_x = {
    function()
      local status = require('git-conflict').status()
      if status.files == 0 then return '' end
      return ('conflicts: %d (%d files)'):format(status.buffer, status.files)
    end,
  },
}
```

## Highlights

The highlight groups can be overridden, e.g. in your colorscheme:
`GitConflictCurrent`, `GitConflictIncoming`, `GitConflictAncestor`, `GitConflictCurrentLabel`,
`GitConflictIncomingLabel`, `GitConflictAncestorLabel`, `GitConflictMiddleLabel` and, for the
word diff, `GitConflictCurrentText` and `GitConflictIncomingText`.

## Health

Run `:checkhealth git-conflict` to check your Neovim/git versions, the `merge.conflictStyle`
setting and whether the default mappings shadow existing ones.

## API

This plugin exposes an API to extract some of the data it collects for other
purposes.

<details><summary>conflict_count({bufnr})</summary>

```vimdoc
    Returns the amount of conflicts in a given buffer.
    

    Parameters:
	{bufnr} (number) Specify the buffer for which you want to know the
	                 amount of conflicts (default: current buffer).

    Return:
	number: The amount of conflicts.
```
</details>

<details><summary>status({bufnr})</summary>

```vimdoc
    Returns { buffer = number, files = number }: the conflicts in the buffer
    and the conflicted files in its repository.
```
</details>

<details><summary>conflicted_files({root})</summary>

```vimdoc
    Returns the sorted absolute paths of every conflicted file, optionally
    only those in the repository at {root}.
```
</details>

<details><summary>get_conflicts({bufnr})</summary>

```vimdoc
    Returns the conflicts in the buffer. Each has `current`, `incoming`,
    `ancestor` and `middle` sections with 0-based `range_start`/`range_end`
    (including the markers) and `content_start`/`content_end` lines.
```
</details>

<details><summary>choose({side}, {opts})</summary>

```vimdoc
    Resolve the conflict under the cursor, or every conflict inside
    {opts.range} ({start, end}, 1-based) or the visual selection.

    Parameters:
	{side} (string) 'ours' | 'theirs' | 'both' | 'both_reverse' | 'base' |
	                'none' | 'cursor'
```
</details>

<details><summary>choose_all({side})</summary>

```vimdoc
    Resolve every conflict in the current buffer with {side}.
```
</details>

<details><summary>find_next_file() / find_prev_file()</summary>

```vimdoc
    Open the next/previous conflicted file (in path order, wrapping around).
```
</details>

<details><summary>preview() / pick({picker}) / toggle_ancestor({hidden})</summary>

```vimdoc
    The functions behind GitConflictPreview, GitConflictPick and
    GitConflictToggleAncestor.
```
</details>

## Issues

**Please read this** — This plugin is not intended to do anything other than provide fancy visuals, and some mappings to handle conflict resolution
It will not be expanded to become a full git management plugin, there are a zillion plugins that do that already, this won't be one of those.

### Feature requests

Open source should be collaborative, if you have an idea for a feature you'd like to see added. Submit a PR rather than a feature request.
