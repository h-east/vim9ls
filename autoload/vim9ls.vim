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

export const VERSION = '0.1.001'

const SCRIPT = expand('<sfile>:p')

export def Command(): list<string>
  if !has('channel') || !has('job')
    throw 'vim9ls: this Vim needs +channel and +job to run the server'
  endif
  # --stdio-channel came with 9.2.1049, and 9.2.1055 compiles a function
  # with a lambda after another function failed to compile.
  if !has('patch-9.2.1055')
    throw 'vim9ls: this Vim needs 9.2.1055 or later to run the server'
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
  return {
    capabilities: {
      positionEncoding: encoding,
      textDocumentSync: {openClose: true, change: 2, save: true},
      hoverProvider: true,
      completionProvider: {triggerCharacters: ['&', ':'],
        resolveProvider: true},
      documentSymbolProvider: true,
      definitionProvider: true,
      referencesProvider: true,
      renameProvider: {prepareProvider: true},
      signatureHelpProvider: {triggerCharacters: ['(', ',']},
      codeActionProvider: {codeActionKinds: ['quickfix']},
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

# What the parser found, and what Vim reports when the checker reads the
# document.  The checker is asked and answers later; the diagnostics go out
# when it has.
def PublishDiagnostics(uri: string)
  var d = docs->get(uri, null_dict)
  if d == null_dict
    return
  endif
  d.timer = -1
  var parsed = Parsed(d)
  var path = util.UriToPath(uri)
  var undefined = names.Undefined(parsed, d.lines,
    (name: string): number => AutoloadDefined(path, name))
  var items = diag.Diagnostics(parsed.diags + undefined, d.lines, encoding)
  var version = d.version
  if path == '' || !compile.Check(path, d.lines,
      parsed.vim9 ? wrap.Lines(parsed, d.lines) : null,
      (errors: any) => Publish(uri, version, items, errors))
    Publish(uri, version, items, null)
  endif
enddef

# Sends "items" and what the checker reported, "errors", for the document at
# "uri" while it is still at "version".  The two may name the same error; it
# is sent once.  When the checker gave no answer, what it reported last time
# stays.
def Publish(uri: string, version: any, items: list<dict<any>>, errors: any)
  var d = docs->get(uri, null_dict)
  if d == null_dict || d.version != version
    return
  endif
  if errors != null
    d.compiled = errors
  endif
  var all = copy(items)
  for item in compile.Diagnostics(d.compiled, d.lines, encoding)
    if all->indexof((_, i) => i.message == item.message
        && i.range.start.line == item.range.start.line) < 0
      add(all, item)
    endif
  endfor
  Notify('textDocument/publishDiagnostics', {
    uri: uri,
    version: d.version,
    diagnostics: all,
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
    stale: true, timer: -1, compiled: []}
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
  inserted[0] = (col == 0 ? '' : first_line[: col - 1]) .. inserted[0]
  inserted[-1] = inserted[-1] .. last_line[end_col :]
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
  if line[at] !~ WORD && at > 0 && line[at - 1] =~ WORD
    at -= 1
  endif
  var begin = at
  while begin > 0 && line[begin - 1] =~ WORD
    begin -= 1
  endwhile
  var stop = at
  while stop < strlen(line) && line[stop] =~ WORD
    stop += 1
  endwhile
  return {word: line[begin : stop - 1], start: begin, end: stop}
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
  var before = found.start == 0 ? '' : line[: found.start - 1]
  var after = line[found.end :]
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
    if s.name ==# name || s.name =~# '#' .. name .. '$'
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

  # "alias.Name": a name from an imported script.
  if token.prev == '.' && token.col >= 2
    var alias = matchstr(w.line[: token.col - 2], refs.NAME .. '\+$')
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
    ->map((_, f) => fnamemodify(f, ':p'))
  for uri in keys(docs)
    add(paths, util.UriToPath(uri))
  endfor
  return sort(paths)->uniq()->filter((_, p) => p !=# path)
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

# The signature of the function a script defines: its name and what follows
# it on the "def" or "function" line, up to the ")" for a legacy function.
def ScriptSignature(s: dict<any>): string
  var detail = s.detail
  if s->get('legacy', false)
    detail = matchstr(detail, '^([^)]*)')
  endif
  return s.name .. detail
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
    return sig.Help(label, active, nl < 0 ? '' : text[nl + 1 :])
  endif

  var token = {text: hit.name, col: hit.col, end: hit.col
    + strlen(hit.name), prev: hit.prev, in_string: false}
  var found = Lookup(w, token)
  if found == null_dict || (found.symbol.kind != parse.KIND_FUNCTION
      && found.symbol.kind != parse.KIND_METHOD)
    return v:null
  endif
  return sig.Help(ScriptSignature(found.symbol), active)
enddef

def CodeActions(params: dict<any>): any
  var uri = params.textDocument.uri
  var d = docs->get(uri, null_dict)
  if d == null_dict
    return v:null
  endif
  var range = params->get('range', {})
  return fix.Actions(Parsed(d), d.lines, uri,
    range->get('start', {})->get('line', 0),
    range->get('end', {})->get('line', len(d.lines)), encoding)
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
    compile.Stop()
    return v:null
  elseif method == 'textDocument/hover'
    return Hover(params)
  elseif method == 'textDocument/completion'
    return Completion(params)
  elseif method == 'completionItem/resolve'
    return ResolveItem(params)
  elseif method == 'textDocument/documentSymbol'
    return DocumentSymbols(params)
  elseif method == 'textDocument/definition'
    return Definition(params)
  elseif method == 'textDocument/references'
    return References(params)
  elseif method == 'textDocument/prepareRename'
    return PrepareRename(params)
  elseif method == 'textDocument/rename'
    return Rename(params)
  elseif method == 'textDocument/signatureHelp'
    return SignatureHelp(params)
  elseif method == 'textDocument/codeAction'
    return CodeActions(params)
  endif
  throw 'MethodNotFound'
enddef

def Notification(method: string, params: dict<any>)
  if method == 'exit'
    qall!
  elseif method == 'textDocument/didOpen'
    SetDoc(params.textDocument.uri, params.textDocument.text,
      params.textDocument->get('version', v:null))
  elseif method == 'textDocument/didChange'
    ChangeDoc(params.textDocument.uri, params.contentChanges,
      params.textDocument->get('version', v:null))
  elseif method == 'textDocument/didSave'
    PublishDiagnostics(params.textDocument.uri)
  elseif method == 'textDocument/didClose'
    if docs->has_key(params.textDocument.uri)
      remove(docs, params.textDocument.uri)
    endif
  endif
enddef

def OnMessage(ch: channel, msg: dict<any>)
  var method: string = msg->get('method', '')
  if method == ''
    # A response; the server has nothing outstanding.
    return
  endif
  var given: any = msg->get('params', {})
  var params: dict<any> = type(given) == v:t_dict ? given : {}
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

def OnClose(ch: channel)
  qall!
enddef

export def Start()
  if $VIM9LS_LOG != ''
    ch_logfile($VIM9LS_LOG, 'a')
  endif
  conn = ch_open('stdio', {mode: 'lsp', callback: OnMessage,
    close_cb: OnClose})
  if ch_status(conn) != 'open'
    cquit
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
