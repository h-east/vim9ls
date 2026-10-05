vim9script

# vim9ls - a language server for Vim script, run by Vim itself
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# A client starts it as
#     vim --clean --stdio-channel -S /path/to/autoload/vim9ls.vim
# and talks LSP to it on stdin and stdout.  Command() is that command line
# for the Vim it is called in, to put in g:lsp_server_list.

import autoload './vim9ls/util.vim'
import autoload './vim9ls/parse.vim'
import autoload './vim9ls/doc.vim'
import autoload './vim9ls/complete.vim'
import autoload './vim9ls/symbol.vim'
import autoload './vim9ls/diag.vim'
import autoload './vim9ls/refs.vim'
import autoload './vim9ls/sig.vim'
import autoload './vim9ls/compile.vim'
import autoload './vim9ls/wrap.vim'
import autoload './vim9ls/names.vim'
import autoload './vim9ls/fix.vim'
import autoload './vim9ls/fold.vim'
import autoload './vim9ls/format.vim'
import autoload './vim9ls/hints.vim'
import autoload './vim9ls/infer.vim'
import autoload './vim9ls/selection.vim'
import autoload './vim9ls/unused.vim'
import autoload './vim9ls/cache.vim'

export const VERSION = '0.1.011'

const SCRIPT = expand('<sfile>:p')

# The Vim the server and the checker need: --stdio-channel came with
# 9.2.1049, 9.2.1055 compiles a function with a lambda after another
# function failed to compile, 9.2.1084 has ":source ++dryrun" and 9.2.1160
# has getinfo().
const PATCH = '9.2.1160'

export def Command(): list<string>
  if !has('channel') || !has('job')
    throw 'vim9ls: this Vim needs +channel and +job to run the server'
  endif
  if !has('patch-' .. PATCH)
    throw $'vim9ls: this Vim needs {PATCH} or later to run the server'
  endif
  var vim = v:progpath
  # gvim.exe would open a window; vim.exe next to it does not.
  if has('win32') && vim =~? 'gvim\.exe$'
    var console = substitute(vim, '\c[^\\/]*$', 'vim.exe', '')
    if executable(console)
      vim = console
    endif
  endif
  return [vim, '--clean', '--stdio-channel', '-S', SCRIPT]
enddef

# How the client counts a position, settled at initialize.
var encoding = 'utf-16'
# The open documents by URI: their lines, version and what parse.vim made
# of them.
var docs: dict<dict<any>> = {}
var conn: channel
# Where the log goes, or why it cannot, told to the client once it listens.
var log_file = ''
var log_failure = ''

def Reply(id: any, result: any)
  ch_sendexpr(conn, {id: id, result: result})
enddef

def ReplyError(id: any, code: number, message: string)
  ch_sendexpr(conn, {id: id, error: {code: code, message: message}})
enddef

def Notify(method: string, params: any)
  ch_sendexpr(conn, {method: method, params: params})
enddef

def Initialize(params: dict<any>): dict<any>
  var offered = params->get('capabilities', {})->get('general', {})
    ->get('positionEncodings', [])
  encoding = index(offered, 'utf-8') >= 0 ? 'utf-8' : 'utf-16'
  watch_files = params->get('capabilities', {})->get('workspace', {})
    ->get('didChangeWatchedFiles', {})->get('dynamicRegistration', false)
  var experimental = params->get('capabilities', {})->get('experimental', {})
  cmdline_completion = type(experimental) == v:t_dict
    && experimental->get('cmdlineCompletion', false) == true
  var options = params->get('initializationOptions', null)
  var workspace = type(options) == v:t_dict ? options->get('workspace', null)
    : null
  var limit = type(workspace) == v:t_dict ? workspace->get('maxFiles', null)
    : null
  if type(limit) == v:t_number && limit > 0
    max_files = limit
  elseif type(limit) != v:t_none
    option_warning = 'vim9ls: workspace.maxFiles is not a positive number, '
      .. $'{MAX_FILES} is used'
  endif
  var given = params->get('workspaceFolders', null)
  if type(given) == v:t_list
    AddFolders(given)
  elseif type(params->get('rootUri', null)) == v:t_string
    AddFolders([{uri: params.rootUri}])
  endif
  return {
    capabilities: {
      positionEncoding: encoding,
      textDocumentSync: {openClose: true, change: 2, save: true},
      hoverProvider: true,
      completionProvider: {triggerCharacters: ['&', ':', '=', ',', ' ', '>'],
        resolveProvider: true},
      documentSymbolProvider: true,
      workspaceSymbolProvider: true,
      foldingRangeProvider: true,
      selectionRangeProvider: true,
      definitionProvider: true,
      typeDefinitionProvider: true,
      implementationProvider: true,
      typeHierarchyProvider: true,
      documentFormattingProvider: true,
      documentRangeFormattingProvider: true,
      referencesProvider: true,
      documentHighlightProvider: true,
      renameProvider: {prepareProvider: true},
      signatureHelpProvider: {triggerCharacters: ['(', ',']},
      codeActionProvider: {codeActionKinds: ['quickfix']},
      inlayHintProvider: true,
      diagnosticProvider: {interFileDependencies: true,
        workspaceDiagnostics: true},
      executeCommandProvider: {commands: [RELOAD]},
      workspace: {workspaceFolders: {supported: true,
        changeNotifications: true}},
    },
    serverInfo: {name: 'vim9ls', version: VERSION},
  }
enddef

def SplitText(text: string): list<string>
  return split(text, '\r\=\n', true)
enddef

# The parse of a document, made when something asks for it.  A change marks
# it stale; a caller that can do with the old names passes "fresh" false.
def Parsed(d: dict<any>, fresh = true): dict<any>
  if d.parsed == null_dict || (fresh && d.stale)
    d.parsed = parse.Parse(d.lines)
    d.stale = false
  endif
  return d.parsed
enddef

# textDocument/diagnostic: what the parser finds in the text as it is, and
# what the checker reported when it has read this text.
def DocumentDiagnostics(params: dict<any>): dict<any>
  var uri = params.textDocument.uri
  var d = docs->get(uri, null_dict)
  if d == null_dict
    return {kind: 'full', items: []}
  endif
  var items = StaticItems(d, util.UriToPath(uri))
  return {kind: 'full', items: d.compiled_now ? WithCompiled(d, items) : items}
enddef

# workspace/diagnostic is kept open.  What is found in the scripts of the
# workspace folders goes to the client as partial results: what the parser
# finds, then that with what the checker reports.  A client that gave no
# token for them is answered once nothing is left to read or check, and asks
# again.  One that gave a token for the work done is told how far the first
# reading of the request has got.

# The workspace folders, as paths.
var folders: list<string> = []
# Whether the client takes a registration for the files to watch.
var watch_files = false
# Whether the client completes the argument of a command itself, as Vim does
# on the command line, when asked to with "cmdlineCompletion".
var cmdline_completion = false
# The request kept open, {id, token, streaming}, or null_dict.
var pull: dict<any> = null_dict
# What is kept for the answer to a request without a token.
var held: list<dict<any>> = []
# The scripts reported, by path, with the time and size they had then.
var reported: dict<string> = {}
# The scripts to read, and the timer that reads them.
var to_read: list<string> = []
var read_timer = -1
# The checks of the scripts that the checker has yet to answer.
var checking = 0
# The first reading of the request, or the reading again that RELOAD asks
# for, {token, total, done, told[, reply]}: a script counts once when read
# and once when checked.  "reply" is the id of the RELOAD request, answered
# at the end.  Or null_dict.
var work: dict<any> = null_dict
# The command that has the workspace read again, as if nothing was known of
# it.
const RELOAD = 'vim9ls.reloadWorkspace'
# The most scripts read, as "workspace.maxFiles" of the initialization
# options sets it; a folder may be a home directory.  What is wrong with the
# options, told to the client once it listens.
const MAX_FILES = 4096
var max_files = MAX_FILES
var option_warning = ''
var told_count = 0

def AddFolders(list: list<any>)
  for f in list
    var path = type(f) == v:t_dict ? util.UriToPath(f->get('uri', '')) : ''
    if path != '' && index(folders, path) < 0
      add(folders, path)
      # A Vim built again keeps its version but may report otherwise.
      cache.Load(path, {vim9ls: VERSION, vim: v:versionlong,
        vim_time: getftime(v:progpath), encoding: encoding})
    endif
  endfor
enddef

# The scripts in the workspace folders that are not open, the first
# "max_files" of them.
def WorkspaceScripts(): list<string>
  var open = docs->keys()->map((_, uri) => util.UriToPath(uri))
  var paths: list<string> = []
  for f in folders
    paths += glob(f .. '/**/*.vim', true, true)
      ->map((_, p) => util.FullPath(p))
  endfor
  paths = paths->sort()->uniq()->filter((_, p) => index(open, p) < 0)
  if len(paths) > max_files
    if told_count != len(paths)
      told_count = len(paths)
      Notify('window/logMessage', {type: 2, message: printf(
        'vim9ls: the workspace has %d scripts, the first %d are read',
        len(paths), max_files)})
    endif
    paths = paths[: max_files - 1]
  endif
  return paths
enddef

# Sends what was found in the script at "path".
def Report(path: string, items: list<dict<any>>)
  var report = {uri: util.PathToUri(path), version: v:null, kind: 'full',
    items: items}
  if pull.streaming
    Notify('$/progress', {token: pull.token, value: {items: [report]}})
  else
    held = held->filter((_, r) => r.uri != report.uri) + [report]
  endif
enddef

def AnswerHeld()
  if pull == null_dict || pull.streaming || held->empty()
      || !to_read->empty() || checking > 0
    return
  endif
  EndWork()
  Reply(pull.id, {items: held})
  held = []
  pull = null_dict
enddef

# Has the scripts read again that changed since they were reported, and
# those in "again"; one that is gone is reported with nothing.
def ScanWorkspace(again: list<string> = [])
  for path in again
    if reported->has_key(path)
      remove(reported, path)
    endif
    cache.Drop(path)
  endfor
  if pull == null_dict
    return
  endif
  var scripts = WorkspaceScripts()
  for path in keys(reported)
    if index(scripts, path) < 0
      remove(reported, path)
      cache.Drop(path)
      Report(path, [])
    endif
  endfor
  for path in scripts
    var stamp = Stamp(path)
    if reported->get(path, '') == stamp || index(to_read, path) >= 0
      continue
    endif
    if reported->has_key(path)
      compile.FilesChanged()
    endif
    var items = cache.Get(path, stamp)
    if type(items) == v:t_list
      reported[path] = stamp
      Report(path, items)
    else
      add(to_read, path)
      if work != null_dict
        work.total += 2
      endif
    endif
  endfor
  if read_timer < 0 && !to_read->empty()
    read_timer = timer_start(0, (_) => ReadScripts())
  endif
  AnswerHeld()
enddef

# Reads scripts for a while, then lets the client be answered before going
# on.
def ReadScripts()
  read_timer = -1
  if pull == null_dict
    return
  endif
  var start = reltime()
  while !to_read->empty() && reltimefloat(reltime(start)) < 0.05
    ReadScript(remove(to_read, 0))
  endwhile
  if !to_read->empty()
    read_timer = timer_start(10, (_) => ReadScripts())
  endif
  AnswerHeld()
enddef

def Stamp(path: string): string
  return getftime(path) .. ':' .. getfsize(path)
enddef

# One step of "w" done; the client hears of every tenth of the whole, and of
# the end.
def Step(w: dict<any>)
  if w == null_dict || work isnot w
    return
  endif
  w.done += 1
  if w.done >= w.total
    EndWork()
    return
  endif
  var percentage = w.total > 0 ? w.done * 100 / w.total : 100
  if percentage / 10 > w.told / 10
    w.told = percentage
    Notify('$/progress', {token: w.token, value: {kind: 'report',
      percentage: percentage}})
  endif
enddef

def ReadScript(path: string)
  var w = work
  if !filereadable(path)
    Step(w)
    Step(w)
    return
  endif
  var stamp = Stamp(path)
  var d = {lines: readfile(path), parsed: null_dict, stale: true,
    compiled: []}
  var items = StaticItems(d, path)
  reported[path] = stamp
  Report(path, items)
  Step(w)
  var parsed = Parsed(d)
  if compile.Check(path, d.lines, parsed.vim9 ? wrap.Lines(parsed, d.lines)
      : null, (errors: any) => Checked(path, stamp, d, items, errors, w),
      true, names.KeyCalls(parsed, d.lines))
    checking += 1
  else
    Step(w)
  endif
enddef

def Checked(path: string, stamp: string, d: dict<any>,
    items: list<dict<any>>, errors: any, w: dict<any>)
  checking -= 1
  if pull == null_dict
    # Not sent; read it again for the next request.
    if reported->has_key(path)
      remove(reported, path)
    endif
    Step(w)
    return
  endif
  if errors != null
    d.compiled = errors
    var all = WithCompiled(d, items)
    Report(path, all)
    cache.Put(path, stamp, all)
  endif
  Step(w)
  if to_read->empty() && checking == 0
    cache.Save()
  endif
  AnswerHeld()
enddef

# The scripts reported that name the one at "path", which may import it.
def Mentioning(path: string): list<string>
  var name = fnamemodify(path, ':t:r')
  return keys(reported)->filter((_, p) => p != path && filereadable(p)
    && readfile(p)->indexof((_, line) => stridx(line, name) >= 0) >= 0)
enddef

def WorkspacePull(id: any, params: dict<any>)
  if pull != null_dict
    EndWork()
    ReplyError(pull.id, -32800, 'a newer request took its place')
  endif
  var token = params->get('partialResultToken', null)
  pull = {id: id, token: token,
    streaming: type(token) == v:t_string || type(token) == v:t_number}
  held = []
  ScanWorkspace()
  var work_token = params->get('workDoneToken', null)
  if (type(work_token) == v:t_string || type(work_token) == v:t_number)
      && pull != null_dict && !to_read->empty()
    work = {token: work_token, total: 2 * len(to_read), done: 0, told: 0}
    Notify('$/progress', {token: work_token, value: {kind: 'begin',
      title: 'Reading the workspace', percentage: 0}})
  endif
enddef

def EndWork()
  if work != null_dict
    Notify('$/progress', {token: work.token, value: {kind: 'end'}})
    if work->has_key('reply')
      Reply(work.reply, v:null)
    endif
    work = null_dict
  endif
enddef

# workspace/executeCommand with RELOAD: what is known of the workspace is
# dropped, and it is read again for the request kept open.
def Reload(id: any, params: dict<any>)
  if params->get('command', '') != RELOAD
    ReplyError(id, -32602, 'Unknown command: '
      .. string(params->get('command', '')))
    return
  endif
  cache.Clear()
  reported = {}
  var token = params->get('workDoneToken', null)
  if pull == null_dict
      || (type(token) != v:t_string && type(token) != v:t_number)
    ScanWorkspace()
    Reply(id, v:null)
    return
  endif
  EndWork()
  ScanWorkspace()
  if to_read->empty()
    Reply(id, v:null)
    return
  endif
  work = {token: token, total: 2 * len(to_read), done: 0, told: 0,
    reply: id}
  Notify('$/progress', {token: token, value: {kind: 'begin',
    title: 'Reading the workspace', percentage: 0}})
enddef

# Ends the request kept open: with what is held, or as cancelled.
def EndPull(cancelled: bool)
  if pull == null_dict
    return
  endif
  EndWork()
  if cancelled
    ReplyError(pull.id, -32800, 'cancelled')
  else
    Reply(pull.id, {items: held})
  endif
  held = []
  pull = null_dict
enddef

# What the parser finds in the document "d" at "path": blocks that do not add
# up, names that are not defined and variables that are not used.  Kept with
# the parse, since the diagnostics are sent and asked for as well.
def StaticItems(d: dict<any>, path: string): list<dict<any>>
  var parsed = Parsed(d)
  if !parsed->has_key('items')
    var undefined = names.Undefined(parsed, d.lines,
      (name: string): number => AutoloadDefined(path, name))
    parsed.items = diag.Diagnostics(parsed.diags + undefined
      + unused.Unused(parsed, d.lines), d.lines, encoding)
  endif
  return parsed.items
enddef

# Whether "a" and "b" name the same error: Vim may add what the command was,
# ":endif without :if: endif", which the parser and Vim's other report leave
# out.
def SameError(a: string, b: string): bool
  return a == b || stridx(a, b .. ': ') == 0 || stridx(b, a .. ': ') == 0
enddef

# "items" and what the checker reported last for the document "d".  The two
# may name the same error, and Vim may report one twice; it is there once, in
# the shorter words.
# Whether "e" is E1054 for a variable of a block at the script level whose
# name a later script variable takes; Vim reads in order and gives none.
def DeclaredLater(parsed: dict<any>, e: dict<any>): bool
  var name = matchstr(e.message,
    '^E1054: Variable already declared in the script: \zs\S\+$')
  if name == ''
    return false
  endif
  var lines = parsed.symbols->copy()->filter((_, s) => s.name == name
      && (s.kind == parse.KIND_VARIABLE || s.kind == parse.KIND_CONSTANT)
      && !s->has_key('scope_start'))
    ->mapnew((_, s) => s.line)
  return !lines->empty() && min(lines) > e.line
enddef

def WithCompiled(d: dict<any>, items: list<dict<any>>): list<dict<any>>
  var all = copy(items)
  var parsed = Parsed(d)
  var errors = d.compiled->copy()->filter((_, e) => !DeclaredLater(parsed, e))
  for item in compile.Diagnostics(errors, d.lines, encoding)
    var at = all->indexof((_, i) => i.range.start.line
      == item.range.start.line && SameError(i.message, item.message))
    if at < 0
      add(all, item)
    elseif strlen(item.message) < strlen(all[at].message)
      all[at] = item
    endif
  endfor
  return all
enddef

# What the parser found, and what Vim reports when the checker reads the
# document.  The checker is asked and answers later; the diagnostics go out
# when it has.
def PublishDiagnostics(uri: string)
  var d = docs->get(uri, null_dict)
  if d == null_dict
    return
  endif
  d.timer = -1
  var path = util.UriToPath(uri)
  var items = StaticItems(d, path)
  var parsed = Parsed(d)
  var version = d.version
  if path == '' || !compile.Check(path, d.lines,
      parsed.vim9 ? wrap.Lines(parsed, d.lines) : null,
      (errors: any) => Publish(uri, version, items, errors), false,
      names.KeyCalls(parsed, d.lines))
    Publish(uri, version, items, null)
  endif
enddef

# Sends "items" and what the checker reported, "errors", for the document at
# "uri" while it is still at "version".  When the checker gave no answer,
# what it reported last time stays.
def Publish(uri: string, version: any, items: list<dict<any>>, errors: any)
  var d = docs->get(uri, null_dict)
  if d == null_dict || d.version != version
    return
  endif
  if errors != null
    d.compiled = errors
    d.compiled_now = true
  endif
  Notify('textDocument/publishDiagnostics', {
    uri: uri,
    version: d.version,
    diagnostics: WithCompiled(d, items),
  })
enddef

# Typing brings a change with every keystroke; the diagnostics wait until
# the changes pause.
def ScheduleDiagnostics(uri: string)
  var d = docs[uri]
  if d.timer >= 0
    timer_stop(d.timer)
  endif
  d.timer = timer_start(200, (_) => PublishDiagnostics(uri))
enddef

def SetDoc(uri: string, text: string, version: any)
  docs[uri] = {lines: SplitText(text), version: version, parsed: null_dict,
    stale: true, timer: -1, compiled: [], compiled_now: false}
  ScheduleDiagnostics(uri)
enddef

# Applies one change of textDocument/didChange: the whole text when it has
# no range, the text in place of the range otherwise.
def ApplyChange(d: dict<any>, change: dict<any>)
  var inserted = SplitText(change.text)
  if !change->has_key('range')
    d.lines = inserted
    return
  endif
  var first = change.range.start.line
  var last = change.range.end.line
  var first_line = d.lines->get(first, '')
  var last_line = d.lines->get(last, '')
  var col = util.ColFromLsp(first_line, change.range.start.character,
    encoding)
  var end_col = util.ColFromLsp(last_line, change.range.end.character,
    encoding)
  inserted[0] = strpart(first_line, 0, col) .. inserted[0]
  inserted[-1] = inserted[-1] .. strpart(last_line, end_col)
  d.lines = slice(d.lines, 0, first) + inserted + slice(d.lines, last + 1)
enddef

def ChangeDoc(uri: string, changes: list<dict<any>>, version: any)
  var d = docs->get(uri, null_dict)
  if d == null_dict
    return
  endif
  for change in changes
    ApplyChange(d, change)
  endfor
  d.version = version
  d.stale = true
  d.compiled_now = false
  ScheduleDiagnostics(uri)
enddef

# The document and the line and byte column "params" point at, with its
# parse, a stale one when "fresh" is false.
def Where(params: dict<any>, fresh = true): dict<any>
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return null_dict
  endif
  var lnum = params.position.line
  var line = d.lines->get(lnum, '')
  var uri = params.textDocument.uri
  return {doc: d, parsed: Parsed(d, fresh), lnum: lnum, line: line,
    col: util.ColFromLsp(line, params.position.character, encoding),
    uri: uri, path: util.UriToPath(uri)}
enddef

# The identifier at byte "col" in "line", or the one just before it when the
# cursor is right after it.
def WordAt(line: string, col: number): dict<any>
  const WORD = '[[:alnum:]_:#]'
  var at = col
  if strpart(line, at, 1) !~ WORD && at > 0
      && strpart(line, at - 1, 1) =~ WORD
    at -= 1
  endif
  var begin = at
  while begin > 0 && strpart(line, begin - 1, 1) =~ WORD
    begin -= 1
  endwhile
  var stop = at
  while stop < strlen(line) && strpart(line, stop, 1) =~ WORD
    stop += 1
  endwhile
  return {word: strpart(line, begin, stop - begin), start: begin, end: stop}
enddef

# "before", the text in front of a word, without the colons and modifiers
# that may start a statement.  Empty when the word is the command itself.
def StatementText(before: string): string
  var rest = substitute(before, '^\s*\%(:\s*\)*', '', '')
  while rest != ''
    var m = matchlist(rest, '^\(\h\w*\)!\=\s\+\(.*\)$')
    if m->empty() || !parse.IsModifier(m[1])
      break
    endif
    rest = m[2]
  endwhile
  return rest
enddef

# The help tag for the word at "found" in "line", going by what is around it.
def TagAt(line: string, found: dict<any>): string
  var word = found.word
  var before = strpart(line, 0, found.start)
  var after = strpart(line, found.end)
  var statement = StatementText(before)
  if before =~ '&$' && word =~ '^[lg]:'
    word = word[2 :]
  endif
  if before =~ '&\%([lg]:\)\=$'
      || statement =~ '^\%(se\%[tlocal]\|setg\%[lobal]\)\s\+\%(\S\+\s\+\)*$'
    return doc.TagFor(word, 'option')
  endif
  if word =~ '^v:'
    return doc.TagFor(word, 'variable')
  endif
  # A name with a scope is a variable, and so is whatever is assigned to.
  if word =~ '^[sgbwtl]:' || after =~ '^\s*\%(\.\.\|[-+*/%.]\)\==[^=]'
      || after =~ '^\s*=[^=]'
    return ''
  endif
  if statement == ''
    var tag = doc.TagFor(word, 'command')
    if tag != ''
      return tag
    endif
  endif
  # Anything else is taken for a function; a variable of the script that
  # happens to be spelled like a command or an option gets no help.
  return doc.TagFor(word, 'function')
enddef

def Hover(params: dict<any>): any
  var w = Where(params)
  if w == null_dict
    return v:null
  endif
  var found = WordAt(w.line, w.col)
  if found.word == ''
    return v:null
  endif
  var tag = TagAt(w.line, found)
  var text = tag == '' ? '' : doc.HelpText(tag)
  if text == ''
    return v:null
  endif
  return {
    contents: {kind: 'plaintext', value: text},
    range: util.Range(w.doc.lines, w.lnum, found.start, w.lnum, found.end,
      encoding),
  }
enddef

def Completion(params: dict<any>): any
  # The names of the script do not change with every keystroke; a stale
  # parse is good enough for the candidates.
  var w = Where(params, false)
  if w == null_dict
    return v:null
  endif
  var ctx = complete.Context(w.line, w.col)
  var items: list<dict<any>>
  if ctx.owner != ''
    items = complete.ItemsOf(Members(w, ctx.owner), ctx.prefix)
  elseif ctx.prefix =~ '#'
    items = AutoloadItems(w, ctx.prefix)
  elseif !ctx.option && complete.InCommandArg(w.line, w.col)
    return cmdline_completion
      ? {isIncomplete: false, items: [], cmdlineCompletion: true}
      : {isIncomplete: false, items: []}
  elseif ctx.method
    items = complete.MethodItems(ctx.prefix, w.parsed.symbols)
  elseif !ctx.option && index(['=', ',', ' ', '>'],
      params->get('context', {})->get('triggerCharacter', '')) >= 0
    # Those are there for the argument of a command and for "->"; elsewhere
    # in an expression the menu would hold every name there is.
    return {isIncomplete: false, items: []}
  else
    items = complete.Items(w.line, w.col, w.parsed.symbols)
  endif
  return {isIncomplete: false, items: items}
enddef

# The completion item with the help entry of the builtin it stands for: the
# first line as the detail, the rest as the documentation.  An item of the
# script has no entry and comes back as it is.
def ResolveItem(item: dict<any>): dict<any>
  var data = item->get('data', {})
  var text = type(data) == v:t_dict ? doc.HelpText(data->get('tag', '')) : ''
  if text == ''
    return item
  endif
  var nl = stridx(text, "\n")
  if !item->has_key('detail')
    item.detail = nl < 0 ? text : text[: nl - 1]
  endif
  if nl >= 0
    item.documentation = {kind: 'plaintext', value: text[nl + 1 :]->trim()}
  endif
  return item
enddef

# The symbols of "script" that other scripts can use: the exported ones.
def Exported(script: dict<any>): list<dict<any>>
  return copy(script.parsed.symbols)->filter((_, s) =>
    script.lines[s.line] =~ '^\s*export\s')
enddef

# What can follow "owner." at line "w.lnum": the exported names of an
# imported script, the members of a class or an enum named, of the class
# of a variable, or of the class "this" is in.
def Members(w: dict<any>, owner: string): list<dict<any>>
  var parsed = w.parsed
  if owner == 'this'
    for s in parsed.symbols
      if s.kind == parse.KIND_CLASS && s.line <= w.lnum
          && w.lnum <= s.end_line
        return s.children
      endif
    endfor
    return []
  endif
  var token = {text: owner, col: 0, end: strlen(owner), prev: ' ',
    in_string: false}
  var found = refs.Resolve(parsed, token, w.lnum)
  if found == null_dict
    return []
  endif
  if found.kind == parse.KIND_MODULE
    var file = refs.ImportFile(w.path, found.detail,
      found->get('autoload', false))
    var script = file == '' ? null_dict : ScriptAt(file)
    return script == null_dict ? [] : Exported(script)
  endif
  if found.kind == parse.KIND_CLASS || found.kind == parse.KIND_ENUM
      || found.kind == parse.KIND_INTERFACE
    return found.children
  endif
  # A variable: the class it is declared with, or made with "Class.new()".
  var type = found.detail =~ '^\h\w*$' ? found.detail
    : matchstr(w.doc.lines[found.line], '=\s*\zs\h\w*\ze\.new\w*(')
  var cls = type == '' ? null_dict : TopLevel(parsed, type)
  return cls == null_dict ? [] : cls.children
enddef

# What the autoload name "prefix", "foo#bar#Fu" for one, can complete to: the
# functions of autoload/foo/bar.vim and the files below it as "foo#bar#name#".
# Each item replaces the whole prefix, "#" is no keyword character.
def AutoloadItems(w: dict<any>, prefix: string): list<dict<any>>
  var head = matchstr(prefix, '.*#')
  var dir = substitute(head, '#', '/', 'g')
  var symbols: list<dict<any>> = []
  var file = refs.AutoloadFile(w.path, dir[: -2] .. '.vim')
  var script = file == '' ? null_dict : ScriptAt(file)
  if script != null_dict
    for s in script.parsed.symbols
      if s.name =~ '#'
        add(symbols, s)
      elseif script.lines[s.line] =~ '^\s*export\s'
        add(symbols, extend(copy(s), {name: head .. s.name}))
      endif
    endfor
  endif
  for d in refs.AutoloadDirs(w.path)
    for f in glob(d .. '/' .. dir .. '*.vim', true, true)
      add(symbols, {name: head .. fnamemodify(f, ':t:r') .. '#',
        kind: parse.KIND_MODULE, detail: ''})
    endfor
  endfor
  var range = util.Range(w.doc.lines, w.lnum, w.col - strlen(prefix), w.lnum,
    w.col, encoding)
  return complete.ItemsOf(symbols, prefix)->map((_, item) =>
    extend(item, {textEdit: {range: range, newText: item.label}}))
enddef

# The whole document, indented the way Vim itself would.
def Formatting(params: dict<any>): any
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return v:null
  endif
  return format.Edits(d.lines, 0, len(d.lines) - 1,
    params->get('options', {}), encoding)
enddef

# The lines of the range, indented; a line is taken whole, the columns of
# the range are of no use for an indent.
def RangeFormatting(params: dict<any>): any
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return v:null
  endif
  var first = params->get('range', {})->get('start', {})->get('line', 0)
  var last = params->get('range', {})->get('end', {})->get('line', first)
  var end = len(d.lines) - 1
  return format.Edits(d.lines, min([first, end]), min([last, end]),
    params->get('options', {}), encoding)
enddef

def FoldingRanges(params: dict<any>): any
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return v:null
  endif
  return fold.Ranges(Parsed(d), d.lines)
enddef

def SelectionRanges(params: dict<any>): any
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return v:null
  endif
  return selection.Ranges(Parsed(d), d.lines, params->get('positions', []),
    encoding)
enddef

def DocumentSymbols(params: dict<any>): any
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return v:null
  endif
  return symbol.DocumentSymbols(Parsed(d).symbols, d.lines, encoding)
enddef

# Other scripts, read and parsed when a name leads there; kept until the
# file changes.
var files: dict<dict<any>> = {}

# The lines and parse of the script at "path": the open document when there
# is one, the file otherwise.  null_dict when it cannot be read.
def ScriptAt(path: string): dict<any>
  var uri = util.PathToUri(path)
  if docs->has_key(uri)
    return {uri: uri, lines: docs[uri].lines, parsed: Parsed(docs[uri])}
  endif
  var mtime = getftime(path)
  if mtime < 0
    return null_dict
  endif
  if !files->has_key(path) || files[path].mtime != mtime
    var lines = readfile(path)
    files[path] = {uri: uri, lines: lines, parsed: parse.Parse(lines),
      mtime: mtime}
  endif
  return files[path]
enddef

def Location(uri: string, lines: list<string>, s: dict<any>): dict<any>
  return {uri: uri, range: util.Range(lines, s.line, s.name_col, s.line,
    s.name_end, encoding)}
enddef

# The "Autoload" of names.Undefined(): whether the legacy autoload function
# "name", used in the script at "path", is defined in its file.
def AutoloadDefined(path: string, name: string): number
  var rel = substitute(name, '#[^#]*$', '', '')->substitute('#', '/', 'g')
    .. '.vim'
  var file = path == '' ? '' : refs.AutoloadFile(path, rel)
  var script = file == '' ? null_dict : ScriptAt(file)
  if script == null_dict
    return -1
  endif
  return TopLevel(script.parsed, name) != null_dict
    || TopLevel(script.parsed, matchstr(name, '[^#]*$')) != null_dict ? 1 : 0
enddef

# The top-level symbol "name" of a script; a legacy autoload function is
# defined under its full name.
def TopLevel(parsed: dict<any>, name: string): dict<any>
  for s in parsed.symbols
    if s.name == name || s.name =~ '#' .. name .. '$'
      return s
    endif
  endfor
  return null_dict
enddef

# The token under the cursor with the document it is in, or null_dict.
def TokenWhere(params: dict<any>): dict<any>
  var w = Where(params)
  if w == null_dict
    return null_dict
  endif
  var vim9 = parse.InVim9At(w.parsed, w.lnum)
  var token = refs.TokenAt(w.line, w.col, vim9)
  if token == null_dict
    return null_dict
  endif
  w.token = token
  return w
enddef

# What defines the token at "w": the symbol and the script it is in, as
# {path, uri, lines, parsed, symbol}.  null_dict when nothing does.
def Lookup(w: dict<any>, token: dict<any>): dict<any>
  var parsed = w.parsed

  # The name on the line that declares it: that one, whether a type follows
  # it, "count: number", or it is a member, which a use has after a ".".
  var declared = SymbolAt(parsed.symbols, w.lnum, token.col)
  if declared != null_dict
    return {path: w.path, uri: w.uri, lines: w.doc.lines, parsed: parsed,
      symbol: declared}
  endif

  # "alias.Name": a name from an imported script.
  if token.prev == '.' && token.col >= 2
    var alias = matchstr(strpart(w.line, 0, token.col - 1),
      refs.NAME .. '\+$')
    var imported = TopLevel(parsed, alias)
    if imported != null_dict && imported.kind == parse.KIND_MODULE
      var file = refs.ImportFile(w.path, imported.detail,
        imported->get('autoload', false))
      var script = file == '' ? null_dict : ScriptAt(file)
      var target = script == null_dict ? null_dict
        : TopLevel(script.parsed, token.text)
      return target == null_dict ? null_dict
        : extend({path: file, symbol: target}, script)
    endif
  endif

  var found = refs.Resolve(parsed, token, w.lnum)
  if found != null_dict
    return {path: w.path, uri: w.uri, lines: w.doc.lines, parsed: parsed,
      symbol: found}
  endif

  # "foo#bar#Func": a legacy autoload function in autoload/foo/bar.vim.
  if token.text =~ '\h\w*#' && token.prev != '.'
    var rel = substitute(token.text, '#[^#]*$', '', '')
      ->substitute('#', '/', 'g') .. '.vim'
    var file = refs.AutoloadFile(w.path, rel)
    var script = file == '' ? null_dict : ScriptAt(file)
    var target = script == null_dict ? null_dict
      : TopLevel(script.parsed, token.text)
    if target == null_dict && script != null_dict
      target = TopLevel(script.parsed, matchstr(token.text, '[^#]*$'))
    endif
    if target != null_dict
      return extend({path: file, symbol: target}, script)
    endif
  endif
  return null_dict
enddef

# What other scripts can use of the symbol "hit" defines: {path, symbol,
# autoload} for an exported name or an autoload function, "autoload" being
# the name a legacy call spells out; null_dict for anything else.
def Shared(hit: dict<any>): dict<any>
  var s = hit.symbol
  if s.kind == parse.KIND_MODULE
    return null_dict
  endif
  if s.name =~ '#'
    return {path: hit.path, symbol: s, autoload: s.name}
  endif
  if hit.lines[s.line] !~ '^\s*export\s'
    return null_dict
  endif
  var under = matchstr(hit.path, '.*[/\\]autoload[/\\]\zs.*\ze\.vim$')
  return {path: hit.path, symbol: s, autoload: under == '' ? ''
    : substitute(under, '[/\\]', '#', 'g') .. '#' .. s.name}
enddef

# The scripts that may use what the script at "path" defines: the others of
# the plugin it belongs to, the directory above its autoload, plugin,
# ftplugin, import, syntax or indent directory, and the open documents.
def UsersOf(path: string): list<string>
  var root = matchstr(path,
    '.*\ze[/\\]\%(autoload\|plugin\|ftplugin\|import\|syntax\|indent\)[/\\]')
  var paths = root == '' ? [] : glob(root .. '/**/*.vim', true, true)
    ->map((_, f) => util.FullPath(f))
  for uri in keys(docs)
    add(paths, util.UriToPath(uri))
  endfor
  return sort(paths)->uniq()->filter((_, p) => p != path)
enddef

# How many symbols a workspace search answers with.
const WORKSPACE_LIMIT = 256

# The scripts a workspace search reads: the open documents, the plugin each
# one belongs to, and the autoload and plugin files on 'runtimepath'.
def WorkspaceFiles(): list<string>
  var paths: list<string> = []
  for uri in keys(docs)
    var path = util.UriToPath(uri)
    add(paths, path)
    paths->extend(UsersOf(path))
  endfor
  for dir in split(&runtimepath, ',')
    for under in ['autoload', 'plugin']
      paths->extend(glob(dir .. '/' .. under .. '/**/*.vim', true, true)
        ->map((_, f) => util.FullPath(f)))
    endfor
  endfor
  return sort(paths)->uniq()
enddef

# The symbols whose name holds the query.  An empty query is answered with
# the open documents alone: every script on 'runtimepath' would be read.
def WorkspaceSymbols(params: dict<any>): list<dict<any>>
  var query = params->get('query', '')
  var out: list<dict<any>> = []
  if query == ''
    for [uri, d] in items(docs)
      out->extend(symbol.WorkspaceSymbols(Parsed(d).symbols, d.lines, uri,
        '', encoding))
    endfor
    return out[: WORKSPACE_LIMIT - 1]
  endif
  # A script the query does not occur in defines no name holding it, and
  # reading a script is cheaper than parsing it.
  var pat = '\c\V' .. escape(query, '\')
  for path in WorkspaceFiles()
    if len(out) >= WORKSPACE_LIMIT
      break
    endif
    var uri = util.PathToUri(path)
    var lines = docs->has_key(uri) ? docs[uri].lines
      : filereadable(path) ? readfile(path) : []
    if match(lines, pat) < 0
      continue
    endif
    var script = ScriptAt(path)
    if script == null_dict
      continue
    endif
    out->extend(symbol.WorkspaceSymbols(script.parsed.symbols, script.lines,
      script.uri, query, encoding))
  endfor
  return out[: WORKSPACE_LIMIT - 1]
enddef

# The script at "path" when "name" occurs in its text, null_dict otherwise;
# a script without it needs no parsing.
def Mentions(path: string, name: string): dict<any>
  var uri = util.PathToUri(path)
  var lines = docs->has_key(uri) ? docs[uri].lines
    : filereadable(path) ? readfile(path) : []
  return match(lines, '\V' .. name) < 0 ? null_dict : ScriptAt(path)
enddef

# Where "shared" is used: in its own script, and in the scripts that may use
# it.  Each use as {uri, lines, line, col, end}, the span of the name after
# the last "#".
def SharedUses(hit: dict<any>, shared: dict<any>,
    declaration: bool): list<dict<any>>
  var out: list<dict<any>> = []
  for r in refs.References(hit.parsed, hit.lines, hit.symbol, declaration)
    var text = hit.lines[r.line][r.col : r.end - 1]
    out->add({uri: hit.uri, lines: hit.lines, line: r.line,
      col: r.col + strridx(text, '#') + 1, end: r.end})
  endfor
  if shared == null_dict
    return out
  endif
  var name = matchstr(shared.symbol.name, '[^#]*$')
  for path in UsersOf(shared.path)
    var script = Mentions(path, name)
    if script == null_dict
      continue
    endif
    for r in refs.UsesOf(script.parsed, script.lines, path, shared)
      out->add({uri: script.uri, lines: script.lines, line: r.line, col: r.col,
        end: r.end})
    endfor
  endfor
  return out
enddef

def Definition(params: dict<any>): any
  var w = TokenWhere(params)
  if w == null_dict
    return v:null
  endif
  var hit = Lookup(w, w.token)
  if hit == null_dict
    return v:null
  endif
  if hit.symbol.kind == parse.KIND_MODULE
    # The import itself: go to the file.
    var file = refs.ImportFile(w.path, hit.symbol.detail,
      hit.symbol->get('autoload', false))
    if file != ''
      return [{uri: util.PathToUri(file),
        range: util.Range([''], 0, 0, 0, 0, encoding)}]
    endif
  endif
  return [Location(hit.uri, hit.lines, hit.symbol)]
enddef

# The kinds of symbol that are a type of their own.
const TYPE_KINDS = [parse.KIND_CLASS, parse.KIND_INTERFACE, parse.KIND_ENUM]

# The name of the type "type" that a script may define, with the alias of
# the import it comes from: "Shape" of "list<Shape>", "lib" and "Shape" of
# "dict<lib.Shape>".  A type of Vim's own starts with a lower case letter.
def TypeName(type: string): list<string>
  var m = matchlist(type, '\%(\(\h\w*\)\.\)\=\(\u\w*\)')
  return m->empty() ? ['', ''] : [m[1], m[2]]
enddef

# Where the type of the name at the cursor is defined.  A class, an
# interface and an enum are a type themselves and lead to their own line.
# The type "name" of the script "from", through the alias of an import when
# there is one, as {uri, lines, parsed, path, symbol}; null_dict when it is
# not found or is not a type.
def ResolveType(from: dict<any>, alias: string, name: string): dict<any>
  var script = from
  if alias != ''
    var imported = TopLevel(from.parsed, alias)
    if imported == null_dict || imported.kind != parse.KIND_MODULE
      return null_dict
    endif
    var file = refs.ImportFile(from.path, imported.detail,
      imported->get('autoload', false))
    script = file == '' ? null_dict : ScriptAt(file)
    if script == null_dict
      return null_dict
    endif
  endif
  var target = TopLevel(script.parsed, name)
  if target == null_dict || index(TYPE_KINDS, target.kind) < 0
    return null_dict
  endif
  return extend({symbol: target}, script, 'keep')
enddef

def TypeDefinition(params: dict<any>): any
  var w = TokenWhere(params)
  if w == null_dict
    return v:null
  endif
  var hit = Lookup(w, w.token)
  if hit == null_dict
    return v:null
  endif
  if index(TYPE_KINDS, hit.symbol.kind) >= 0
    return [Location(hit.uri, hit.lines, hit.symbol)]
  endif
  var [alias, name] = TypeName(
    hints.VariableType(hit.parsed, hit.lines, hit.symbol))
  if name == ''
    return v:null
  endif
  var found = ResolveType(hit, alias, name)
  return found == null_dict ? v:null
    : [Location(found.uri, found.lines, found.symbol)]
enddef

# The symbol whose name is at "lnum" and byte "col", the one the line
# declares rather than one it uses; null_dict when the cursor is elsewhere.
def SymbolAt(symbols: list<dict<any>>, lnum: number, col: number): dict<any>
  for s in parse.AllSymbols(symbols)
    if s.line == lnum && s.name_col <= col && col < s.name_end
      return s
    endif
  endfor
  return null_dict
enddef

# The class, interface or enum the symbol "want" is a member of; null_dict
# when it is not a member of one.
def Enclosing(symbols: list<dict<any>>, want: dict<any>): dict<any>
  for s in symbols
    if index(TYPE_KINDS, s.kind) >= 0
      for c in s.children
        if c is want
          return s
        endif
      endfor
    endif
    var found = Enclosing(s.children, want)
    if found != null_dict
      return found
    endif
  endfor
  return null_dict
enddef

# Where the name at the cursor is implemented: the classes that implement an
# interface or extend a class, and their method of the same name when the
# cursor is on a method.  Only what names the type itself counts.
# Whether the type "s" names "parent" in its header: a class or an enum that
# implements an interface, an interface that extends one, a class that
# extends a class.
def NamesType(s: dict<any>, parent: dict<any>): bool
  # The name may come through the alias of an import: "extends lib.Shape".
  var extends = '\<extends\s\+\%(\h\w*\.\)\=' .. parent.name .. '\>'
  if parent.kind == parse.KIND_INTERFACE
    return s.kind == parse.KIND_INTERFACE ? s.detail =~ extends
      : s.detail =~ '\<implements\>.*\<' .. parent.name .. '\>'
  endif
  return parent.kind == parse.KIND_CLASS && s.kind == parse.KIND_CLASS
    && s.detail =~ extends
enddef

# The types that name "parent" in their header, each as the script it is in
# with its symbol.  Only what names it itself counts, so a class extending
# one of the classes found is not among them.
def Subtypes(parent: dict<any>): list<dict<any>>
  var out: list<dict<any>> = []
  var pat = '\<\%(extends\|implements\)\>.*\<' .. parent.name .. '\>'
  for path in WorkspaceFiles()
    if len(out) >= WORKSPACE_LIMIT
      break
    endif
    var uri = util.PathToUri(path)
    var lines = docs->has_key(uri) ? docs[uri].lines
      : filereadable(path) ? readfile(path) : []
    if match(lines, pat) < 0
      continue
    endif
    var script = ScriptAt(path)
    if script == null_dict
      continue
    endif
    for s in script.parsed.symbols
      if index(TYPE_KINDS, s.kind) >= 0 && NamesType(s, parent)
        out->add(extend({symbol: s}, script, 'keep'))
      endif
    endfor
  endfor
  return out
enddef

# Where the name at the cursor is implemented: the types that name it in
# their header, and their method of the same name when the cursor is on a
# method.
def Implementation(params: dict<any>): any
  var w = TokenWhere(params)
  if w == null_dict
    return v:null
  endif
  # Asked from the line that declares the name, an interface method for one,
  # or from a use of it.
  var hit = Lookup(w, w.token)
  if hit == null_dict
    return v:null
  endif
  var type = hit.symbol
  var method = ''
  if type.kind == parse.KIND_METHOD
    method = type.name
    type = Enclosing(hit.parsed.symbols, type)
    if type == null_dict
      return v:null
    endif
  endif
  if index(TYPE_KINDS, type.kind) < 0
    return v:null
  endif
  var out: list<dict<any>> = []
  for sub in Subtypes(type)
    var target = sub.symbol
    if method != ''
      var members = target.children->copy()->filter((_, c) => c.name == method)
      if members->empty()
        continue
      endif
      target = members[0]
    endif
    out->add(Location(sub.uri, sub.lines, target))
  endfor
  return out->empty() ? v:null : out
enddef

# A type the way the protocol passes it around: the range is the type with
# its body, the selection range its name.
def TypeItem(script: dict<any>, s: dict<any>): dict<any>
  return {
    name: s.name,
    kind: s.kind,
    uri: script.uri,
    range: util.Range(script.lines, s.line, s.col, s.end_line,
      strlen(script.lines->get(s.end_line, '')), encoding),
    selectionRange: util.Range(script.lines, s.line, s.name_col, s.line,
      s.name_end, encoding),
  }
enddef

# The type an item of the protocol stands for, as the script it is in with
# its symbol; null_dict when the file or the name is gone.
def TypeFromItem(item: any): dict<any>
  if type(item) != v:t_dict || !item->has_key('uri')
    return null_dict
  endif
  var script = ScriptAt(util.UriToPath(item.uri))
  if script == null_dict
    return null_dict
  endif
  var start = item->get('selectionRange', {})->get('start', {})
  var lnum = start->get('line', 0)
  var col = util.ColFromLsp(script.lines->get(lnum, ''),
    start->get('character', 0), encoding)
  var s = SymbolAt(script.parsed.symbols, lnum, col)
  # The path is what an import of that script is looked for from.
  return s == null_dict || index(TYPE_KINDS, s.kind) < 0 ? null_dict
    : extend({symbol: s, path: util.UriToPath(item.uri)}, script, 'keep')
enddef

# The type hierarchy starts at a class, an interface or an enum; it is asked
# for from the line that declares one.
def PrepareTypeHierarchy(params: dict<any>): any
  var w = TokenWhere(params)
  if w == null_dict
    return v:null
  endif
  var hit = Lookup(w, w.token)
  if hit == null_dict || index(TYPE_KINDS, hit.symbol.kind) < 0
    return v:null
  endif
  return [TypeItem(hit, hit.symbol)]
enddef

# What the type of the item extends and implements, in the order its header
# names them.  A name that leads nowhere is left out.
def Supertypes(params: dict<any>): any
  var hit = TypeFromItem(params->get('item', null))
  if hit == null_dict
    return v:null
  endif
  var out: list<dict<any>> = []
  for name in split(hit.symbol.detail, '\%(\<\%(extends\|implements\)\>\|,\)')
    var [alias, plain] = TypeName(name)
    if plain == ''
      continue
    endif
    var above = ResolveType(hit, alias, plain)
    if above != null_dict
      out->add(TypeItem(above, above.symbol))
    endif
  endfor
  return out->empty() ? v:null : out
enddef

# The subtypes of the item, as items of their own.
def SubtypeItems(params: dict<any>): any
  var hit = TypeFromItem(params->get('item', null))
  if hit == null_dict
    return v:null
  endif
  var out = Subtypes(hit.symbol)->mapnew((_, sub) => TypeItem(sub, sub.symbol))
  return out->empty() ? v:null : out
enddef

# The signature of the function a script defines: its name and what follows
# it on the "def" or "function" line, up to the ")" for a legacy function.
def ScriptSignature(s: dict<any>): string
  var detail = s.detail
  if s->get('legacy', false)
    detail = matchstr(detail, '^([^)]*)')
  endif
  return s.name .. detail
enddef

# "help" with the parameters of its signature counted in the encoding the
# client took, which sig.Help() counts in bytes.
def InEncoding(help: dict<any>): dict<any>
  var label = help.signatures[0].label
  for p in help.signatures[0].parameters
    p.label = p.label->mapnew((_, col) => util.ColToLsp(label, col, encoding))
  endfor
  return help
enddef

def SignatureHelp(params: dict<any>): any
  var w = Where(params)
  if w == null_dict
    return v:null
  endif
  var lines = w.doc.lines
  var hit = sig.CallAt(lines, w.lnum, w.col,
    parse.Vim9Lines(w.parsed, len(lines)))
  if hit == null_dict
    return v:null
  endif
  var active = hit.active + (hit.method ? 1 : 0)
  # The name may be on an earlier line than the cursor.
  w.lnum = hit.line
  w.line = lines[hit.line]

  if hit.prev != '.' && doc.HasTag(hit.name .. '()')
    var text = doc.HelpText(hit.name .. '()')
    var nl = stridx(text, "\n")
    var label = nl < 0 ? text : text[: nl - 1]
    var documentation = nl < 0 ? '' : text[nl + 1 :]
    # With getinfo() the label gets the types, and the argument the value
    # before "->" fills is known: it is not always the first.
    var info = getinfo('function', hit.name)
    if info->empty()
      return InEncoding(sig.Help(label, active, documentation))
    endif
    if hit.method
      active = hit.active + (hit.active >= info.method - 1 ? 1 : 0)
    endif
    var typed = sig.Typed(label, info)
    return InEncoding(sig.Help(typed.label, active, documentation,
      typed.parameters))
  endif

  var token = {text: hit.name, col: hit.col, end: hit.col
    + strlen(hit.name), prev: hit.prev, in_string: false}
  var found = Lookup(w, token)
  if found == null_dict || (found.symbol.kind != parse.KIND_FUNCTION
      && found.symbol.kind != parse.KIND_METHOD)
    return v:null
  endif
  return InEncoding(sig.Help(ScriptSignature(found.symbol), active))
enddef

def CodeActions(params: dict<any>): any
  var uri = params.textDocument.uri
  var d = docs->get(uri, null_dict)
  if d == null_dict
    return v:null
  endif
  return fix.Actions(Parsed(d), d.lines, uri,
    params->get('context', {})->get('diagnostics', []), encoding)
enddef

def InlayHints(params: dict<any>): any
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return v:null
  endif
  var range = params->get('range', {})
  var first = range->get('start', {})->get('line', 0)
  var last = range->get('end', {})->get('line', len(d.lines))
  var parsed = Parsed(d)
  return (hints.TypeHints(parsed, d.lines, first, last)
    + hints.ParamHints(parsed, d.lines, first, last,
      (name: string) => ParamNames(parsed, name)))
    ->mapnew((_, h) => ({
      position: util.Position(d.lines, h.line, h.col, encoding),
      label: h.label,
      kind: h.kind,
      paddingRight: h.kind == hints.KIND_PARAMETER,
    }))
enddef

# The parameter names of function "name" for the hints: a builtin's as
# signature help knows them, a function of the script's from its definition.
# An empty Dict for a name that is neither.  A builtin's argument that has no
# name or is named after its type, "{string}" of strlen(), gets ''.
def ParamNames(parsed: dict<any>, name: string): dict<any>
  if doc.HasTag(name .. '()')
    var text = doc.HelpText(name .. '()')
    var nl = stridx(text, "\n")
    var info = getinfo('function', name)
    var args: list<dict<any>> = info->get('args', [])
    var params = sig.Names(nl < 0 ? text : text[: nl - 1], info)
      ->map((i, n) => n =~ '^{arg\d\+}$'
        || sig.TypeNamed(n, args->get(i, {types: []}).types)
        ? '' : matchstr(n, '^{\zs.*\ze}$'))
    return {names: params, method: max([1, info->get('method', 1)])}
  endif
  for s in parse.AllSymbols(parsed.symbols)
    if (s.kind == parse.KIND_FUNCTION || s.kind == parse.KIND_METHOD)
        && s.name == name
      return {names: s.children->copy()
        ->filter((_, c) => c->get('param', false))
        ->mapnew((_, c) => substitute(c.name, '^a:', '', '')), method: 1}
    endif
  endfor
  return {}
enddef

def References(params: dict<any>): any
  var w = TokenWhere(params)
  if w == null_dict
    return v:null
  endif
  var hit = Lookup(w, w.token)
  if hit == null_dict
    return v:null
  endif
  var include = params->get('context', {})->get('includeDeclaration', true)
  return SharedUses(hit, Shared(hit), include)
    ->mapnew((_, u) => ({uri: u.uri, range: util.Range(u.lines, u.line, u.col,
      u.line, u.end, encoding)}))
enddef

# Whether the name at "col" in "line" is being written to: 3 for a write, 2
# for a read, the numbers |DocumentHighlightKind| uses.
def UseKind(line: string, col: number, endcol: number): number
  var before = strpart(line, 0, col)
  var after = strpart(line, endcol)
  # A declaration, also the names in "var [a, b]" and "for [a, b]".
  if before =~ '\<\%(var\|final\|const\|let\|for\)\s\+\%(\[[^]]*\)\=$'
    return 3
  endif
  # An assignment: "x = 1", "x += 1", "x ..= 'a'".  Not "x == 1" or "x =~ 'p'".
  if after =~ '^\s*\%(=[^=~]\|[-+*/%]=\|\.\.=\)'
    return 3
  endif
  return 2
enddef

# The uses of a name Vim itself knows, a builtin function or a v: variable.
# The parser does not track these, so the tokens are matched by name.
def VimNameUses(w: dict<any>): list<dict<number>>
  var name = w.token.text
  if w.token.in_string || w.token.prev == '.' || w.token.prev == '&'
    return []
  endif
  if infer.Info(name =~ '^v:' ? 'vimvar' : 'function', name)->empty()
    return []
  endif
  var vim9_at = parse.Vim9Lines(w.parsed, len(w.doc.lines))
  var uses: list<dict<number>> = []
  for lnum in range(len(w.doc.lines))
    var line = w.doc.lines[lnum]
    if stridx(line, name) < 0
      continue
    endif
    for token in refs.Tokens(line, vim9_at[lnum])
      if token.text == name && !token.in_string && token.prev != '.'
          && token.prev != '&'
        uses->add({line: lnum, col: token.col, end: token.end})
      endif
    endfor
  endfor
  return uses
enddef

# The uses of the name under the cursor in this document alone.
def Highlights(params: dict<any>): any
  var w = TokenWhere(params)
  if w == null_dict
    return v:null
  endif
  var hit = Lookup(w, w.token)
  if hit == null_dict
    var known = VimNameUses(w)
    return known->empty() ? v:null : known->mapnew((_, r) => ({
      range: util.Range(w.doc.lines, r.line, r.col, r.line, r.end, encoding),
      kind: UseKind(w.doc.lines->get(r.line, ''), r.col, r.end),
    }))
  endif
  var uses: list<dict<number>> = []
  if hit.uri == w.uri
    for r in refs.References(hit.parsed, hit.lines, hit.symbol, true)
      var text = hit.lines[r.line][r.col : r.end - 1]
      uses->add({line: r.line, col: r.col + strridx(text, '#') + 1,
        end: r.end})
    endfor
  else
    # The name belongs to another script, only its uses here can be marked.
    var shared = Shared(hit)
    if shared == null_dict
      return v:null
    endif
    uses = refs.UsesOf(w.parsed, w.doc.lines, w.path, shared)
  endif
  return uses->mapnew((_, r) => ({
    range: util.Range(w.doc.lines, r.line, r.col, r.line, r.end, encoding),
    kind: UseKind(w.doc.lines->get(r.line, ''), r.col, r.end),
  }))
enddef

# The name proper of the token under the cursor and what defines it, for
# renaming; null_dict when the name is neither defined in this document nor
# shared by the script that defines it.
def Renamable(params: dict<any>): dict<any>
  var w = TokenWhere(params)
  if w == null_dict
    return null_dict
  endif
  var hit = Lookup(w, w.token)
  if hit == null_dict
    return null_dict
  endif
  w.hit = hit
  w.shared = Shared(hit)
  if hit.uri != w.uri && w.shared == null_dict
    return null_dict
  endif
  w.name = matchstr(refs.Core(w.token.text), '[^#]*$')
  w.range = util.Range(w.doc.lines, w.lnum, w.token.end - strlen(w.name),
    w.lnum, w.token.end, encoding)
  return w
enddef

def PrepareRename(params: dict<any>): any
  var w = Renamable(params)
  if w == null_dict
    return v:null
  endif
  return {range: w.range, placeholder: w.name}
enddef

def Rename(params: dict<any>): any
  var new_name: string = params->get('newName', '')
  if new_name !~ '^\h\w*$'
    throw 'InvalidParams: not a valid name: ' .. new_name
  endif
  var w = Renamable(params)
  if w == null_dict
    throw 'InvalidParams: the name is not defined in this file'
  endif
  var changes: dict<list<dict<any>>> = {}
  for u in SharedUses(w.hit, w.shared, true)
    if !changes->has_key(u.uri)
      changes[u.uri] = []
    endif
    changes[u.uri]->add({range: util.Range(u.lines, u.line, u.col, u.line,
      u.end, encoding), newText: new_name})
  endfor
  return {changes: changes}
enddef

def Request(method: string, params: dict<any>): any
  if method == 'initialize'
    return Initialize(params)
  elseif method == 'shutdown'
    EndPull(false)
    compile.Stop()
    cache.Save()
    return v:null
  elseif method == 'textDocument/hover'
    return Hover(params)
  elseif method == 'textDocument/diagnostic'
    return DocumentDiagnostics(params)
  elseif method == 'textDocument/completion'
    return Completion(params)
  elseif method == 'completionItem/resolve'
    return ResolveItem(params)
  elseif method == 'textDocument/documentSymbol'
    return DocumentSymbols(params)
  elseif method == 'workspace/symbol'
    return WorkspaceSymbols(params)
  elseif method == 'textDocument/foldingRange'
    return FoldingRanges(params)
  elseif method == 'textDocument/selectionRange'
    return SelectionRanges(params)
  elseif method == 'textDocument/definition'
    return Definition(params)
  elseif method == 'textDocument/typeDefinition'
    return TypeDefinition(params)
  elseif method == 'textDocument/implementation'
    return Implementation(params)
  elseif method == 'textDocument/formatting'
    return Formatting(params)
  elseif method == 'textDocument/rangeFormatting'
    return RangeFormatting(params)
  elseif method == 'textDocument/prepareTypeHierarchy'
    return PrepareTypeHierarchy(params)
  elseif method == 'typeHierarchy/supertypes'
    return Supertypes(params)
  elseif method == 'typeHierarchy/subtypes'
    return SubtypeItems(params)
  elseif method == 'textDocument/references'
    return References(params)
  elseif method == 'textDocument/documentHighlight'
    return Highlights(params)
  elseif method == 'textDocument/prepareRename'
    return PrepareRename(params)
  elseif method == 'textDocument/rename'
    return Rename(params)
  elseif method == 'textDocument/signatureHelp'
    return SignatureHelp(params)
  elseif method == 'textDocument/codeAction'
    return CodeActions(params)
  elseif method == 'textDocument/inlayHint'
    return InlayHints(params)
  endif
  throw 'MethodNotFound'
enddef

def Notification(method: string, params: dict<any>)
  if method == 'exit'
    qall!
  elseif method == 'initialized'
    if log_failure != ''
      Notify('window/showMessage', {type: 2, message: log_failure})
    elseif log_file != ''
      Notify('window/logMessage', {type: 4,
        message: $'vim9ls: logging to "{log_file}"'})
    endif
    if option_warning != ''
      Notify('window/logMessage', {type: 2, message: option_warning})
    endif
    # The scripts of the workspace are read again when the client sees one
    # change; a pattern with no base of its own holds for every folder.
    if watch_files
      ch_sendexpr(conn, {method: 'client/registerCapability', params: {
        registrations: [{id: 'vim9ls-watched-files',
          method: 'workspace/didChangeWatchedFiles',
          registerOptions: {watchers: [{globPattern: '**/*.vim'}]}}]}},
        {callback: (_, _) => 0})
    endif
  elseif method == 'textDocument/didOpen'
    SetDoc(params.textDocument.uri, params.textDocument.text,
      params.textDocument->get('version', v:null))
    ScanWorkspace([util.UriToPath(params.textDocument.uri)])
  elseif method == 'textDocument/didChange'
    ChangeDoc(params.textDocument.uri, params.contentChanges,
      params.textDocument->get('version', v:null))
  elseif method == 'textDocument/didSave'
    compile.FilesChanged()
    PublishDiagnostics(params.textDocument.uri)
    ScanWorkspace(Mentioning(util.UriToPath(params.textDocument.uri)))
  elseif method == 'textDocument/didClose'
    compile.FilesChanged()
    if docs->has_key(params.textDocument.uri)
      remove(docs, params.textDocument.uri)
    endif
    ScanWorkspace()
  elseif method == 'workspace/didChangeWorkspaceFolders'
    var event = params->get('event', {})
    for f in event->get('removed', [])
      var path = util.UriToPath(f->get('uri', ''))
      filter(folders, (_, p) => p != path)
    endfor
    AddFolders(event->get('added', []))
    ScanWorkspace()
  elseif method == 'workspace/didChangeWatchedFiles'
    compile.FilesChanged()
    # One that is gone is left as it was reported, for ScanWorkspace() to find
    # it missing.
    ScanWorkspace(params->get('changes', [])
      ->mapnew((_, c) => util.UriToPath(c->get('uri', '')))
      ->filter((_, p) => filereadable(p)))
  elseif method == '$/cancelRequest'
    if pull != null_dict && string(params->get('id', '')) == string(pull.id)
      EndPull(true)
    endif
  endif
enddef

def OnMessage(_: channel, msg: dict<any>)
  var method: string = msg->get('method', '')
  if method == ''
    # A response; the server has nothing outstanding.
    return
  endif
  var given: any = msg->get('params', {})
  var params: dict<any> = type(given) == v:t_dict ? given : {}
  if method == 'workspace/diagnostic' && msg->has_key('id')
    WorkspacePull(msg.id, params)
    return
  elseif method == 'workspace/executeCommand' && msg->has_key('id')
    Reload(msg.id, params)
    return
  endif
  try
    if msg->has_key('id')
      Reply(msg.id, Request(method, params))
    else
      Notification(method, params)
    endif
  catch /^MethodNotFound$/
    ReplyError(msg.id, -32601, 'Method not found: ' .. method)
  catch /^InvalidParams: /
    ReplyError(msg.id, -32602, substitute(v:exception, '^InvalidParams: ',
      '', ''))
  catch
    util.Log(v:throwpoint .. ': ' .. v:exception)
    if msg->has_key('id')
      ReplyError(msg.id, -32603, v:exception)
    endif
  endtry
enddef

def OnClose(_: channel)
  cache.Save()
  qall!
enddef

# Nothing is displayed with --stdio-channel, but with 'verbose' set an error
# still goes to stderr, where the client can show it.
def Die(msg: string)
  &verbose = 1
  echoerr 'vim9ls: ' .. msg
  cquit
enddef

export def Start()
  # A client other than Vim starts the server without Command().
  if !has('patch-' .. PATCH)
    Die($'this Vim needs {PATCH} or later to run the server')
  endif
  # The log only helps to debug; not a reason to stop serving.
  if $VIM9LS_LOG != ''
    var dir = has('win32') ? $TEMP : $TMPDIR != '' ? $TMPDIR : '/tmp'
    var file = $'{substitute(dir, '[/\\]$', '', '')}/vim9ls_{getpid()}.log'
    try
      ch_logfile(file, 'a')
      log_file = file
    catch
      log_failure = $'vim9ls: cannot open the log file "{file}": '
        .. substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', '')
    endtry
  endif
  try
    conn = ch_open('stdio', {mode: 'lsp', callback: OnMessage,
      close_cb: OnClose})
  catch
    Die(substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', ''))
  endtry
  if ch_status(conn) != 'open'
    Die('cannot open the stdio channel')
  endif
enddef

if index(v:argv, '--stdio-channel') >= 0
  Start()
endif

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
