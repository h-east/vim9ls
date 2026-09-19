# vim9ls

[![Test](https://github.com/h-east/vim9ls/actions/workflows/test.yml/badge.svg)](https://github.com/h-east/vim9ls/actions/workflows/test.yml)
[![Update doc/tags](https://github.com/h-east/vim9ls/actions/workflows/update-doc-tags.yml/badge.svg)](https://github.com/h-east/vim9ls/actions/workflows/update-doc-tags.yml)
[![Vim 9.2.1xxx+](https://img.shields.io/badge/Vim-9.2.1xxx%2B-015b01?logo=vim&logoColor=white)](#requirements)

A language server for Vim9 script and legacy Vim script, run by Vim itself.

vim9ls is written in Vim9 script and runs in a Vim of its own, so it answers
from what that Vim knows: its help files, its builtin functions, options and
commands, and the plugins you already have.  A new function or option is
there as soon as Vim has it, since nothing is copied out of Vim.  Nothing
else needs to be installed.

The diagnostics are Vim's own.  The script is read with `:source ++dryrun`,
which runs nothing in it and compiles its `:def` functions, so what is
reported is what Vim finds in the script, not what another parser guesses.

## Requirements

Vim 9.2.1xxx or later with `+channel` and `+job`.

<details>
<summary>What those patches are for</summary>

- 9.2.1xxx: `getinfo()` names and types the arguments in the signature
  help of a builtin
- 9.2.1084: `:source ++dryrun` brings the diagnostics from Vim itself
- 9.2.1055: lets a function holding a lambda compile after an earlier one
  failed, which the checker relies on
- 9.2.1049: adds `--stdio-channel`, which is how the server talks to a client
  on stdin and stdout

</details>

## Installation

With a plugin manager, vim-plug for instance:

```vim
Plug 'h-east/vim9ls'
```

## Setup

Any LSP client that talks stdio can use the server.
[lsp.vim](https://github.com/h-east/lsp.vim) is the recommended one.

With lsp.vim: install it the same way and add the server to
`g:lsp_server_list`:

    {filetypes: ['vim'], name: 'vim9ls', cmd: function('vim9ls#Command')}

With another LSP client: point it at `bin/vim9ls` (`bin/vim9ls.cmd` on
MS-Windows).

See `:help vim9ls` for the details.

## What it does

- Hover: the help entry for the builtin function, option, Ex command or `v:`
  variable under the cursor.
- Completion: builtin functions, options, commands, and what the script
  defines; after a `.` the exported names of an import or the members of a
  class, after `foo#bar#` the autoload functions of that file.
- Document symbols: functions, variables, classes and their members, enums,
  interfaces, augroups, imports and user commands.
- Definition, references and rename for what the script defines; definition
  follows imports and legacy autoload functions into other files, and
  references and rename follow an exported name or an autoload function into
  the other files of the plugin and the open documents.
- Signature help for builtin functions and the script's own; with a Vim
  that has `getinfo()` the arguments of a builtin come with their names
  and types as Vim reports them, and the return type.
- Code actions: a quick fix for what the parser reports, `:let` to `var`,
  the `endif` a block lacks, an `endif` without an `if`.
- Inlay hints: the type of a `var` that leaves it to the initializer, as
  the Vim9 compiler infers it, and the parameter names at a call.
- Diagnostics: blocks that do not add up, `:let` under Vim9 rules, in legacy
  script words that are not commands, calls of functions that are not
  defined, and `v:` variables Vim does not have.  And from Vim itself: a type
  mismatch, a name that is not found, an argument too many, in a `:def`
  function and, in a Vim9 script, at the script level.

## Protocol coverage

What this server does with each of the 95 requests and notifications in the
LSP 3.18 meta model: 19 are answered, 11 are planned and listed in the TODO
below, and 65 are left out for the reason given.

<details>
<summary>Method-by-method tables</summary>

### Lifecycle

| Method | State | Note |
| --- | --- | --- |
| `initialize` | yes | position encoding "utf-8" when the client offers it, "utf-16" otherwise |
| `initialized` | yes | nothing to do |
| `shutdown` | yes |  |
| `exit` | yes |  |
| `client/registerCapability` | no | every capability is announced at `initialize` |
| `client/unregisterCapability` | no |  |
| `$/cancelRequest` | no | a request is answered before the next one is read |
| `$/progress` | no | nothing takes long enough to report on |
| `$/setTrace` | no | `$VIM9LS_LOG` holds the channel log anyway |
| `$/logTrace` | no |  |

### Keeping the server in step with the buffer

| Method | State | Note |
| --- | --- | --- |
| `textDocument/didOpen` | yes |  |
| `textDocument/didChange` | yes | incremental |
| `textDocument/didSave` | yes | the diagnostics once more, on the saved text |
| `textDocument/didClose` | yes |  |
| `textDocument/willSave` | no | nothing to do before a write |
| `textDocument/willSaveWaitUntil` | no |  |
| `notebookDocument/didOpen` | no | Vim script has no notebooks |
| `notebookDocument/didChange` | no |  |
| `notebookDocument/didSave` | no |  |
| `notebookDocument/didClose` | no |  |

### Language features

| Method | State | Note |
| --- | --- | --- |
| `textDocument/completion` | yes | triggered by `&` and `:` as well |
| `completionItem/resolve` | yes | the help entry of a builtin, fetched for the item that is looked at |
| `textDocument/hover` | yes | the help entry; for editors other than Vim, which has `K` |
| `textDocument/signatureHelp` | yes | triggered by `(` and `,` as well |
| `textDocument/declaration` | no | Vim script declares nothing apart from the definition |
| `textDocument/definition` | yes |  |
| `textDocument/typeDefinition` | planned | the class a Vim9 variable is typed with |
| `textDocument/implementation` | planned | the classes that implement a Vim9 interface |
| `textDocument/references` | yes |  |
| `textDocument/documentHighlight` | yes | the other uses of the name in the document, a declaration or an assignment marked as a write |
| `textDocument/documentSymbol` | yes |  |
| `textDocument/codeAction` | yes | a quick fix for what a diagnostic reports: `:let` to `var`, a missing `endif` |
| `codeAction/resolve` | no | an action comes with its edit |
| `textDocument/codeLens` | no | nothing here has a line to put above the code |
| `codeLens/resolve` | no |  |
| `textDocument/documentLink` | no | definition already follows an import to its file |
| `documentLink/resolve` | no |  |
| `textDocument/foldingRange` | planned | the blocks the parser already finds |
| `textDocument/selectionRange` | no | Vim has text objects for that |
| `textDocument/prepareCallHierarchy` | no |  |
| `callHierarchy/incomingCalls` | no | references show the callers, and a function body its calls |
| `callHierarchy/outgoingCalls` | no |  |
| `textDocument/prepareTypeHierarchy` | planned | what a Vim9 class extends and implements, and what extends it |
| `typeHierarchy/supertypes` | planned |  |
| `typeHierarchy/subtypes` | planned |  |
| `textDocument/semanticTokens/full` | no | Vim's syntax file does the highlighting |
| `textDocument/semanticTokens/full/delta` | no |  |
| `textDocument/semanticTokens/range` | no |  |
| `textDocument/inlayHint` | yes | the type of a `var` that leaves it to the initializer, and the parameter names at a call |
| `inlayHint/resolve` | no | a hint comes complete |
| `textDocument/publishDiagnostics` | yes | after the changes pause |
| `textDocument/diagnostic` | no | diagnostics are sent, not asked for |
| `textDocument/formatting` | planned | Vim's own indent script, run in the server; for editors other than Vim |
| `textDocument/rangeFormatting` | planned |  |
| `textDocument/rangesFormatting` | no |  |
| `textDocument/onTypeFormatting` | no | Vim indents as you type on its own |
| `textDocument/rename` | yes |  |
| `textDocument/prepareRename` | yes | turns a rename down before it is tried |
| `textDocument/linkedEditingRange` | no | nothing here mirrors an edit into another range |
| `textDocument/documentColor` | no | nothing here is a color |
| `textDocument/colorPresentation` | no |  |
| `textDocument/inlineValue` | no | for a debugger, which this is not |
| `textDocument/inlineCompletion` | no | completion is asked for, not offered while typing |
| `textDocument/moniker` | no | for an indexer, which this is not |

### Workspace

| Method | State | Note |
| --- | --- | --- |
| `workspace/symbol` | planned | the names the autoload and plugin files on 'runtimepath' define |
| `workspaceSymbol/resolve` | no |  |
| `workspace/configuration` | no | nothing to configure |
| `workspace/didChangeConfiguration` | no |  |
| `workspace/workspaceFolders` | no | the server reads the file it is given and the files it imports; there is no workspace |
| `workspace/didChangeWorkspaceFolders` | no |  |
| `workspace/didChangeWatchedFiles` | no |  |
| `workspace/executeCommand` | no | nothing here runs a command |
| `workspace/applyEdit` | no | the edits of a rename go back as its answer |
| `workspace/diagnostic` | no | diagnostics are sent per document |
| `workspace/willCreateFiles` | no | nothing here depends on a file being made, moved or deleted |
| `workspace/didCreateFiles` | no |  |
| `workspace/willRenameFiles` | no |  |
| `workspace/didRenameFiles` | no |  |
| `workspace/willDeleteFiles` | no |  |
| `workspace/didDeleteFiles` | no |  |
| `workspace/codeLens/refresh` | no | nothing changes behind the client's back |
| `workspace/inlayHint/refresh` | no |  |
| `workspace/semanticTokens/refresh` | no |  |
| `workspace/diagnostic/refresh` | no |  |
| `workspace/foldingRange/refresh` | no |  |
| `workspace/inlineValue/refresh` | no |  |
| `workspace/textDocumentContent` | no | nothing here makes a document up |
| `workspace/textDocumentContent/refresh` | no |  |

### Window

| Method | State | Note |
| --- | --- | --- |
| `window/showMessage` | no | nothing here needs the user's attention |
| `window/showMessageRequest` | no |  |
| `window/logMessage` | no | what goes wrong goes to `$VIM9LS_LOG`, with the messages around it |
| `window/showDocument` | no | nothing here opens a document |
| `window/workDoneProgress/create` | no |  |
| `window/workDoneProgress/cancel` | no |  |
| `telemetry/event` | no | there is nothing to report |

</details>

## TODO

In the order they are meant to be taken up.

- [x] Diagnostics for a function that is neither defined by the script nor
      a builtin, and for a `v:` variable Vim does not have.
- [x] Definition, references and rename across files: a name defined in an
      imported script or an autoload file, found in the files that use it.
- [x] Vim9 block scope: a `var` inside a block belongs to that block, so two
      blocks of one function can declare the same name.
- [x] Completion of the exported names after an import alias, of autoload
      functions after `foo#`, and of members after `.`.
- [x] `completionItem/resolve`: the help entry of a builtin, fetched for the
      item that is looked at rather than sent with every item.
- [x] Diagnostics for what compiling a `:def` reports, from the checker: a
      Vim of its own that is started once and kept, and reads the script
      with `:source ++dryrun`.
- [x] `textDocument/codeAction` with a quick fix for what a diagnostic
      reports: `:let` to `var` under Vim9 rules, the `endif` a block lacks.
- [x] Signature help with the types of a builtin's arguments; the help entry
      names them but does not type them.  Vim hands them out with
      `getinfo()`.
- [x] The type of an expression as the Vim9 compiler infers it, for the
      hints and the hover to come: literals, operators, indexing, lambdas,
      the script's own functions by their declared type and the builtins by
      what `getinfo()` reports for the argument types.
- [x] `textDocument/inlayHint` with the type of a `var` that leaves it to
      the initializer, and the parameter names at a call from what
      signature help knows.
- [ ] `workspace/symbol` over the autoload and plugin files on `'runtimepath'`.
- [ ] `textDocument/foldingRange`, from what the parser already knows.
- [ ] `textDocument/typeDefinition`, `textDocument/implementation` and the
      type hierarchy for Vim9 classes and interfaces.
- [ ] `textDocument/formatting` and `rangeFormatting` with Vim's own indent
      script, run in the server; for editors other than Vim.
- [x] Tests on MS-Windows in CI, and the launchers `bin/vim9ls` and
      `bin/vim9ls.cmd` started the way a client starts them.
- [ ] Hover in Markdown, for the editors that render it.

## Contributing

How a report or a patch is best put, and how the tests are run, is in
[CONTRIBUTING](.github/CONTRIBUTING.md).

## AI

This plugin is developed with the support of AI (Claude).

## License

Vim license, see LICENSE.
