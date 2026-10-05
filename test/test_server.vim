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

# The launcher a client other than Vim starts: the shell script, or the
# .cmd through cmd.exe on MS-Windows.
def g:Test_launcher()
  var launcher = fnamemodify(helper.HERE, ':h') .. '/bin/vim9ls'
  helper.StartServer(has('win32')
    ? ['cmd', '/c', tr(launcher, '/', '\') .. '.cmd'] : [launcher])
  var resp = helper.Initialize()
  assert_true(resp.result.capabilities.hoverProvider, string(helper.stderr))
enddef

def g:Test_initialize()
  helper.StartServer()
  var resp = helper.Initialize(['utf-8', 'utf-16'])
  var caps = resp.result.capabilities
  assert_equal('utf-8', caps.positionEncoding)
  assert_equal({openClose: true, change: 2, save: true}, caps.textDocumentSync)
  assert_true(caps.hoverProvider)
  assert_true(caps.documentSymbolProvider)
  assert_equal(['&', ':', '=', ',', ' ', '>'],
    caps.completionProvider.triggerCharacters)
  assert_equal(['(', ','], caps.signatureHelpProvider.triggerCharacters)
  assert_true(caps.inlayHintProvider)
  assert_equal('vim9ls', resp.result.serverInfo.name)
enddef

# The server takes the folders a client adds and removes, and serves the
# documents of each.
def g:Test_workspace_folders()
  helper.StartServer()
  var caps = helper.Initialize().result.capabilities
  assert_equal({supported: true, changeNotifications: true},
    caps.workspace.workspaceFolders)
  helper.Notify('workspace/didChangeWorkspaceFolders', {event: {
    added: [{uri: 'file:///tmp/Xvim9ls_two', name: 'Xvim9ls_two'}],
    removed: []}})
  for [uri, text] in [['file:///tmp/Xvim9ls_one/a.vim', 'endif'],
      ['file:///tmp/Xvim9ls_two/b.vim', 'endwhile']]
    helper.OpenDoc([text], uri)
    var note = helper.WaitNotification('textDocument/publishDiagnostics')
    assert_equal(uri, note.params.uri)
    assert_match(':' .. text .. ' without ',
      note.params.diagnostics->get(0, {message: ''}).message)
  endfor
  helper.Notify('workspace/didChangeWorkspaceFolders', {event: {added: [],
    removed: [{uri: 'file:///tmp/Xvim9ls_two', name: 'Xvim9ls_two'}]}})
  assert_equal([], helper.Request('textDocument/documentSymbol',
    {textDocument: {uri: 'file:///tmp/Xvim9ls_two/b.vim'}}).result)
enddef

# Asked for the diagnostics of a document, the server answers with what it
# sends, for the text as it is: what the checker reported on an earlier
# text is left out.
def g:Test_document_diagnostic()
  helper.StartServer()
  helper.Initialize()
  var text = ['vim9script', 'def F(): number', '  var left = 1',
    '  return "x"', 'enddef']
  var both = ['Unused variable: left',
    'E1012: Type mismatch; expected number but got string']
  helper.OpenDoc(text)
  assert_equal(both, helper.WaitNotification('textDocument/publishDiagnostics')
    .params.diagnostics->mapnew((_, d) => d.message))
  var Pulled = () => helper.Request('textDocument/diagnostic',
    {textDocument: {uri: helper.URI}}).result
  assert_equal('full', Pulled().kind)
  assert_equal(both, Pulled().items->mapnew((_, d) => d.message))

  helper.ChangeDoc(text + [''])
  assert_equal(['Unused variable: left'],
    Pulled().items->mapnew((_, d) => d.message))
  helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal(both, Pulled().items->mapnew((_, d) => d.message))

  assert_equal({kind: 'full', items: []},
    helper.Request('textDocument/diagnostic',
      {textDocument: {uri: 'file:///tmp/Xvim9ls_not_open.vim'}}).result)
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

# With $VIM9LS_LOG set the server logs in a file of its own in the
# temporary directory, and tells the client where.
def g:Test_log()
  var job = helper.StartServer()
  helper.Initialize()
  var file = $'{helper.LOG}/vim9ls_{job_info(job).process}.log'
  var msg = helper.WaitNotification('window/logMessage')
  assert_equal($'vim9ls: logging to "{file}"', msg.params.message)
  assert_true(getfsize(file) > 0, file)
enddef

# A log that cannot be opened is told once the client listens; the server
# goes on.
def g:Test_log_cannot_open()
  var tmp = helper.HERE .. '/Xnodir'
  var job = helper.StartServer(null_list, tmp)
  var resp = helper.Initialize()
  assert_true(resp.result.capabilities.hoverProvider, string(helper.stderr))
  var msg = helper.WaitNotification('window/showMessage')
  assert_equal(2, msg.params.type)
  var file = $'{tmp}/vim9ls_{job_info(job).process}.log'
  assert_match('^vim9ls: cannot open the log file "\V' .. escape(file, '\')
    .. '\m": E484:', msg.params.message)
  helper.OpenDoc(['vim9script', 'def F()', 'enddef'])
  resp = helper.Request('textDocument/documentSymbol',
    {textDocument: {uri: helper.URI}})
  assert_equal(['F'], resp.result->mapnew((_, s) => s.name))
enddef

# Without a channel the server reports the reason on stderr for the client.
def g:Test_no_channel()
  var err: list<string> = []
  var job = job_start([v:progpath, '--clean', '-es',
      '--cmd', 'set rtp^=' .. fnamemodify(helper.HERE, ':h'),
      '-c', 'call vim9ls#Start()', '-c', 'qall!'], {
    in_io: 'null',
    out_io: 'null',
    err_cb: (_, msg) => add(err, msg),
  })
  helper.WaitFor(() => job_status(job) != 'run')
  helper.WaitFor(() => ch_status(job) == 'closed')
  assert_notequal(0, job_info(job).exitval)
  assert_match('^vim9ls: E1582:', err->get(-1, ''), string(err))
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
  # "strlen" starts at byte 15 and at UTF-16 unit 13.
  var resp = helper.Request('textDocument/hover', helper.Params(0, 14))
  assert_match('^strlen', resp.result.contents.value)
  assert_equal(13, resp.result.range.start.character)
  assert_equal(19, resp.result.range.end.character)
enddef

# A name after a character of more than one byte is found where it is.
def g:Test_name_after_multibyte()
  var lines = [
    'vim9script',
    'var count = 1',
    "echo 'ああ' .. count",
    "echo 'ああ' .. cou",
  ]
  var at = stridx(lines[2], 'count')
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(lines)
  var resp = helper.Request('textDocument/definition', helper.Params(2, at + 1))
  assert_equal(1, resp.result[0].range.start.line)

  resp = helper.Request('textDocument/references', extend(
    helper.Params(1, 5), {context: {includeDeclaration: false}}))
  assert_equal([[2, at, at + 5]],
    resp.result->mapnew((_, l) => [l.range.start.line, l.range.start.character,
      l.range.end.character]))

  resp = helper.Request('textDocument/completion',
    helper.Params(3, strlen(lines[3])))
  assert_true(Labels(resp.result.items)->index('count') >= 0)
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

  # The help entry of a builtin comes with completionItem/resolve; an item
  # of the script comes back as it is.
  resp = helper.Request('textDocument/completion', helper.Params(4, 9))
  items = resp.result.items
  var strlen_item = items[Labels(items)->index('strlen')]
  assert_equal({tag: 'strlen()'}, strlen_item.data)
  resp = helper.Request('completionItem/resolve', strlen_item)
  assert_match('^strlen({string})', resp.result.detail)
  assert_equal('plaintext', resp.result.documentation.kind)
  assert_match('Return type: |Number|', resp.result.documentation.value)
  resp = helper.Request('textDocument/completion', helper.Params(6, 4))
  items = resp.result.items
  var own = items[Labels(items)->index('MyFunc')]
  assert_false(own->has_key('data'))
  resp = helper.Request('completionItem/resolve', own)
  assert_equal(own, resp.result)
  resp = helper.Request('textDocument/completion', helper.Params(5, 8))
  items = resp.result.items
  resp = helper.Request('completionItem/resolve',
    items[Labels(items)->index('textwidth')])
  assert_match("^'textwidth' 'tw'", resp.result.detail)
enddef

# In the argument of a command the client is asked to complete as Vim does
# on the command line, when it takes that; an expression is completed here.
def g:Test_completion_command_argument()
  var lines = [
    'vim9script',
    'set completeopt=',
    'set cot=menu|set fo=',
    'silent! hi Normal guifg=',
    'edit src/ma',
    'MyCommand ',
    'var x = ',
    'x = ',
    'echo a || b ',
    'throw ',
    'def F',
    'set ',
  ]
  helper.StartServer()
  helper.Initialize(['utf-8', 'utf-16'], {cmdlineCompletion: true})
  helper.OpenDoc(lines)

  var Complete = (lnum: number) =>
    helper.Request('textDocument/completion',
      helper.Params(lnum, strlen(lines[lnum]))).result
  for lnum in range(1, 5)
    assert_equal({isIncomplete: false, items: [], cmdlineCompletion: true},
      Complete(lnum), lines[lnum])
  endfor
  for lnum in range(6, 9)
    assert_false(Complete(lnum)->has_key('cmdlineCompletion'), lines[lnum])
    assert_true(Labels(Complete(lnum).items)->index('strlen') >= 0,
      lines[lnum])
  endfor
  assert_false(Complete(10)->has_key('cmdlineCompletion'), lines[10])
  assert_true(Labels(Complete(11).items)->index('completeopt') >= 0)

  # "=", "," and a space bring the menu on for the argument of a command, a
  # space for the name of an option as well, and nothing in an expression.
  var Triggered = (lnum: number, char: string) =>
    helper.Request('textDocument/completion',
      extend(helper.Params(lnum, strlen(lines[lnum])),
        {context: {triggerKind: 2, triggerCharacter: char}})).result
  assert_equal({isIncomplete: false, items: [], cmdlineCompletion: true},
    Triggered(1, '='))
  assert_equal({isIncomplete: false, items: []}, Triggered(6, '='))
  assert_equal({isIncomplete: false, items: []}, Triggered(6, ','))
  assert_equal({isIncomplete: false, items: [], cmdlineCompletion: true},
    Triggered(5, ' '))
  assert_true(Labels(Triggered(11, ' ').items)->index('completeopt') >= 0)
  assert_equal({isIncomplete: false, items: []}, Triggered(8, ' '))

  # A client that does not take it is given nothing there.
  helper.StopServer()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(lines)
  assert_equal({isIncomplete: false, items: []}, Complete(1))
enddef

# After "->": the functions that can take the value before it, and no other
# name.
def g:Test_completion_method()
  var lines = [
    'vim9script',
    'var text: string = "test string"',
    'var Ref: func(string): number = (s) => 1',
    'def MyFunc(s: string): string',
    '  return s',
    'enddef',
    'command MyCommand echo',
    'echo text->',
    'echo text->sp',
    'echo text > ',
    'def NoArg()',
    'enddef',
    'function Legacy(...)',
    'endfunction',
  ]
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(lines)

  var Triggered = (lnum: number) =>
    helper.Request('textDocument/completion',
      extend(helper.Params(lnum, strlen(lines[lnum])),
        {context: {triggerKind: 2, triggerCharacter: '>'}})).result
  var labels = Labels(Triggered(7).items)
  assert_true(labels->index('len') >= 0)
  assert_true(labels->index('MyFunc') >= 0)
  assert_true(labels->index('Ref') >= 0)
  assert_true(labels->index('Legacy') >= 0)
  assert_equal(-1, labels->index('text'))
  assert_equal(-1, labels->index('MyCommand'))
  assert_equal(-1, labels->index('argc'))
  assert_equal(-1, labels->index('NoArg'))

  labels = Labels(helper.Request('textDocument/completion',
    helper.Params(8, strlen(lines[8]))).result.items)
  assert_true(labels->index('split') >= 0)
  assert_equal([], labels->copy()->filter((_, l) => l !~ '^sp'))

  # A ">" that is not part of "->" gives nothing.
  assert_equal({isIncomplete: false, items: []},
    helper.Request('textDocument/completion',
      extend(helper.Params(9, strlen(lines[9]) - 1),
        {context: {triggerKind: 2, triggerCharacter: '>'}})).result)
enddef

# After "alias.", "foo#bar#", "this.", "var." and "Class.": what is there,
# and nothing else.
def g:Test_completion_members()
  var root = helper.HERE .. '/Xproj'
  mkdir(root .. '/autoload/xold', 'p')
  mkdir(root .. '/plugin', 'p')
  writefile(['vim9script', 'export def Greet(): string', "  return 'hi'",
    'enddef', 'def Hidden()', 'enddef', 'export var greeting = 1'],
    root .. '/autoload/xlib.vim')
  writefile(['function xold#Func()', 'endfunction', 'function xold#Other()',
    'endfunction'], root .. '/autoload/xold.vim')
  writefile(['vim9script'], root .. '/autoload/xold/sub.vim')
  var main = root .. '/plugin/xmain.vim'
  var uri = util.PathToUri(main)
  try
    helper.StartServer()
    helper.Initialize()
    helper.OpenDoc([
      'vim9script',
      "import autoload 'xlib.vim' as lib",
      'echo lib.Gr',
      'echo lib.',
      'call xold#F',
      'class Shape',
      '  var width: number',
      '  def Area(): number',
      '    return this.',
      '  enddef',
      'endclass',
      'var s: Shape = Shape.new()',
      'echo s.',
      'var t = Shape.new()',
      'echo t.',
      'echo Shape.',
      'enum Color',
      '  Red,',
      '  Blue',
      'endenum',
      'echo Color.',
      'echo strlen.',
    ], uri)
    var Items = (line: number, col: number) => helper.Request(
      'textDocument/completion', helper.Params(line, col, uri)).result.items
    var Names = (line: number, col: number) => Items(line, col)
      ->mapnew((_, i) => i.label)->sort()
    assert_equal(['Greet'], Names(2, 11))
    assert_equal(['Greet', 'greeting'], Names(3, 9))
    assert_equal(['xold#Func'], Names(4, 11))
    assert_equal({range: {start: {line: 4, character: 5},
      end: {line: 4, character: 11}}, newText: 'xold#Func'},
      Items(4, 11)[0].textEdit)
    assert_equal(['xold#Func', 'xold#Other', 'xold#sub#'], Names(4, 10))
    assert_equal(['Area', 'width'], Names(8, 16))
    assert_equal(['Area', 'width'], Names(12, 7))
    assert_equal(['Area', 'width'], Names(14, 7))
    assert_equal(['Area', 'width'], Names(15, 11))
    assert_equal(['Blue', 'Red'], Names(20, 11))
    assert_equal([], Names(21, 12))
  finally
    delete(root, 'rf')
  endtry
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

def g:Test_type_definition()
  var root = helper.HERE .. '/Xproj'
  mkdir(root .. '/plugin', 'p')
  writefile(['vim9script', 'export class Color', '  var name: string',
    'endclass'], root .. '/plugin/xcolor.vim')
  var uri = util.PathToUri(root .. '/plugin/xmain.vim')
  try
    helper.StartServer()
    helper.Initialize()
    helper.OpenDoc([
      'vim9script',                       # 0
      "import './xcolor.vim' as xcolor",  # 1
      'class Shape',                      # 2
      '  var name: string',               # 3
      'endclass',                         # 4
      'interface Drawable',               # 5
      '  def Draw(): void',               # 6
      'endinterface',                     # 7
      'def Use()',                        # 8
      '  var declared: Shape',            # 9
      '  var inferred = Shape.new()',     # 10
      '  var many: list<Shape>',          # 11
      '  var other: xcolor.Color',        # 12
      '  var plain: string',              # 13
      '  var drawn: Drawable',            # 14
      '  echo declared',                  # 15
      '  echo inferred',                  # 16
      '  echo many',                      # 17
      '  echo other',                     # 18
      '  echo plain',                     # 19
      '  echo drawn',                     # 20
      'enddef',                           # 21
      'var top = Shape.new()',            # 22
      'echo top',                         # 23
    ], uri)
    var Ask = (line: number, character: number) => helper.Request(
      'textDocument/typeDefinition',
      helper.Params(line, character, uri)).result

    # A declared type, a type the initializer tells, and one inside a list.
    for lnum in [15, 16, 17]
      var got = Ask(lnum, 7)
      assert_equal(uri, got[0].uri, 'line ' .. lnum)
      assert_equal({start: {line: 2, character: 6},
        end: {line: 2, character: 11}}, got[0].range, 'line ' .. lnum)
    endfor

    # A type of another script, through the alias of the import.
    var other = Ask(18, 7)
    assert_equal(util.PathToUri(root .. '/plugin/xcolor.vim'), other[0].uri)
    assert_equal(1, other[0].range.start.line)

    # An interface is a type of its own, and so is a class: the name of one
    # leads to the line it is on.
    assert_equal(5, Ask(20, 7)[0].range.start.line)
    assert_equal(2, Ask(10, 17)[0].range.start.line)

    # A type of Vim's own has nothing to go to.
    assert_equal(null, Ask(19, 7))

    # A variable of the script, from its declaration and from a use.
    assert_equal(2, Ask(22, 5)[0].range.start.line)
    assert_equal(2, Ask(23, 6)[0].range.start.line)
  finally
    delete(root, 'rf')
  endtry
enddef

def g:Test_implementation()
  var root = helper.HERE .. '/Xproj'
  mkdir(root .. '/plugin', 'p')
  writefile(['vim9script', "import './xmain.vim' as xmain",
    'class Square implements xmain.Drawable', '  def Draw(): void',
    '  enddef', 'endclass'], root .. '/plugin/xother.vim')
  var uri = util.PathToUri(root .. '/plugin/xmain.vim')
  try
    helper.StartServer()
    helper.Initialize()
    helper.OpenDoc([
      'vim9script',                      # 0
      'export interface Drawable',       # 1
      '  def Draw(): void',              # 2
      'endinterface',                    # 3
      'abstract class Base',             # 4
      '  abstract def Area(): number',   # 5
      'endclass',                        # 6
      'class Circle implements Drawable',  # 7
      '  def Draw(): void',              # 8
      '  enddef',                        # 9
      'endclass',                        # 10
      'class Box extends Base',          # 11
      '  def Area(): number',            # 12
      '    return 0',                    # 13
      '  enddef',                        # 14
      'endclass',                        # 15
    ], uri)
    var Ask = (line: number, character: number) => helper.Request(
      'textDocument/implementation',
      helper.Params(line, character, uri)).result

    # The interface: the classes that implement it, here and in the other
    # script, which names it through the alias of its import.
    var got = Ask(1, 17)
    assert_equal([[uri, 7], [util.PathToUri(root .. '/plugin/xother.vim'), 2]],
      got->mapnew((_, l) => [l.uri, l.range.start.line])->sort())
    # The method of the interface: the method of each class.
    assert_equal([8, 3], Ask(2, 6)
      ->mapnew((_, l) => l.range.start.line))

    # A class that is extended, and the abstract method in it.
    assert_equal([[uri, 11]], Ask(4, 15)
      ->mapnew((_, l) => [l.uri, l.range.start.line]))
    assert_equal([[uri, 12]], Ask(5, 15)
      ->mapnew((_, l) => [l.uri, l.range.start.line]))

    # Nothing implements a class nothing extends.
    assert_equal(null, Ask(7, 6))
  finally
    delete(root, 'rf')
  endtry
enddef

def g:Test_type_hierarchy()
  var root = helper.HERE .. '/Xproj'
  mkdir(root .. '/plugin', 'p')
  writefile(['vim9script', "import './xmain.vim' as xmain",
    'class Square extends xmain.Shape', 'endclass'],
    root .. '/plugin/xother.vim')
  var main = root .. '/plugin/xmain.vim'
  var uri = util.PathToUri(main)
  try
    helper.StartServer()
    helper.Initialize()
    # The other script imports this one, so it has to be on disk as well.
    var lines = [
      'vim9script',                       # 0
      'export interface Drawable',        # 1
      '  def Draw(): void',               # 2
      'endinterface',                     # 3
      'interface Solid extends Drawable', # 4
      'endinterface',                     # 5
      'export class Shape implements Drawable',  # 6
      '  def Draw(): void',               # 7
      '  enddef',                         # 8
      'endclass',                         # 9
      'enum Color implements Drawable',   # 10
      '  Red',                            # 11
      '  def Draw(): void',               # 12
      '  enddef',                         # 13
      'endenum',                          # 14
      'def Plain()',                      # 15
      'enddef',                           # 16
    ]
    writefile(lines, main)
    helper.OpenDoc(lines, uri)
    var Prepare = (line: number, character: number) => helper.Request(
      'textDocument/prepareTypeHierarchy',
      helper.Params(line, character, uri)).result

    # A class, an interface and an enum start a hierarchy; a function does
    # not.
    var items = Prepare(6, 13)
    assert_equal(['Shape'], items->mapnew((_, i) => i.name))
    assert_equal(5, items[0].kind)
    assert_equal({line: 6, character: 13}, items[0].selectionRange.start)
    assert_equal(null, Prepare(15, 4))

    # What it implements, through the alias of an import as well.
    var supers = helper.Request('typeHierarchy/supertypes',
      {item: items[0]}).result
    assert_equal(['Drawable'], supers->mapnew((_, i) => i.name))
    assert_equal(1, supers[0].range.start.line)

    # An interface that extends one, and an enum that implements it, are
    # both below it.
    var drawable = Prepare(1, 17)[0]
    var subs = helper.Request('typeHierarchy/subtypes',
      {item: drawable}).result
    assert_equal([['Solid', uri], ['Shape', uri], ['Color', uri]],
      subs->mapnew((_, i) => [i.name, i.uri]))

    # A class of another script, which names this one through its import.
    var shape_subs = helper.Request('typeHierarchy/subtypes',
      {item: items[0]}).result
    assert_equal(['Square'], shape_subs->mapnew((_, i) => i.name))
    assert_equal(util.PathToUri(root .. '/plugin/xother.vim'),
      shape_subs[0].uri)

    # Nothing is below an enum, and the item comes back from a file that is
    # not open.
    var square = shape_subs[0]
    assert_equal(null, helper.Request('typeHierarchy/subtypes',
      {item: square}).result)
    var square_supers = helper.Request('typeHierarchy/supertypes',
      {item: square}).result
    assert_equal(['Shape'], square_supers->mapnew((_, i) => i.name))
  finally
    delete(root, 'rf')
  endtry
enddef

def g:Test_formatting()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',            # 0
    'def F(): number',       # 1
    'if true',               # 2
    'var x = 1   ',          # 3, with blanks at the end
    'endif',                 # 4
    'return 0',              # 5
    'enddef',                # 6
  ])
  var Ask = (method: string, params: dict<any>) => helper.Request(method,
    extend({textDocument: {uri: helper.URI}}, params)).result

  # Two spaces of indent, and a line that is already right is left alone.
  var edits = Ask('textDocument/formatting',
    {options: {tabSize: 2, insertSpaces: true}})
  assert_equal([[2, '  if true'], [3, '    var x = 1   '],
    [4, '  endif'], [5, '  return 0']],
    edits->mapnew((_, e) => [e.range.start.line, e.newText]))
  assert_equal({line: 2, character: 0}, edits[0].range.start)
  assert_equal({line: 2, character: 7}, edits[0].range.end)

  # A tab of indent, and the blanks at the end taken off where it was asked
  # for.
  edits = Ask('textDocument/formatting',
    {options: {tabSize: 4, insertSpaces: false,
      trimTrailingWhitespace: true}})
  assert_equal([[2, "\tif true"], [3, "\t\tvar x = 1"],
    [4, "\tendif"], [5, "\treturn 0"]],
    edits->mapnew((_, e) => [e.range.start.line, e.newText]))

  # A range takes whole lines, and leaves the rest of the document alone.
  edits = Ask('textDocument/rangeFormatting',
    {options: {tabSize: 2, insertSpaces: true},
      range: {start: {line: 2, character: 0}, end: {line: 3, character: 5}}})
  assert_equal([[2, '  if true'], [3, '    var x = 1   ']],
    edits->mapnew((_, e) => [e.range.start.line, e.newText]))
enddef

# The newline at the end of a document is the empty line after the last one.
def g:Test_formatting_final_newlines()
  helper.StartServer()
  helper.Initialize()
  var Format = (options: dict<any>) => helper.Request(
    'textDocument/formatting',
    {textDocument: {uri: helper.URI}, options: options}).result

  # Three newlines at the end, of which two are taken away.
  helper.Notify('textDocument/didOpen', {textDocument: {uri: helper.URI,
    languageId: 'vim', version: 1, text: "vim9script\necho 1\n\n\n"}})
  var edits = Format({tabSize: 2, insertSpaces: true,
    trimFinalNewlines: true})
  assert_equal(1, len(edits))
  assert_equal('', edits[0].newText)
  assert_equal({line: 2, character: 0}, edits[0].range.start)
  assert_equal({line: 4, character: 0}, edits[0].range.end)

  # None at the end, and one is put there.
  helper.Notify('textDocument/didOpen', {textDocument: {uri: helper.URI,
    languageId: 'vim', version: 2, text: "vim9script\necho 1"}})
  edits = Format({tabSize: 2, insertSpaces: true, insertFinalNewline: true})
  assert_equal(1, len(edits))
  assert_equal("\n", edits[0].newText)
  assert_equal({line: 1, character: 6}, edits[0].range.start)
  assert_equal(edits[0].range.start, edits[0].range.end)

  # Neither asked for, so the end is left as it is.
  assert_equal([], Format({tabSize: 2, insertSpaces: true}))
enddef

def g:Test_folding_range()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',            # 0
    "import './one.vim'",    # 1
    "import './two.vim'",    # 2
    '',                      # 3
    '# What the next one is',  # 4
    '# for, on two lines',   # 5
    'def Outer(): number',   # 6
    '  if true',             # 7
    '    echo 1',            # 8
    '  endif',               # 9
    '  return 0',            # 10
    'enddef',                # 11
    '',                      # 12
    'class Shape',           # 13
    '  def Area(): number',  # 14
    '    return 0',          # 15
    '  enddef',              # 16
    'endclass',              # 17
    'def Unclosed()',        # 18
  ])
  var ranges = helper.Request('textDocument/foldingRange',
    {textDocument: {uri: helper.URI}}).result
  assert_equal([
    {startLine: 1, endLine: 2, kind: 'imports'},
    {startLine: 4, endLine: 5, kind: 'comment'},
    {startLine: 6, endLine: 11},
    {startLine: 7, endLine: 9},
    {startLine: 13, endLine: 17},
    {startLine: 14, endLine: 16},
    # A function that is never closed reaches the end of the document.
    {startLine: 18, endLine: 19},
  ], ranges)
enddef

# The chain of ranges at one position, innermost first, each as the lines
# and characters it runs between.
def Chain(lnum: number, character: number): list<list<number>>
  var chains = helper.Request('textDocument/selectionRange',
    {textDocument: {uri: helper.URI},
      positions: [{line: lnum, character: character}]}).result
  var out: list<list<number>> = []
  var item = chains[0]
  while true
    add(out, [item.range.start.line, item.range.start.character,
      item.range.end.line, item.range.end.character])
    if !item->has_key('parent')
      break
    endif
    item = item.parent
  endwhile
  return out
enddef

def g:Test_selection_range()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',                  # 0
    'def Foo()',                   # 1
    '  if cond',                   # 2
    "    echo Bar(x, 'baz qux')",  # 3
    '    echo 2',                  # 4
    '  endif',                     # 5
    'enddef',                      # 6
    'var list = [',                # 7
    '  1,',                        # 8
    '  2,',                        # 9
    '  ]',                         # 10
    'nnoremap [c [czz',            # 11
    'echo 1',                      # 12
    'autocmd User X {',            # 13
    '  echo 2',                    # 14
    '}',                           # 15
    'if cond',                     # 16
    '  echo 3',                    # 17
    '  echo 4',                    # 18
    'else',                        # 19
    '  echo 5',                    # 20
    'endif',                       # 21
  ])
  assert_equal([
    [3, 21, 3, 24],   # qux
    [3, 17, 3, 24],   # baz qux
    [3, 16, 3, 25],   # 'baz qux'
    [3, 13, 3, 25],   # x, 'baz qux'
    [3, 12, 3, 26],   # (x, 'baz qux')
    [3, 9, 3, 26],    # Bar(x, 'baz qux')
    [3, 4, 3, 26],    # the statement
    [3, 4, 4, 10],    # the body of the "if"
    [2, 2, 5, 7],     # if ~ endif
    [1, 0, 6, 6],     # def ~ enddef
    [0, 0, 22, 0],    # the document
  ], Chain(3, 21))

  # A statement that carries on over lines is one step.
  assert_equal([
    [8, 2, 8, 3],
    [8, 2, 9, 4],     # what the brackets hold, without the blanks
    [7, 11, 10, 3],
    [7, 0, 10, 3],
    [0, 0, 22, 0],
  ], Chain(8, 2))

  # The "[" of a mapping opens nothing, so the line below it is a statement
  # of its own and not the tail of one that never ends.
  assert_equal([
    [12, 5, 12, 6],
    [12, 0, 12, 6],
    [0, 0, 22, 0],
  ], Chain(12, 5))

  # The name of a call leads to the call, although the cursor stands in
  # front of the brackets rather than inside them.
  assert_equal([3, 9, 3, 26], Chain(3, 9)[1])

  # The lines of a block end where they will, and the "{" of its header
  # still finds the "}".
  assert_equal([
    [14, 2, 14, 6],
    [14, 2, 14, 8],   # the statement, and what the block holds
    [13, 15, 15, 1],  # { ... }
    [13, 0, 15, 1],   # the block with its header
    [0, 0, 22, 0],
  ], Chain(14, 2))

  # What a block holds is the branch the position is in, not the lines of
  # the other one.
  assert_equal([
    [17, 2, 17, 6],
    [17, 2, 17, 8],
    [17, 2, 18, 8],   # up to the ":else", which is not part of it
    [16, 0, 21, 5],
    [0, 0, 22, 0],
  ], Chain(17, 2))

  # One chain for each position asked about.
  var chains = helper.Request('textDocument/selectionRange',
    {textDocument: {uri: helper.URI},
      positions: [{line: 3, character: 21}, {line: 8, character: 2}]}).result
  assert_equal(2, len(chains))
  assert_equal({line: 3, character: 21}, chains[0].range.start)
  assert_equal({line: 8, character: 2}, chains[1].range.start)
enddef

def g:Test_workspace_symbol()
  var root = helper.HERE .. '/Xproj'
  mkdir(root .. '/autoload', 'p')
  mkdir(root .. '/plugin', 'p')
  writefile(['vim9script', 'export def XprojGreet(): string',
    "  return 'hi'", 'enddef', 'export const XPROJ_LIMIT = 3'],
    root .. '/autoload/xlib.vim')
  writefile(['vim9script', 'class XprojShape', '  var name: string',
    '  def XprojArea(): number', '    return 0', '  enddef', 'endclass'],
    root .. '/plugin/xclass.vim')
  var uri = util.PathToUri(root .. '/plugin/xmain.vim')
  try
    helper.StartServer()
    helper.Initialize()
    helper.OpenDoc(['vim9script', 'def XprojRun()', 'enddef'], uri)

    # The query is matched without regard to case, in the files of the
    # plugin the open document belongs to as well as in the document.
    var found = helper.Request('workspace/symbol', {query: 'xprojg'}).result
    assert_equal(['XprojGreet'], found->mapnew((_, s) => s.name))
    assert_equal(util.PathToUri(root .. '/autoload/xlib.vim'),
      found[0].location.uri)
    assert_equal({start: {line: 1, character: 11},
      end: {line: 1, character: 21}}, found[0].location.range)

    found = helper.Request('workspace/symbol', {query: 'xproj'}).result
    assert_equal(['XPROJ_LIMIT', 'XprojArea', 'XprojGreet', 'XprojRun',
      'XprojShape'], sort(found->mapnew((_, s) => s.name)))
    # A method carries the class it is in.
    var area = found->copy()->filter((_, s) => s.name == 'XprojArea')[0]
    assert_equal('XprojShape', area.containerName)
    assert_equal(6, area.kind)
    assert_false(found->copy()
      ->filter((_, s) => s.name == 'XprojGreet')[0]->has_key('containerName'))

    # An empty query is answered with the open documents alone.
    found = helper.Request('workspace/symbol', {query: ''}).result
    assert_equal(['XprojRun'], found->mapnew((_, s) => s.name))
    assert_equal(uri, found[0].location.uri)
  finally
    delete(root, 'rf')
  endtry
enddef

# A quick fix for each of the three things the parser reports.
def g:Test_inlay_hint()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'var n = 1',
    'var s: string = "x"',
    'def F(a: list<number>): string',
    "  var first = a[0] .. s",
    '  return first',
    'enddef',
    'var l = [n]',
    'echo F(l)->strpart(n, 2)',
    'echo strlen(s) + repeat(s, n)',
  ])
  var Ask = (first: number, last: number) => helper.Request(
    'textDocument/inlayHint', {textDocument: {uri: helper.URI},
      range: {start: {line: first, character: 0},
        end: {line: last, character: 0}}}).result
  # The argument of strlen() is named after its type, "{string}", and gets
  # no hint.
  assert_equal([
    [{line: 1, character: 5}, ': number', 1, false],
    [{line: 4, character: 11}, ': string', 1, false],
    [{line: 7, character: 5}, ': list<number>', 1, false],
    [{line: 8, character: 7}, 'a:', 2, true],
    [{line: 8, character: 19}, 'start:', 2, true],
    [{line: 8, character: 22}, 'len:', 2, true],
    [{line: 9, character: 24}, 'expr:', 2, true],
    [{line: 9, character: 27}, 'count:', 2, true],
  ], Ask(0, 10)->mapnew((_, h) => [h.position, h.label, h.kind,
    h.paddingRight]))
  assert_equal([4], Ask(3, 6)->mapnew((_, h) => h.position.line))
  assert_equal([], Ask(2, 3))
enddef

# A parameter that is not used can be named "_"; a variable that is not used
# has no fix, taking its declaration away may drop what its value does.
def g:Test_code_action_unused_parameter()
  helper.StartServer()
  helper.Initialize()
  var text = ['vim9script', 'def F(used: number, unused: string = "a")',
    '  var left = used', 'enddef']
  helper.OpenDoc(text)
  var published = helper.WaitNotification('textDocument/publishDiagnostics')
    .params.diagnostics
  var actions = helper.Request('textDocument/codeAction',
    {textDocument: {uri: helper.URI}, range: {start: {line: 0, character: 0},
      end: {line: 3, character: 0}}, context: {diagnostics: published}}).result
  assert_equal(['Name the parameter "_"'], actions->mapnew((_, a) => a.title))
  assert_equal({range: {start: {line: 1, character: 20},
    end: {line: 1, character: 26}}, newText: '_'},
    actions[0].edit.changes[helper.URI][0])

  # Not when the name there is no longer the one reported.
  helper.ChangeDoc(['vim9script', 'def F(used: number, other: string = "a")',
    '  var left = used', 'enddef'])
  assert_equal([], helper.Request('textDocument/codeAction',
    {textDocument: {uri: helper.URI}, range: {start: {line: 0, character: 0},
      end: {line: 3, character: 0}}, context: {diagnostics: published}}).result)
enddef

def g:Test_code_action()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'let x = 1',
    'let x = 2',
    'let g:y = 3',
    'def F()',
    '  if x',
    '    echo x',
    'enddef',
  ])
  # A client sends back the diagnostics it has on the lines asked about,
  # those of the parser and those Vim reported alike.
  var published = helper.WaitNotification('textDocument/publishDiagnostics')
    .params.diagnostics
  var Ask = (first: number, last: number) => helper.Request(
    'textDocument/codeAction', {textDocument: {uri: helper.URI},
      range: {start: {line: first, character: 0},
        end: {line: last, character: 0}},
      context: {diagnostics: published->copy()->filter((_, d) =>
        d.range.start.line >= first && d.range.start.line <= last)}}).result
  var actions = Ask(0, 8)
  assert_equal([
    [1, 'Replace :let with :var'],
    [2, 'Drop :let, the variable is there'],
    [3, 'Drop :let, the variable is there'],
    [4, 'Insert enddef'],
    [5, 'Insert endif'],
    [7, 'Remove the enddef without a start'],
  ], actions->mapnew((_, a) => [a.diagnostics[0].range.start.line, a.title])
    ->sort((a, b) => a[0] - b[0]))
  assert_equal('quickfix', actions[0].kind)
  var Edit = (title: string) => actions[actions->indexof(
    (_, a) => a.title == title)].edit.changes[helper.URI][0]
  assert_equal({range: {start: {line: 1, character: 0},
    end: {line: 1, character: 3}}, newText: 'var'},
    Edit('Replace :let with :var'))
  assert_equal({range: {start: {line: 2, character: 0},
    end: {line: 2, character: 4}}, newText: ''},
    Edit('Drop :let, the variable is there'))
  assert_equal({range: {start: {line: 7, character: 0},
    end: {line: 7, character: 0}}, newText: "  endif\n"},
    Edit('Insert endif'))
  assert_equal({range: {start: {line: 7, character: 0},
    end: {line: 8, character: 0}}, newText: ''},
    Edit('Remove the enddef without a start'))
  # Only the diagnostics in the range asked about.
  assert_equal(['Replace :let with :var'],
    Ask(1, 1)->mapnew((_, a) => a.title))
  # Nothing without the diagnostics.
  assert_equal([], helper.Request('textDocument/codeAction',
    {textDocument: {uri: helper.URI}, range: {start: {line: 0, character: 0},
      end: {line: 8, character: 0}}, context: {diagnostics: []}}).result)

  # Vim reports the missing endif where the block stops; only the parser's,
  # on the "if", has a fix.  An endif Vim reports twice has one.
  helper.ChangeDoc(['vim9script', 'if 1', '  echo 1', 'endif', 'endif'])
  published = helper.WaitNotification('textDocument/publishDiagnostics')
    .params.diagnostics
  assert_equal([[4, 'Remove the endif without a start']],
    Ask(0, 4)->mapnew((_, a) => [a.diagnostics[0].range.start.line, a.title]))
  helper.ChangeDoc(['vim9script', 'if 1', '  echo 1'], helper.URI, 3)
  published = helper.WaitNotification('textDocument/publishDiagnostics')
    .params.diagnostics
  assert_true(published->indexof((_, d) => d.range.start.line > 1
    && d.message =~ 'E171:') >= 0, string(published))
  assert_equal([[1, 'Insert endif']],
    Ask(0, 2)->mapnew((_, a) => [a.diagnostics[0].range.start.line, a.title]))
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

  # A call of a function that nothing defines.
  helper.ChangeDoc(['call s:Nope()', 'call nosuch()', 'echo v:nosuch'],
    helper.URI, 3)
  note = helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal([
    [0, 'E117: Unknown function: s:Nope'],
    [1, 'E117: Unknown function: nosuch'],
    [2, 'E121: Undefined variable: v:nosuch'],
  ], note.params.diagnostics->mapnew((_, d) => [d.range.start.line, d.message]))
  assert_equal({start: {line: 0, character: 5}, end: {line: 0, character: 11}},
    note.params.diagnostics[0].range)
enddef

# The diagnostics after "lines" replaced the document: [line, message] of
# each, in the order of the lines.
def After(lines: list<string>, version: number): list<list<any>>
  helper.ChangeDoc(lines, helper.URI, version)
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
    'echo undefined_name',
  ])
  # What Vim reports comes with the first diagnostics, no save needed.
  var note = helper.WaitNotification('textDocument/publishDiagnostics')
  var diags = note.params.diagnostics
  assert_equal([
    [2, 'E1012: Type mismatch; expected number but got string'],
    [6, 'E1012: Type mismatch; expected number but got string'],
    [10, 'E1001: Variable not found: undefined_name'],
  ], diags->mapnew((_, d) => [d.range.start.line, d.message]))
  assert_equal(1, diags[0].severity)
  assert_equal('vim9ls', diags[0].source)
  assert_equal({start: {line: 2, character: 0}, end: {line: 2, character: 12}},
    diags[0].range)

  # Fixed: nothing is left, and what the parser reports is not doubled.
  assert_equal([[1, 'E1126: Cannot use :let in Vim9 script']],
    After(['vim9script', 'let x = 1', 'def Fine(): number', '  return 1',
      'enddef'], 2))
  # Nor ":let" after "legacy", which Vim accepts.
  assert_equal([], After(['vim9script', 'legacy let $X = 1', 'def Fine()',
    '  legacy let x = 1', 'enddef'], 3))

  # A "const" is left alone, what comes after "finish" is read as well, and
  # every line with an error is reported, in a function and at the script
  # level.
  assert_equal([
    [1, 'E1012: Type mismatch; expected number but got string'],
    [4, 'E1012: Type mismatch; expected number but got string'],
    [6, 'Unused variable: s'],
    [6, 'E1012: Type mismatch; expected string but got number'],
    [7, 'E1001: Variable not found: undefined_name'],
  ], After(['vim9script', 'var n: number = "t"', 'const LIMIT = 10', 'finish',
      'var m: number = "s"', 'def Two(): number', '  var s: string = 1',
      '  echo undefined_name', '  return 1', 'enddef'], 3))

  # A user command the dry run cannot know and a variable declared inside a
  # block are no errors.
  assert_equal([], After(['vim9script', "Plug 'x/y'", 'command! Log echo 1',
    'Log', "if has('iconv')", "  var enc = 'euc-jp'", "  enc = 'eucjp-ms'",
    'endif'], 8))
  # Nor is one in a function, while a builtin command spelled wrong is.
  assert_equal([[3, 'E476: Invalid command: echoo 1']],
    After(['vim9script', 'def F()', '  LspHover', '  echoo 1', 'enddef'], 9))
  # Nor is one in a lambda in a list, and the lines after it are not taken
  # for commands.
  assert_equal([], After(['vim9script', 'g:dir_actions = [',
    "  {text: 'a', Action: (items) => {", '    :Dir', '  }},',
    "  {text: 'b', Action: (items) => {", '    # mess clear', '  }},', ']'],
    13))
  # An assignment to a capitalized name that is not declared is an error.
  assert_equal([[1, 'E476: Invalid command: Undeclared = 1'],
    [3, 'E476: Invalid command: Inside = 1']],
    After(['vim9script', 'Undeclared = 1', 'def F()', '  Inside = 1',
      'enddef'], 14))
  # So is a name that cannot be a user command.
  assert_equal([[2, 'E476: Invalid command: Foo_bar']],
    After(['vim9script', 'def F()', '  Foo_bar', 'enddef'], 15))
  # A continuation line in the first column, which a function would take
  # for an error.
  assert_equal([], After(['vim9script', "&l:define = 'a'",
    "..          'b'"], 12))
  # An error Vim reports twice, once with the command added, is there once,
  # as is one the parser reports too.
  assert_equal([[4, 'E580: :endif without :if']],
    After(['vim9script', 'if 1', '  echo 1', 'endif', 'endif'], 10))
  assert_equal([[0, 'E580: :endif without :if']], After(['endif'], 11))
  # A legacy script defines its functions and nothing is compiled.
  assert_equal([], After(['function Legacy()', '  return undefined_a',
    'endfunction', 'echo undefined_b'], 4))

  # Nothing runs: not a shell command, and not a command that would end
  # the checker, which is still there for the next change.
  assert_equal([], After(['vim9script', 'echo system("echo x")', 'qall!'],
    5))
  assert_equal([[1, 'E1012: Type mismatch; expected number but got string']],
    After(['vim9script', 'var n: number = "s"'], 6))

  # An error in a method is put on its line, and a static method is called
  # by its bare name inside the class.
  assert_equal([[8, 'E117: Unknown function: _Helper'],
    [9, 'Unused variable: n']],
    After(['vim9script', 'class C', '  def _Helper()', '  enddef',
      '  static def S(): number', '    return 1', '  enddef', '  def Run()',
      '    _Helper()', '    var n = S()', '  enddef', 'endclass'], 7))

  # Vim names a file under the home directory with "~"; the lines are
  # still the file's.
  var home = 'file://' .. $HOME .. '/Xvim9ls_home_test.vim'
  helper.OpenDoc(['vim9script', 'def Broken(): number', '  return "x"',
    'enddef', 'echo undefined_name'], home)
  note = helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal(home, note.params.uri)
  assert_equal([
    [2, 'E1012: Type mismatch; expected number but got string'],
    [4, 'E1001: Variable not found: undefined_name'],
  ], note.params.diagnostics->mapnew((_, d) => [d.range.start.line, d.message]))

  # A class in an autoload script is defined again at every check; Vim only
  # refuses that outside a dry run.
  var root = helper.HERE .. '/Xproj'
  mkdir(root .. '/autoload', 'p')
  var cls = util.PathToUri(root .. '/autoload/xshape.vim')
  try
    var text = ['vim9script', 'export class Shape', '  const width = 1',
      '  def Area(): number', '    return this.width', '  enddef', 'endclass']
    helper.OpenDoc(text, cls)
    note = helper.WaitNotification('textDocument/publishDiagnostics')
    assert_equal([], note.params.diagnostics)
    helper.ChangeDoc(text + [''], cls, 2)
    note = helper.WaitNotification('textDocument/publishDiagnostics')
    assert_equal([], note.params.diagnostics)
  finally
    delete(root, 'rf')
  endtry

  # The checker's own script is running in the checker; reading it must
  # not try to define its functions again.
  var checker = fnamemodify(helper.SERVER, ':h') .. '/vim9ls/checker.vim'
  helper.OpenDoc(readfile(checker), util.PathToUri(checker))
  note = helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal([], note.params.diagnostics)
enddef

# A variable of a block at the script level may have the name of a script
# variable declared further on, as Vim reads the script in order; one
# declared before is still reported.
def g:Test_compile_block_variable_declared_later()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'if true',
    '  var later: list<string> = []',
    '  later = ["a"]',
    'endif',
    'var later: list<string> = ["b"]',
    'var before = 1',
    'if true',
    '  var before = 2',
    'endif',
  ])
  var diags = helper.WaitNotification('textDocument/publishDiagnostics')
    .params.diagnostics->filter((_, d) => d.message =~ '^E1054')
  assert_equal([[8, 'E1054: Variable already declared in the script: before']],
    diags->mapnew((_, d) => [d.range.start.line, d.message]))
  helper.StopServer()
enddef

# A declaration in a lambda at the script level stays a declaration of the
# lambda, the dry run declaring no script variable for it, and the script
# level is still checked.
def g:Test_compile_declaration_in_lambda()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'var names = ["a", "b"]',
    'range(1, 2)->foreach((_, n) => {',
    '  var joined = names->mapnew((_, s) => s .. n)->join()',
    '  echo joined',
    '})',
    'var count: number = "x"',
  ])
  var diags = helper.WaitNotification('textDocument/publishDiagnostics')
    .params.diagnostics->filter((_, d) => d.message =~ '^E')
  assert_equal([[6, 'E1012: Type mismatch; expected number but got string']],
    diags->mapnew((_, d) => [d.range.start.line, d.message]))
  helper.StopServer()
enddef

# A global function of a script checked before is gone when the next one is
# checked: a class of the same name is not reported as E1041.
def g:Test_compile_global_function_of_another_script()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(['def Xglobal()', 'enddef'], 'file:///tmp/Xvim9ls_global.vim')
  helper.WaitNotification('textDocument/publishDiagnostics')
  helper.OpenDoc(['vim9script', 'class Xglobal', 'endclass'])
  var diags = helper.WaitNotification('textDocument/publishDiagnostics')
  assert_equal(helper.URI, diags.params.uri)
  assert_equal([], diags.params.diagnostics)
  helper.StopServer()
enddef

# A call in the keys of a mapping is looked up where the keys find it when
# typed: after <ScriptCmd> in the script and then everywhere, with <SID> in
# the script, after ":call" everywhere but the script.  Its arguments are
# counted, also in continuation lines.
def g:Test_compile_calls_in_keys()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'def Local(n: number, m = 0)',
    'enddef',
    'nnoremap <F1> <ScriptCmd>Local(1)<CR>',
    'nnoremap <F2> <ScriptCmd>nosuch()<CR>',
    'nnoremap <F3> :call <SID>Local(1, 2)<CR>',
    'nnoremap <F4> :call <SID>Missing()<CR>',
    'nnoremap <F5> :call Local(1)<CR>',
    'nnoremap <F6> :call Other()<CR>',
    'nnoremap <F7> <ScriptCmd>Local()<CR>',
    'nnoremap <F8> <ScriptCmd>call Local(1, 2, 3)<CR>',
    'nnoremap <F9> :call strlen("a", "b")<CR>',
    'inoremap <expr> <F10> nosuch()',
    'nnoremap <F11> <ScriptCmd>Local(1,',
    '      \ 2, 3)<CR>',
  ])
  var diags = helper.WaitNotification('textDocument/publishDiagnostics')
    .params.diagnostics->filter((_, d) => d.message =~ '^E')
  assert_equal([
    [4, 25, 'E117: Unknown function: nosuch'],
    [6, 20, 'E117: Unknown function: <SID>Missing'],
    [7, 20, 'E117: Unknown function: Local'],
    [9, 25, 'E119: Not enough arguments for function: Local'],
    [10, 30, 'E118: Too many arguments for function: Local'],
    [11, 20, 'E118: Too many arguments for function: strlen'],
    [13, 26, 'E118: Too many arguments for function: Local'],
  ], diags->mapnew((_, d) =>
    [d.range.start.line, d.range.start.character, d.message]))
  helper.StopServer()
enddef

# A script that is imported is read again once it has changed, since Vim
# keeps what it read before for the import: at once when the client reports
# the change, and otherwise when the scripts are next looked at, which is
# done every two seconds.
def g:Test_compile_import_changed()
  var root = helper.HERE .. '/Xchanged'
  mkdir(root, 'p')
  var user = ['vim9script', "import './xlib.vim'", 'def F(): number',
    '  return xlib.N', 'enddef']
  var uri = util.PathToUri(root .. '/user.vim')
  const E1012 = 'E1012: Type mismatch; expected number but got string'
  try
    for reported in [true, false]
      writefile(['vim9script', 'export const N: number = 1'],
        root .. '/xlib.vim')
      writefile(user, root .. '/user.vim')
      helper.StartServer()
      helper.Initialize()
      helper.OpenDoc(user, uri)
      assert_equal([],
        helper.WaitNotification('textDocument/publishDiagnostics')
        .params.diagnostics)
      writefile(['vim9script', 'export const N: string = "s"'],
        root .. '/xlib.vim')
      if reported
        helper.Notify('workspace/didChangeWatchedFiles', {changes: [
          {uri: util.PathToUri(root .. '/xlib.vim'), type: 2}]})
      else
        sleep 2100m
      endif
      helper.ChangeDoc(user + [''], uri, 2)
      assert_equal([E1012],
        helper.WaitNotification('textDocument/publishDiagnostics')
          .params.diagnostics->mapnew((_, d) => d.message),
        reported ? 'reported' : 'not reported')
      helper.StopServer()
    endfor

    # Written again in the second it was read, to the same size.
    writefile(['vim9script', 'export const N: number = 12'],
      root .. '/xlib.vim')
    helper.StartServer()
    helper.Initialize()
    helper.OpenDoc(user, uri)
    assert_equal([],
      helper.WaitNotification('textDocument/publishDiagnostics')
      .params.diagnostics)
    writefile(['vim9script', "export const N: string = ''"],
      root .. '/xlib.vim')
    helper.Notify('workspace/didChangeWatchedFiles', {changes: [
      {uri: util.PathToUri(root .. '/xlib.vim'), type: 2}]})
    helper.ChangeDoc(user + [''], uri, 2)
    assert_equal([E1012],
      helper.WaitNotification('textDocument/publishDiagnostics')
        .params.diagnostics->mapnew((_, d) => d.message), 'same size')
  finally
    helper.StopServer()
    delete(root, 'rf')
  endtry
enddef

# Two plugins with an import file of the same name: each script is checked
# against its own, also when the other plugin was checked in between, and a
# file only the other one has is not found.
def g:Test_compile_import_of_own_plugin()
  var root = helper.HERE .. '/Xplugins'
  for [name, text] in [
      ['one', ['vim9script', 'export const N: number = 1', 'export class Shape',
        'endclass']],
      ['two', ['vim9script', 'export const N: string = "s"']]]
    mkdir(root .. '/' .. name .. '/import', 'p')
    mkdir(root .. '/' .. name .. '/plugin', 'p')
    writefile(text, root .. '/' .. name .. '/import/xi.vim')
  endfor
  writefile(['vim9script'], root .. '/two/import/xtwo.vim')
  var one = ['vim9script', "import 'xi.vim'", 'def A(): number',
    '  return xi.N', 'enddef', 'def B(s: xi.Shape): xi.Shape', '  return s',
    'enddef']
  var two = ['vim9script', "import 'xi.vim'", 'def A(): string',
    '  return xi.N', 'enddef']
  var one_uri = util.PathToUri(root .. '/one/plugin/use.vim')
  var two_uri = util.PathToUri(root .. '/two/plugin/use.vim')
  try
    writefile(one, root .. '/one/plugin/use.vim')
    writefile(two + ['var s: xi.Shape'], root .. '/two/plugin/use.vim')
    helper.StartServer()
    helper.Initialize()
    helper.OpenDoc(one, one_uri)
    assert_equal([], helper.WaitNotification('textDocument/publishDiagnostics')
      .params.diagnostics)
    # The other plugin has no Shape, which shows its own file is read.
    helper.OpenDoc(two + ['var s: xi.Shape'], two_uri)
    assert_equal(['E1010: Type not recognized: xi.Shape'],
      helper.WaitNotification('textDocument/publishDiagnostics')
        .params.diagnostics->mapnew((_, d) => d.message))
    helper.ChangeDoc(one + [''], one_uri, 2)
    assert_equal([], helper.WaitNotification('textDocument/publishDiagnostics')
      .params.diagnostics)
    var other = ['vim9script', "import 'xtwo.vim'"]
    var other_uri = util.PathToUri(root .. '/one/plugin/other.vim')
    writefile(other, root .. '/one/plugin/other.vim')
    helper.OpenDoc(other, other_uri)
    assert_match('^E1053: ',
      helper.WaitNotification('textDocument/publishDiagnostics')
        .params.diagnostics->get(0, {message: ''}).message)

    # A script in an "after" directory imports from the directory above it.
    mkdir(root .. '/one/autoload', 'p')
    mkdir(root .. '/one/after/ftplugin', 'p')
    writefile(['vim9script', 'export def Show(s: string)', 'enddef'],
      root .. '/one/autoload/xpop.vim')
    var after = ['vim9script', "import autoload 'xpop.vim'", 'def F()',
      "  xpop.Show('a')", 'enddef']
    var after_uri = util.PathToUri(root .. '/one/after/ftplugin/x.vim')
    writefile(after, root .. '/one/after/ftplugin/x.vim')
    helper.OpenDoc(after, after_uri)
    assert_equal([], helper.WaitNotification('textDocument/publishDiagnostics')
      .params.diagnostics)
  finally
    helper.StopServer()
    delete(root, 'rf')
  endtry
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
    # A relative import, named by its file; the path is given without the
    # "./" of the import.
    resp = helper.Request('textDocument/definition',
      helper.Params(4, 13, uri))
    assert_equal(util.PathToUri(root .. '/plugin/xconst.vim'),
      resp.result[0].uri)
    assert_notmatch('/\./', resp.result[0].uri)
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

def g:Test_references_other_files()
  var root = helper.HERE .. '/Xproj'
  mkdir(root .. '/autoload', 'p')
  mkdir(root .. '/plugin', 'p')
  var lib = root .. '/autoload/xlib.vim'
  writefile(['vim9script', 'export def Greet(): string', "  return 'hi'",
    'enddef', 'echo Greet()'], lib)
  var old = root .. '/autoload/xold.vim'
  writefile(['function xold#Func()', 'endfunction'], old)
  var other = root .. '/plugin/xother.vim'
  writefile(['vim9script', "import autoload 'xlib.vim'", 'echo xlib.Greet()',
    "call('xold#Func', [])", 'echo xlib#Greet()'], other)
  var main = root .. '/plugin/xmain.vim'
  var uri = util.PathToUri(main)
  var Spans = (locations: list<dict<any>>) => locations->mapnew((_, l) =>
    [fnamemodify(util.UriToPath(l.uri), ':t'), l.range.start.line,
      l.range.start.character, l.range.end.character])
  try
    helper.StartServer()
    helper.Initialize()
    helper.OpenDoc(['vim9script', "import autoload 'xlib.vim' as lib",
      'echo lib.Greet()', 'xold#Func()'], uri)
    # An exported name: its own script, the other scripts of the plugin and
    # the open documents, after an alias of the import and as an autoload
    # name.
    var resp = helper.Request('textDocument/references', extend(
      helper.Params(2, 10, uri), {context: {includeDeclaration: true}}))
    var greet = [['xlib.vim', 1, 11, 16], ['xlib.vim', 4, 5, 10],
      ['xmain.vim', 2, 9, 14], ['xother.vim', 2, 10, 15],
      ['xother.vim', 4, 10, 15]]
    assert_equal(greet, Spans(resp.result))
    # The same from the definition, in a document that is open.
    helper.OpenDoc(readfile(lib), util.PathToUri(lib))
    resp = helper.Request('textDocument/references', extend(
      helper.Params(1, 12, util.PathToUri(lib)),
      {context: {includeDeclaration: true}}))
    assert_equal(greet, Spans(resp.result))
    # A legacy autoload function is renamed after its last "#", also inside
    # a string.
    var at = helper.Params(3, 2, uri)
    resp = helper.Request('textDocument/prepareRename', at)
    assert_equal({range: {start: {line: 3, character: 5},
      end: {line: 3, character: 9}}, placeholder: 'Func'}, resp.result)
    resp = helper.Request('textDocument/rename', extend(at, {newName: 'Run'}))
    var changes = resp.result.changes
    var Edits = (path: string) => Spans(changes[util.PathToUri(path)]
      ->mapnew((_, e) => ({uri: util.PathToUri(path), range: e.range})))
    assert_equal([util.PathToUri(old), uri, util.PathToUri(other)],
      keys(changes)->sort())
    assert_equal([['xold.vim', 0, 14, 18]], Edits(old))
    assert_equal([['xmain.vim', 3, 5, 9]], Edits(main))
    assert_equal([['xother.vim', 3, 11, 15]], Edits(other))
    assert_equal(['Run'], changes[uri]->mapnew((_, e) => e.newText))
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

def g:Test_document_highlight()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'var count = 0',
    'def Bump()',
    '  count += 1',
    'enddef',
    'echo count',
    'if count == 1',
    'endif',
  ])
  var resp = helper.Request('textDocument/documentHighlight',
    helper.Params(5, 6))
  var Marks = (result: any) => result->mapnew((_, h) =>
    [h.range.start.line, h.range.start.character, h.range.end.character,
      h.kind])
  # The declaration and the "+=" are writes, reading it is not.
  assert_equal([[1, 4, 9, 3], [3, 2, 7, 3], [5, 5, 10, 2], [6, 3, 8, 2]],
    Marks(resp.result))

  # Nothing known under the cursor.
  resp = helper.Request('textDocument/documentHighlight', helper.Params(0, 0))
  assert_equal(null, resp.result)
enddef

def g:Test_document_highlight_of_a_name_vim_knows()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc([
    'vim9script',
    'echo strlen("a")',
    'echo strlen("bb") + v:count',
    'echo "strlen"',
    'echo notafunction(1)',
  ])
  var Marks = (result: any) => result->mapnew((_, h) =>
    [h.range.start.line, h.range.start.character, h.range.end.character])

  # A builtin is marked where it is called, not inside a string.
  var resp = helper.Request('textDocument/documentHighlight',
    helper.Params(1, 7))
  assert_equal([[1, 5, 11], [2, 5, 11]], Marks(resp.result))

  # A v: variable as well.
  resp = helper.Request('textDocument/documentHighlight',
    helper.Params(2, 20))
  assert_equal([[2, 20, 27]], Marks(resp.result))

  # A name Vim does not know is left alone.
  resp = helper.Request('textDocument/documentHighlight',
    helper.Params(4, 7))
  assert_equal(null, resp.result)
enddef

# On the line that declares a name the name itself is found, whether a type
# follows it or it is a member, which a use has after a ".".  References and
# rename work from there too, the type left in place.
def g:Test_definition_on_the_declaring_line()
  helper.StartServer()
  helper.Initialize()
  var text = ['vim9script',
    'var typed: number = 1',
    'def Foo(arg: number): number',
    '  var local: string = "x"',
    '  return arg + typed',
    'enddef',
    'class Shape',
    '  var width: number',
    '  def Area(): number',
    '    return this.width',
    '  enddef',
    'endclass',
    'enum Color',
    '  Red',
    'endenum']
  helper.OpenDoc(text)
  var At = (lnum: number, name: string) => {
    var r = helper.Request('textDocument/definition',
      helper.Params(lnum, stridx(text[lnum], name) + 1)).result
    return r == null ? [] : r->mapnew((_, l) => [l.range.start.line,
      l.range.start.character])
  }
  assert_equal([[1, 4]], At(1, 'typed'))
  assert_equal([[2, 8]], At(2, 'arg'))
  assert_equal([[3, 6]], At(3, 'local'))
  assert_equal([[7, 6]], At(7, 'width'))
  assert_equal([[8, 6]], At(8, 'Area'))
  assert_equal([[13, 2]], At(13, 'Red'))

  var refs = helper.Request('textDocument/references',
    extend(helper.Params(7, 7), {context: {includeDeclaration: true}})).result
  assert_equal([[7, 6], [9, 16]], refs->mapnew((_, l) => [l.range.start.line,
    l.range.start.character]))

  var edits = helper.Request('textDocument/rename',
    extend(helper.Params(1, 5), {newName: 'count'})).result
    .changes[helper.URI]
  assert_equal([[1, 4, 9], [4, 15, 20]], edits->mapnew((_, e) =>
    [e.range.start.line, e.range.start.character, e.range.end.character]))
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
    'echo 1->append(',
    'echo get(',
  ])
  # The label carries the types.
  var resp = helper.Request('textDocument/signatureHelp',
    helper.Params(4, 26))
  var help = resp.result
  assert_equal(2, help.activeParameter)
  assert_equal(
    'matchstr({expr}: string | list<any>, {pat}: string [, {start}: number'
      .. ' [, {count}: number]]): string',
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

  # The value before "->" fills the second argument of append(), so the
  # argument typed is the first, {lnum}.
  resp = helper.Request('textDocument/signatureHelp', helper.Params(15, 16))
  assert_equal(0, resp.result.activeParameter)

  # The help names the first argument of get() "{list}" while it accepts more
  # types than a list: the name becomes the number of the argument.
  resp = helper.Request('textDocument/signatureHelp', helper.Params(16, 9))
  assert_equal(
    'get({arg1}: blob | list<any> | tuple<any> | dict<any> | func,'
      .. ' {idx}: string | number [, {default}: any])',
    resp.result.signatures[0].label)
  assert_match('^Get item', resp.result.signatures[0].documentation.value)
enddef

# A call is found by its bytes: a character of more than one byte before it,
# or in a call closed above, does not throw the count off.
def g:Test_signature_help_multibyte()
  var lines = [
    'vim9script',
    "var chars = get(g:, 'chars', ['─', '│', '─', '│', '╭', '╮', '╯', '╰'])",
    'def F()',
    '  if empty()',
    "  echo '─│' .. matchstr(",
    'enddef',
  ]
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(lines)
  var resp = helper.Request('textDocument/signatureHelp',
    helper.Params(3, strlen(lines[3])))
  assert_equal(null, resp.result)

  resp = helper.Request('textDocument/signatureHelp',
    helper.Params(4, strlen(lines[4])))
  assert_match('^matchstr(', resp.result.signatures[0].label)
enddef

# The parameters of a label with a multibyte character are marked where they
# are, in bytes with UTF-8.
def g:Test_signature_help_multibyte_label()
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(['vim9script', "def F(a = 'あ', b = 1)", 'enddef', 'F(1, '])
  var resp = helper.Request('textDocument/signatureHelp', helper.Params(3, 5))
  var label = resp.result.signatures[0].label
  assert_equal([[stridx(label, 'a'), stridx(label, ',')],
    [stridx(label, 'b'), stridx(label, ')')]],
    resp.result.signatures[0].parameters->mapnew((_, p) => p.label))
  helper.StopServer()

  # In UTF-16 units when that is what the client took.
  helper.StartServer()
  helper.Initialize(['utf-16'])
  helper.OpenDoc(['vim9script', "def F(a = 'あ', b = 1)", 'enddef', 'F(1, '])
  resp = helper.Request('textDocument/signatureHelp', helper.Params(3, 5))
  var Units = (s: string): number =>
    strutf16len(strpart(label, 0, stridx(label, s)))
  assert_equal([[Units('a'), Units(',')], [Units('b'), Units(')')]],
    resp.result.signatures[0].parameters->mapnew((_, p) => p.label))
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
  # The parser's error; the checker adds what Vim makes of the rest.
  assert_equal(['E171: Missing :endif'],
    note.params.diagnostics->mapnew((_, d) => d.message)
      ->filter((_, m) => m =~ '^E171:'))
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

# A change after a character of more than one byte lands where it was made.
def g:Test_incremental_sync_multibyte()
  var line = "var s = 'ああ' | var one = 1"
  var at = stridx(line, 'one') + 3
  helper.StartServer()
  helper.Initialize()
  helper.OpenDoc(['vim9script', line])
  helper.ChangeRange([1, at, 1, at], 'Two', 2)
  var resp = helper.Request('textDocument/documentSymbol',
    {textDocument: {uri: helper.URI}})
  assert_equal(['s', 'oneTwo'], resp.result->mapnew((_, s) => s.name))
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
