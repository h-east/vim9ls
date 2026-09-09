# vim9ls

[![Test](https://github.com/h-east/vim9ls/actions/workflows/test.yml/badge.svg)](https://github.com/h-east/vim9ls/actions/workflows/test.yml)
[![Update doc/tags](https://github.com/h-east/vim9ls/actions/workflows/update-doc-tags.yml/badge.svg)](https://github.com/h-east/vim9ls/actions/workflows/update-doc-tags.yml)
[![Vim 9.2.1049+](https://img.shields.io/badge/Vim-9.2.1049%2B-015b01?logo=vim&logoColor=white)](#requirements)

A language server for Vim9 script and legacy Vim script, run by Vim itself.

vim9ls is written in Vim9 script and runs in a Vim of its own, so it answers
from what that Vim knows: its help files, its builtin functions, options and
commands, and the plugins you already have.  A new function or option is
there as soon as Vim has it, since nothing is copied out of Vim.  Nothing
else needs to be installed.

## Requirements

Vim 9.2.1049 or later with `+channel` and `+job`. The `--stdio-channel`
argument came with that patch.

## Installation

With a plugin manager, vim-plug for instance:

```vim
Plug 'h-east/vim9ls'
```

Or as an optional package, put it under `pack/*/opt/vim9ls` and load it from
your vimrc:

```vim
packadd! vim9ls
```

## Setup

Any LSP client that talks stdio can use the server.
[lsp.vim](https://github.com/h-east/lsp.vim) is the recommended one.

With lsp.vim: install it the same way and add the server to
`g:lsp_server_list`:

    {name: 'vim9ls', filetypes: ['vim'], cmd: function('vim9ls#Command')}

With another LSP client: point it at `bin/vim9ls` (`bin/vim9ls.cmd` on
MS-Windows).

See `:help vim9ls` for the details.

## What it does

- Hover: the help entry for the builtin function, option, Ex command or `v:`
  variable under the cursor.
- Completion: builtin functions, options, commands, and what the script
  defines.
- Document symbols: functions, variables, classes and their members, enums,
  interfaces, augroups, imports and user commands.
- Definition, references and rename for what the script defines; definition
  also follows imports and legacy autoload functions into other files.
- Signature help for builtin functions and the script's own.
- Diagnostics: blocks that do not add up, `:let` under Vim9 rules, and, in
  legacy script, words that are not commands.

## Tests

    cd test && ./run

The Vim the tests run in is also the server they start; name one with
`VIMPROG=/path/to/vim ./run`.

## AI

This plugin is developed with the support of AI (Claude).

## License

Vim license, see LICENSE.
