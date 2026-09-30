# vim9ls

[![Test](https://github.com/h-east/vim9ls/actions/workflows/test.yml/badge.svg)](https://github.com/h-east/vim9ls/actions/workflows/test.yml)
[![Update doc/tags](https://github.com/h-east/vim9ls/actions/workflows/update-doc-tags.yml/badge.svg)](https://github.com/h-east/vim9ls/actions/workflows/update-doc-tags.yml)
[![Vim 9.2.1160+](https://img.shields.io/badge/Vim-9.2.1160%2B-015b01?logo=vim&logoColor=white)](#requirements)

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

Vim 9.2.1160 or later with `+channel` and `+job`.

<details>
<summary>What those patches are for</summary>

- 9.2.1160: `getinfo()` names and types the arguments in the signature
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
  interfaces, augroups, imports and user commands.  The same names are
  searched across the workspace with `workspace/symbol`.
- Folding ranges: functions, classes, enums, interfaces, augroups, the
  blocks of `if`, `while`, `for` and `try`, and the runs of comments and of
  imports.
- Selection ranges: from the name under the cursor out through the string or
  the brackets it stands in, the statement with the lines it carries on
  over, the branch of each block and the block itself.
- Type definition: from a name to the class, interface or enum it is typed
  with, whether the type is written out or left to the initializer.
- Implementation: from an interface or a class to the classes that implement
  or extend it, and from a method of one to the method of each.
- Type hierarchy: what a class, an interface or an enum extends and
  implements, and what names it in turn.
- Formatting of the document or of a range, with the indent script of Vim
  itself; the blanks at the end of a line and the newline at the end of the
  document are seen to when the client asks for it.
- Definition, references and rename for what the script defines; definition
  follows imports and legacy autoload functions into other files, and
  references and rename follow an exported name or an autoload function into
  the other files of the plugin and the open documents.
- Signature help for builtin functions and the script's own; the arguments
  of a builtin come with their names and types as `getinfo()` reports them,
  and the return type.
- Code actions: a quick fix for a diagnostic, of the parser or of Vim,
  `:let` to `var`, the `endif` a block lacks, an `endif` without an `if`,
  `_` for a parameter that is not used.
- Inlay hints: the type of a `var` that leaves it to the initializer, as
  the Vim9 compiler infers it, and the parameter names at a call.
- Diagnostics: blocks that do not add up, `:let` under Vim9 rules, in legacy
  script words that are not commands, calls of functions that are not
  defined, `v:` variables Vim does not have, and, as hints, the variables and
  parameters of a `:def` function that are not used.  And from Vim itself: a
  type mismatch, a name that is not found, an argument too many, in a `:def`
  function and, in a Vim9 script, at the script level.  In a Vim9 script also
  a call in the keys of a mapping that is not defined where the keys find it,
  or takes another number of arguments.
- Workspace diagnostics: the same for the scripts of the workspace folders
  that are not open, at most 4096 by default, sent as they are read and
  again when they may have changed.  What was found is kept on disk, so that
  a server started again reads only the scripts that changed.

## Protocol coverage

What this server does with each of the 95 requests and notifications in the
LSP 3.18 meta model: 41 are answered and 54 are left out for the reason
given.

<details>
<summary>Method-by-method tables</summary>

### Lifecycle

| Method | State | Note |
| --- | --- | --- |
| `initialize` | yes | position encoding "utf-8" when the client offers it, "utf-16" otherwise |
| `initialized` | yes | where the log of `$VIM9LS_LOG` is, or why it cannot be opened |
| `shutdown` | yes |  |
| `exit` | yes |  |
| `client/registerCapability` | yes | the "*.vim" files to watch, the one thing not announced at `initialize` |
| `client/unregisterCapability` | no |  |
| `$/cancelRequest` | yes | for `workspace/diagnostic`, which is kept open; any other request is answered before the next one is read |
| `$/progress` | yes | the partial results of `workspace/diagnostic`, and how far its first reading has got |
| `$/setTrace` | no | the log of `$VIM9LS_LOG` has more |
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
| `textDocument/typeDefinition` | yes | the class, interface or enum a name is typed with, declared or inferred |
| `textDocument/implementation` | yes | the classes that implement an interface or extend a class, and their method of the same name |
| `textDocument/references` | yes |  |
| `textDocument/documentHighlight` | yes | the other uses of the name in the document, a declaration or an assignment marked as a write |
| `textDocument/documentSymbol` | yes |  |
| `textDocument/codeAction` | yes | a quick fix for what a diagnostic reports: `:let` to `var`, a missing `endif`, `_` for an unused parameter |
| `codeAction/resolve` | no | an action comes with its edit |
| `textDocument/codeLens` | no | nothing here has a line to put above the code |
| `codeLens/resolve` | no |  |
| `textDocument/documentLink` | no | definition already follows an import to its file |
| `documentLink/resolve` | no |  |
| `textDocument/foldingRange` | yes | functions, classes, blocks, and the runs of comments and imports |
| `textDocument/selectionRange` | yes | from the name under the cursor out to the document |
| `textDocument/prepareCallHierarchy` | no |  |
| `callHierarchy/incomingCalls` | no | references show the callers, and a function body its calls |
| `callHierarchy/outgoingCalls` | no |  |
| `textDocument/prepareTypeHierarchy` | yes | a class, an interface or an enum starts a hierarchy |
| `typeHierarchy/supertypes` | yes | what the type extends and implements |
| `typeHierarchy/subtypes` | yes | the types that name it in their header |
| `textDocument/semanticTokens/full` | no | Vim's syntax file does the highlighting |
| `textDocument/semanticTokens/full/delta` | no |  |
| `textDocument/semanticTokens/range` | no |  |
| `textDocument/inlayHint` | yes | the type of a `var` that leaves it to the initializer, and the parameter names at a call |
| `inlayHint/resolve` | no | a hint comes complete |
| `textDocument/publishDiagnostics` | yes | after the changes pause |
| `textDocument/diagnostic` | yes | the same as those sent, for the text as it is |
| `textDocument/formatting` | yes | Vim's own indent script, run in the server; for editors other than Vim |
| `textDocument/rangeFormatting` | yes | the lines of the range, taken whole |
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
| `workspace/symbol` | yes | the names of the open documents, of their plugins, and of the autoload and plugin files on 'runtimepath' |
| `workspaceSymbol/resolve` | no |  |
| `workspace/configuration` | no | nothing to configure |
| `workspace/didChangeConfiguration` | no |  |
| `workspace/workspaceFolders` | no | the files a search reads are worked out from the open documents and 'runtimepath' |
| `workspace/didChangeWorkspaceFolders` | yes | one server serves every folder: the files are worked out from the documents |
| `workspace/didChangeWatchedFiles` | yes | the scripts of the workspace that changed are read again |
| `workspace/executeCommand` | yes | `vim9ls.reloadWorkspace`, which has the workspace read again |
| `workspace/applyEdit` | no | the edits of a rename go back as its answer |
| `workspace/diagnostic` | yes | the scripts of the workspace folders that are not open, at most 4096 by default; kept open |
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
| `window/showMessage` | yes | a warning when the log of `$VIM9LS_LOG` cannot be opened |
| `window/showMessageRequest` | no |  |
| `window/logMessage` | yes | where the log of `$VIM9LS_LOG` is |
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
- [x] `workspace/symbol` over the autoload and plugin files on `'runtimepath'`.
- [x] `textDocument/foldingRange`, from what the parser already knows.
- [x] `textDocument/typeDefinition`, `textDocument/implementation` and the
      type hierarchy for Vim9 classes and interfaces.
- [x] `textDocument/formatting` and `rangeFormatting` with Vim's own indent
      script, run in the server; for editors other than Vim.
- [x] Tests on MS-Windows in CI, and the launchers `bin/vim9ls` and
      `bin/vim9ls.cmd` started the way a client starts them.

## Contributing

How a report or a patch is best put, and how the tests are run, is in
[CONTRIBUTING](.github/CONTRIBUTING.md).

## AI

This plugin is developed with the support of AI (Claude).

## License

Vim license, see LICENSE.
