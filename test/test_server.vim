vim9script

import './helper.vim'
import './test_parse.vim' as samples
import autoload '../autoload/vim9ls/util.vim'

import autoload '../autoload/vim9ls.vim'

def g:Test_command()
  var cmd = vim9ls.Command()
  assert_equal(['--clean', '--stdio-channel', '-S'], cmd[1 : 3])
  assert_equal(helper.SERVER, cmd[4])
  assert_true(executable(cmd[0]))
enddef

def g:Test_initialize()
  helper.StartServer()
  var resp = helper.Initialize(['utf-8', 'utf-16'])
  var caps = resp.result.capabilities
  assert_equal('utf-8', caps.positionEncoding)
  assert_equal({openClose: true, change: 2, save: true}, caps.textDocumentSync)
  assert_true(caps.hoverProvider)
  assert_true(caps.documentSymbolProvider)
  assert_equal(['&', ':'], caps.completionProvider.triggerCharacters)
  assert_equal(['(', ','], caps.signatureHelpProvider.triggerCharacters)
  assert_equal('vim9ls', resp.result.serverInfo.name)
enddef

def g:Test_initialize_utf16()
  helper.StartServer()
  var resp = helper.Initialize(['utf-16'])
  assert_equal('utf-16', resp.result.capabilities.positionEncoding)
  helper.StopServer()

  # A client that offers nothing gets what the protocol requires.
  helper.StartServer()
  resp = helper.Request('initialize', {processId: null, rootUri: null,
    capabilities: {}})
  assert_equal('utf-16', resp.result.capabilities.positionEncoding)
enddef

def g:Test_hover()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    "var n = strlen('abc')",
    'set textwidth=80',
    'echo &tw',
    'var e = v:count',
    'silent! echo &l:sw',
  ])

  var resp = helper.Request('textDocument/hover', helper.Params(1, 10))
  assert_match('^strlen({string})', resp.result.contents.value)
  assert_equal('plaintext', resp.result.contents.kind)
  assert_equal({start: {line: 1, character: 8}, end: {line: 1, character: 14}},
    resp.result.range)

  resp = helper.Request('textDocument/hover', helper.Params(2, 6))
  assert_match("^'textwidth' 'tw'", resp.result.contents.value)

  resp = helper.Request('textDocument/hover', helper.Params(3, 6))
  assert_match("^'textwidth' 'tw'", resp.result.contents.value)

  resp = helper.Request('textDocument/hover', helper.Params(3, 1))
  assert_match('^:ec\[ho\]', resp.result.contents.value)

  resp = helper.Request('textDocument/hover', helper.Params(4, 10))
  assert_match('v:count', resp.result.contents.value)

  resp = helper.Request('textDocument/hover', helper.Params(5, 16))
  assert_match("^'shiftwidth' 'sw'", resp.result.contents.value)

  # A variable of the script has no help.
  resp = helper.Request('textDocument/hover', helper.Params(1, 4))
  assert_equal(null, resp.result)

  # Right after a word counts as on it.
  resp = helper.Request('textDocument/hover', helper.Params(1, 14))
  assert_match('^strlen', resp.result.contents.value)
enddef

# A variable that is spelled like a command is still a variable.
def g:Test_hover_variable_not_command()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'g:loaded_gzip = 1',
    'let g:loaded_gzip = 1',
    'n = 1',
    'n += 1',
    'echo g:loaded_gzip',
    's:count = 2',
  ])
  for [line, character] in [[0, 3], [0, 0], [1, 6], [2, 0], [3, 0], [4, 7],
      [5, 3]]
    var resp = helper.Request('textDocument/hover',
      helper.Params(line, character))
    assert_equal(null, resp.result, $'line {line} character {character}')
  endfor
  # The command in front of the variable still has its help.
  var resp = helper.Request('textDocument/hover', helper.Params(1, 1))
  assert_match('^:let', resp.result.contents.value)
enddef

def g:Test_hover_utf16()
  helper.StartServer()
  helper.Initialize(['utf-16'])
  helper.OpenDoc(["echo '😀' .. strlen('a')"])
  # "strlen" starts at byte 12 and at UTF-16 unit 10.
  var resp = helper.Request('textDocument/hover', helper.Params(0, 11))
  assert_match('^strlen', resp.result.contents.value)
  assert_equal(10, resp.result.range.start.character)
  assert_equal(16, resp.result.range.end.character)
enddef

def Labels(items: list<dict<any>>): list<string>
  return items->mapnew((_, i) => i.label)
enddef

def g:Test_completion()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'def MyFunc()',
    'enddef',
    'var myVar = 1',
    'echo strl',
    'echo &tw',
    '  My',
    'ec',
  ])

  var resp = helper.Request('textDocument/completion', helper.Params(4, 9))
  assert_false(resp.result.isIncomplete)
  var items = resp.result.items
  assert_true(index(Labels(items), 'strlen') >= 0)
  assert_equal(3, items[Labels(items)->index('strlen')].kind)
  assert_true(index(Labels(items), 'textwidth') < 0)

  resp = helper.Request('textDocument/completion', helper.Params(5, 8))
  items = resp.result.items
  assert_true(index(Labels(items), 'textwidth') >= 0)
  assert_equal(10, items[Labels(items)->index('textwidth')].kind)
  assert_true(index(Labels(items), 'strlen') < 0)

  resp = helper.Request('textDocument/completion', helper.Params(6, 4))
  items = resp.result.items
  assert_true(index(Labels(items), 'MyFunc') >= 0)
  assert_true(index(Labels(items), 'myVar') < 0)

  resp = helper.Request('textDocument/completion', helper.Params(7, 2))
  items = resp.result.items
  assert_true(index(Labels(items), 'echo') >= 0)
  assert_equal(14, items[Labels(items)->index('echo')].kind)
enddef

def g:Test_document_symbol()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(samples.VIM9_SAMPLE)
  var resp = helper.Request('textDocument/documentSymbol',
    {textDocument: {uri: helper.URI}})
  var symbols = resp.result
  assert_equal(['foo', 'count', 'LIMIT', 'Outer', 'Shape', 'Color',
    'Drawable', 'MyGroup', 'Hello'], symbols->mapnew((_, s) => s.name))
  var outer = symbols[3]
  assert_equal(12, outer.kind)
  assert_equal({line: 4, character: 0}, outer.range.start)
  assert_equal({line: 8, character: 6}, outer.range.end)
  assert_equal({line: 4, character: 11}, outer.selectionRange.start)
  assert_equal({line: 4, character: 16}, outer.selectionRange.end)
  assert_equal('Inner', outer.children[0].name)
  assert_equal(['name', 'total', 'new', 'Area'],
    symbols[4].children->mapnew((_, s) => s.name))
  assert_false(symbols[0]->has_key('children'))
enddef

def g:Test_diagnostics()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(['if 1', "echo 'x'"])
  var note = helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal(helper.URI, note.params.uri)
  assert_equal(1, note.params.version)
  var diags = note.params.diagnostics
  assert_equal(1, len(diags))
  assert_equal('E171: Missing :endif', diags[0].message)
  assert_equal(1, diags[0].severity)
  assert_equal('vim9ls', diags[0].source)
  assert_equal({start: {line: 0, character: 0}, end: {line: 0, character: 4}},
    diags[0].range)

  helper.ChangeDoc(['if 1', 'endif'])
  note = helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal(2, note.params.version)
  assert_equal([], note.params.diagnostics)
enddef

# What the saved document gets from Vim itself: [line, message] of each.
def Compiled(): list<list<any>>
  helper.SaveDoc()
  var note = helper.WaitNotification('textDocument/publishDiagnostics')
  return note.params.diagnostics
    ->mapnew((_, d) => [d.range.start.line, d.message])
    ->sort((a, b) => a[0] - b[0])
enddef

def g:Test_compile_diagnostics()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'def Broken(): number',
    '  return "x"',
    'enddef',
    'def WithLambda(): number',
    '  var F = (n: number): number => {',
    '    return "s"',
    '  }',
    '  return F(1)',
    'enddef',
  ])
  helper.WaitNotification('textDocument/publishDiagnostics')
  var expected = [
    [2, 'E1012: Type mismatch; expected number but got string'],
    [6, 'E1012: Type mismatch; expected number but got string'],
  ]
  assert_equal(expected, Compiled())
  # The same script read once more reports the same.
  assert_equal(expected, Compiled())
  helper.SaveDoc()
  var note = helper.WaitNotification('textDocument/publishDiagnostics')
  var d = note.params.diagnostics[0]
  assert_equal(1, d.severity)
  assert_equal('vim9ls', d.source)
  assert_equal({start: {line: 2, character: 0}, end: {line: 2, character: 12}},
    d.range)

  # Fixed: nothing is left, and what the parser reports is not doubled.
  helper.ChangeDoc(['vim9script', 'let x = 1', 'def Fine(): number',
    '  return 1', 'enddef'])
  helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal([[1, 'E1126: Cannot use :let in Vim9 script']], Compiled())

  # A script-level error stops the script; the functions defined up to there
  # are compiled still.  A legacy script's functions are not read until
  # called, and a function without "!" is fine to read again.
  helper.ChangeDoc(['vim9script', 'def Early(): number', '  return "x"',
    'enddef', 'var n: number = "s"'], helper.URI, 3)
  helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal([[2, 'E1012: Type mismatch; expected number but got string'],
    [4, 'E1012: Type mismatch; expected number but got string']], Compiled())
  helper.ChangeDoc(['function Legacy()', '  return undefined_a', 'endfunction',
    'echo undefined_b'], helper.URI, 4)
  helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal([[3, 'E121: Undefined variable: undefined_b']], Compiled())
  assert_equal([[3, 'E121: Undefined variable: undefined_b']], Compiled())

  # The script level runs, a shell command in it too; a script that ends the
  # checker gets no answer, and the next save is answered by a new one.
  helper.ChangeDoc(['vim9script', 'echo system("echo x")'], helper.URI, 5)
  helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal([], Compiled())
  helper.ChangeDoc(['vim9script', 'qall!'], helper.URI, 6)
  helper.WaitNotification('textDocument/publishDiagnostics')
  helper.SaveDoc()
  helper.ChangeDoc(['vim9script', 'var n: number = "s"'], helper.URI, 7)
  helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal([[1, 'E1012: Type mismatch; expected number but got string']],
    Compiled())
enddef

def g:Test_definition()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'var count = 0',
    'def Helper(): number',
    '  var count = 1',
    '  return count',
    'enddef',
    'echo Helper() + count',
    'class Shape',
    '  var name: string',
    '  def Describe(): string',
    '    return this.name',
    '  enddef',
    'endclass',
    'echo strlen("x")',
  ])
  var resp = helper.Request('textDocument/definition', helper.Params(6, 6))
  assert_equal([{uri: helper.URI, range: {start: {line: 2, character: 4},
    end: {line: 2, character: 10}}}], resp.result)
  # The local shadows the script variable inside the function.
  resp = helper.Request('textDocument/definition', helper.Params(4, 10))
  assert_equal(3, resp.result[0].range.start.line)
  resp = helper.Request('textDocument/definition', helper.Params(6, 17))
  assert_equal(1, resp.result[0].range.start.line)
  # A member goes to the field.
  resp = helper.Request('textDocument/definition', helper.Params(10, 17))
  assert_equal({start: {line: 8, character: 6}, end: {line: 8, character: 10}},
    resp.result[0].range)
  # A builtin has no definition here.
  resp = helper.Request('textDocument/definition', helper.Params(13, 6))
  assert_equal(null, resp.result)
enddef

def g:Test_definition_other_files()
  var root = helper.HERE .. '/Xproj'
  mkdir(root .. '/autoload', 'p')
  mkdir(root .. '/plugin', 'p')
  writefile(['vim9script', 'export def Greet(): string', "  return 'hi'",
    'enddef'], root .. '/autoload/xlib.vim')
  writefile(['function xold#Func()', 'endfunction'],
    root .. '/autoload/xold.vim')
  writefile(['vim9script', 'export const LIMIT = 3'],
    root .. '/plugin/xconst.vim')
  var main = root .. '/plugin/xmain.vim'
  var uri = util.PathToUri(main)
  try
    helper.StartServer()
    helper.Initialize()
    helper.OpenDoc([
      'vim9script',
      "import autoload 'xlib.vim' as xlib",
      "import './xconst.vim'",
      'echo xlib.Greet()',
      'echo xconst.LIMIT',
      'call xold#Func()',
    ], uri)
    var resp = helper.Request('textDocument/definition',
      helper.Params(3, 11, uri))
    assert_equal(util.PathToUri(root .. '/autoload/xlib.vim'),
      resp.result[0].uri)
    assert_equal({start: {line: 1, character: 11},
      end: {line: 1, character: 16}}, resp.result[0].range)
    # The alias itself leads to the file.
    resp = helper.Request('textDocument/definition', helper.Params(3, 6, uri))
    assert_equal(util.PathToUri(root .. '/autoload/xlib.vim'),
      resp.result[0].uri)
    assert_equal(0, resp.result[0].range.start.line)
    # A relative import, named by its file.
    resp = helper.Request('textDocument/definition',
      helper.Params(4, 13, uri))
    assert_equal(util.PathToUri(root .. '/plugin/xconst.vim'),
      resp.result[0].uri)
    assert_equal(1, resp.result[0].range.start.line)
    # A legacy autoload function.
    resp = helper.Request('textDocument/definition',
      helper.Params(5, 10, uri))
    assert_equal(util.PathToUri(root .. '/autoload/xold.vim'),
      resp.result[0].uri)
    assert_equal({start: {line: 0, character: 9},
      end: {line: 0, character: 18}}, resp.result[0].range)
  finally
    delete(root, 'rf')
  endtry
enddef

def g:Test_references()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'function s:Init()',
    'endfunction',
    'call s:Init()',
    "let F = function('s:Init')",
    'echo "s:Init"',
  ])
  var resp = helper.Request('textDocument/references', extend(
    helper.Params(2, 8), {context: {includeDeclaration: true}}))
  assert_equal([[0, 11, 15], [2, 7, 11], [3, 20, 24], [4, 8, 12]],
    resp.result->mapnew((_, l) => [l.range.start.line, l.range.start.character,
      l.range.end.character]))
  assert_equal(helper.URI, resp.result[0].uri)
  resp = helper.Request('textDocument/references', extend(
    helper.Params(2, 8), {context: {includeDeclaration: false}}))
  assert_equal(3, len(resp.result))
  # Nothing known under the cursor.
  resp = helper.Request('textDocument/references', extend(
    helper.Params(0, 0), {context: {includeDeclaration: true}}))
  assert_equal(null, resp.result)
enddef

def g:Test_rename()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'function s:Init()',
    'endfunction',
    'call s:Init()',
    'call <SID>Init()',
    'echo strlen("x")',
  ])
  var resp = helper.Request('textDocument/prepareRename', helper.Params(2, 8))
  assert_equal({range: {start: {line: 2, character: 7},
    end: {line: 2, character: 11}}, placeholder: 'Init'}, resp.result)
  resp = helper.Request('textDocument/rename', extend(helper.Params(2, 8),
    {newName: 'Setup'}))
  var edits = resp.result.changes[helper.URI]
  assert_equal([[0, 11, 15], [2, 7, 11], [3, 10, 14]],
    edits->mapnew((_, e) => [e.range.start.line, e.range.start.character,
      e.range.end.character]))
  assert_equal(['Setup', 'Setup', 'Setup'], edits->mapnew((_, e) => e.newText))
  # Not a name, and not something defined here.
  resp = helper.Request('textDocument/rename', extend(helper.Params(2, 8),
    {newName: 'no good'}))
  assert_equal(-32602, resp.error.code)
  resp = helper.Request('textDocument/rename', extend(helper.Params(4, 6),
    {newName: 'Other'}))
  assert_equal(-32602, resp.error.code)
  resp = helper.Request('textDocument/prepareRename', helper.Params(4, 6))
  assert_equal(null, resp.result)
enddef

def g:Test_signature_help()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'def Add(a: number, b: number = 1): number',
    '  return a + b',
    'enddef',
    "echo matchstr('abc', 'b', ",
    'echo Add(1, ',
    "echo 'x'->matchstr('a', ",
    'echo nothing(1, ',
    'echo 1 + 2',
    'function s:Init(x, y) abort',
    'endfunction',
    'call s:Init(1, ',
    'echo Add(',
    '  1,',
    '  ',
  ])
  var resp = helper.Request('textDocument/signatureHelp',
    helper.Params(4, 26))
  var help = resp.result
  assert_equal(2, help.activeParameter)
  assert_equal('matchstr({expr}, {pat} [, {start} [, {count}]])',
    help.signatures[0].label)
  assert_equal(4, len(help.signatures[0].parameters))
  assert_match('^Same as', help.signatures[0].documentation.value)

  resp = helper.Request('textDocument/signatureHelp', helper.Params(5, 12))
  assert_equal('Add(a: number, b: number = 1): number',
    resp.result.signatures[0].label)
  assert_equal(1, resp.result.activeParameter)
  assert_equal([[4, 13], [15, 28]],
    resp.result.signatures[0].parameters->mapnew((_, p) => p.label))

  # The value in front of "->" is the first argument.
  resp = helper.Request('textDocument/signatureHelp', helper.Params(6, 24))
  assert_equal(2, resp.result.activeParameter)

  resp = helper.Request('textDocument/signatureHelp', helper.Params(7, 16))
  assert_equal(null, resp.result)
  resp = helper.Request('textDocument/signatureHelp', helper.Params(8, 8))
  assert_equal(null, resp.result)

  resp = helper.Request('textDocument/signatureHelp', helper.Params(11, 15))
  assert_equal('s:Init(x, y)', resp.result.signatures[0].label)
  assert_equal(1, resp.result.activeParameter)

  # The call started two lines up.
  resp = helper.Request('textDocument/signatureHelp', helper.Params(14, 2))
  assert_equal('Add(a: number, b: number = 1): number',
    resp.result.signatures[0].label)
  assert_equal(1, resp.result.activeParameter)
enddef

# Changes come as ranges; the server keeps the text up to date from them.
def g:Test_incremental_sync()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(['vim9script', 'def One()', 'enddef', 'echo One()'])
  helper.WaitNotification('textDocument/publishDiagnostics')
  # Insert in the middle of a line: "One" becomes "OneTwo".
  helper.ChangeRange([1, 7, 1, 7], 'Two', 2)
  # Replace across lines: the call and the line after it.
  helper.ChangeRange([3, 5, 3, 8], "OneTwo()\nvar x = 1\nif x", 3)
  var resp = helper.Request('textDocument/documentSymbol',
    {textDocument: {uri: helper.URI}})
  assert_equal(['OneTwo', 'x'], resp.result->mapnew((_, s) => s.name))
  resp = helper.Request('textDocument/references', extend(
    helper.Params(1, 5), {context: {includeDeclaration: true}}))
  assert_equal([[1, 4, 10], [3, 5, 11]],
    resp.result->mapnew((_, l) => [l.range.start.line, l.range.start.character,
      l.range.end.character]))
  # The diagnostics follow, once, after the changes.
  var note = helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal(3, note.params.version)
  assert_equal(['E171: Missing :endif'],
    note.params.diagnostics->mapnew((_, d) => d.message))
  # Delete a whole line, and the text of the whole document.
  helper.ChangeRange([4, 0, 5, 2], '', 4)
  resp = helper.Request('textDocument/documentSymbol',
    {textDocument: {uri: helper.URI}})
  assert_equal(['OneTwo'], resp.result->mapnew((_, s) => s.name))
  helper.ChangeDoc(['def Whole()', 'enddef'], helper.URI, 5)
  resp = helper.Request('textDocument/documentSymbol',
    {textDocument: {uri: helper.URI}})
  assert_equal(['Whole'], resp.result->mapnew((_, s) => s.name))
enddef

def g:Test_unknown_method()
  helper.StartServer()
  helper.Initialize()
  var resp = helper.Request('workspace/nothing', {})
  assert_equal(-32601, resp.error.code)
  assert_match('workspace/nothing', resp.error.message)
  # A request for a document the server never saw is answered, not dropped.
  resp = helper.Request('textDocument/hover',
    helper.Params(0, 0, 'file:///nowhere.vim'))
  assert_equal(null, resp.result)
enddef

def g:Test_shutdown_exit()
  helper.StartServer()
  helper.Initialize()
  var resp = helper.Request('shutdown')
  assert_true(resp->has_key('result'))
  assert_equal(null, resp.result)
  helper.Notify('exit', null)
  assert_true(helper.WaitFor(() => job_status(helper.Job()) == 'dead'))
enddef

def g:Test_exit_when_client_goes()
  helper.StartServer()
  helper.Initialize()
  ch_close(helper.Job())
  assert_true(helper.WaitFor(() => job_status(helper.Job()) == 'dead'))
enddef

# vim: ts=2 sw=0 et
