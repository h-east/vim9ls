# vim9ls

[![Vim 9.2.1049+](https://img.shields.io/badge/Vim-9.2.1049%2B-015b01?logo=vim&logoColor=white)](#requirements)

A language server for Vim script, run by Vim itself.

vim9ls is written in Vim9 script and runs in a Vim of its own.  A client
starts it as

    vim --clean --stdio-channel -S /path/to/autoload/vim9ls.vim

and talks LSP to it on stdin and stdout.  The server answers from what Vim
knows: the help files for hover, `getcompletion()` for the builtin functions,
options and commands, and the user's own `'runtimepath'`.
Nothing else needs to be installed.

## Requirements

Vim 9.2.1049 or later with `+channel` and `+job`. The `--stdio-channel`
argument came with that patch.

## Setup

With [lsp.vim](https://github.com/h-east/lsp.vim): install both plugins and
add the server to `g:lsp_server_list`:

    {name: 'vim9ls', filetypes: ['vim'], cmd: vim9ls#Command()}

With another editor: point its LSP client at `bin/vim9ls` (`bin/vim9ls.cmd` on
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
