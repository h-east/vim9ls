vim9script

import './helper.vim'
import './test_parse.vim' as samples

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
  assert_equal(1, caps.textDocumentSync)
  assert_true(caps.hoverProvider)
  assert_true(caps.documentSymbolProvider)
  assert_equal(['&', ':'], caps.completionProvider.triggerCharacters)
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
