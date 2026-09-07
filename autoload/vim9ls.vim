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

export const VERSION = '0.1.0'
const SCRIPT = expand('<sfile>:p')

export def Command(): list<string>
  # --stdio-channel cannot be checked from here; a Vim without it says so
  # when the server is started.
  if !has('channel') || !has('job')
    throw 'vim9ls: this Vim needs +channel and +job to run the server'
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
      textDocumentSync: 1,
      hoverProvider: true,
      completionProvider: {triggerCharacters: ['&', ':']},
      documentSymbolProvider: true,
    },
    serverInfo: {name: 'vim9ls', version: VERSION},
  }
enddef

def SetDoc(uri: string, text: string, version: any)
  var lines = split(text, '\r\=\n', true)
  var parsed = parse.Parse(lines)
  docs[uri] = {lines: lines, version: version, parsed: parsed}
  Notify('textDocument/publishDiagnostics', {
    uri: uri,
    version: version,
    diagnostics: diag.Diagnostics(parsed.diags, lines, encoding),
  })
enddef

# The document and the line and byte column "params" point at.
def Where(params: dict<any>): dict<any>
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return null_dict
  endif
  var lnum = params.position.line
  var line = d.lines->get(lnum, '')
  return {doc: d, lnum: lnum, line: line,
    col: util.ColFromLsp(line, params.position.character, encoding)}
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
  var w = Where(params)
  if w == null_dict
    return v:null
  endif
  return {
    isIncomplete: false,
    items: complete.Items(w.line, w.col, w.doc.parsed.symbols),
  }
enddef

def DocumentSymbols(params: dict<any>): any
  var d = docs->get(params.textDocument.uri, null_dict)
  if d == null_dict
    return v:null
  endif
  return symbol.DocumentSymbols(d.parsed.symbols, d.lines, encoding)
enddef

def Request(method: string, params: dict<any>): any
  if method == 'initialize'
    return Initialize(params)
  elseif method == 'shutdown'
    return v:null
  elseif method == 'textDocument/hover'
    return Hover(params)
  elseif method == 'textDocument/completion'
    return Completion(params)
  elseif method == 'textDocument/documentSymbol'
    return DocumentSymbols(params)
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
    SetDoc(params.textDocument.uri, params.contentChanges[-1].text,
      params.textDocument->get('version', v:null))
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
