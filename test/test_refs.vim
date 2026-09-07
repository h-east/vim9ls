vim9script

import autoload '../autoload/vim9ls/parse.vim'
import autoload '../autoload/vim9ls/refs.vim'

const HERE = expand('<sfile>:p:h')

def g:Test_code_spans()
  # A legacy comment is the whole line.
  assert_equal({code: [], strings: []}, refs.CodeSpans('  " x = 1', false))
  # A Vim9 comment ends the code.
  assert_equal({code: [[0, 6]], strings: []},
    refs.CodeSpans('x = 1 # y = 2', true))
  # "#" inside a word is not a comment.
  assert_equal({code: [[0, 15]], strings: []},
    refs.CodeSpans('call a#b#Func()', true))
  # Strings are cut out, with their contents reported.
  var spans = refs.CodeSpans("echo 'it''s' .. \"a\\\"b\" .. x", false)
  assert_equal([[0, 5], [12, 16], [22, 27]], spans.code)
  assert_equal([[6, 11], [17, 21]], spans.strings)
enddef

def Texts(tokens: list<dict<any>>): list<string>
  return tokens->mapnew((_, t) => t.text)
enddef

def g:Test_tokens()
  var tokens = refs.Tokens("call s:Init(g:count, 'Foo', 'x y', 12)", false)
  assert_equal(['call', 's:Init', 'g:count', 'Foo'], Texts(tokens))
  assert_equal(false, tokens[1].in_string)
  assert_equal(true, tokens[3].in_string)
  assert_equal(' ', tokens[1].prev)

  tokens = refs.Tokens('this.name = <SID>Helper() + obj.Area()', true)
  assert_equal(['this', 'name', '<SID>Helper', 'obj', 'Area'], Texts(tokens))
  assert_equal('.', tokens[1].prev)
  assert_equal('.', tokens[4].prev)
  # A function named in a string, with or without a "*".
  tokens = refs.Tokens("exists('*s:Init') || function(\"Foo\")", false)
  assert_equal(['exists', 'function', 's:Init', 'Foo'], Texts(tokens))
enddef

def g:Test_resolve_scopes()
  var lines =<< trim END
    vim9script
    var count = 0
    def First()
      var count = 1
      echo count
    enddef
    def Second()
      echo count
    enddef
  END
  var parsed = parse.Parse(lines)
  var token = {text: 'count', col: 7, end: 12, prev: ' ', in_string: false}
  assert_equal(3, refs.Resolve(parsed, token, 4).line)
  assert_equal(1, refs.Resolve(parsed, token, 7).line)
  assert_equal(1, refs.Resolve(parsed, token, 1).line)
  # A name that is not defined resolves to nothing.
  var other = {text: 'other', col: 0, end: 5, prev: '', in_string: false}
  assert_equal(null_dict, refs.Resolve(parsed, other, 7))
enddef

def Spans(refs_list: list<dict<number>>): list<list<number>>
  return refs_list->mapnew((_, r) => [r.line, r.col, r.end])
enddef

def g:Test_references_vim9()
  var lines =<< trim END
    vim9script
    def Init()
    enddef
    Init()
    s:Init()
    var f = function('Init')
    echo 'Init'
    var Init_x = 1
  END
  var parsed = parse.Parse(lines)
  var symbol = parsed.symbols[0]
  assert_equal([[1, 4, 8], [3, 0, 4], [4, 2, 6], [5, 18, 22], [6, 6, 10]],
    Spans(refs.References(parsed, lines, symbol, true)))
  assert_equal([[3, 0, 4], [4, 2, 6], [5, 18, 22], [6, 6, 10]],
    Spans(refs.References(parsed, lines, symbol, false)))
enddef

def g:Test_references_legacy()
  var lines =<< trim END
    function s:Init()
    endfunction
    function Init()
    endfunction
    call s:Init()
    call <SID>Init()
    call Init()
    let s:count = 1
    echo 'count' . s:count
  END
  var parsed = parse.Parse(lines)
  # "s:Init" and "Init" are different functions in legacy script.
  assert_equal([[0, 11, 15], [4, 7, 11], [5, 10, 14]],
    Spans(refs.References(parsed, lines, parsed.symbols[0], true)))
  assert_equal([[2, 9, 13], [6, 5, 9]],
    Spans(refs.References(parsed, lines, parsed.symbols[1], true)))
  # A variable named in a string is not a reference.
  assert_equal([[7, 6, 11], [8, 17, 22]],
    Spans(refs.References(parsed, lines, parsed.symbols[2], true)))
enddef

def g:Test_references_members()
  var lines =<< trim END
    vim9script
    class Shape
      var name: string
      def new(name: string)
        this.name = name
      enddef
    endclass
    var s = Shape.new('x')
    echo s.name
    var name = 'free'
  END
  var parsed = parse.Parse(lines)
  var field = parsed.symbols[0].children[0]
  assert_equal([[2, 6, 10], [4, 9, 13], [8, 7, 11]],
    Spans(refs.References(parsed, lines, field, true)))
  # The parameter and the free variable are not the field.
  var free = parsed.symbols[2]
  assert_equal([[9, 4, 8]], Spans(refs.References(parsed, lines, free, true)))
enddef

def g:Test_import_file()
  var root = HERE .. '/Xproj'
  mkdir(root .. '/autoload/deep', 'p')
  mkdir(root .. '/plugin', 'p')
  writefile(['vim9script'], root .. '/autoload/xlib.vim')
  writefile(['vim9script'], root .. '/autoload/deep/xsub.vim')
  writefile(['vim9script'], root .. '/plugin/xhelp.vim')
  var script = root .. '/plugin/xmain.vim'
  try
    assert_equal(root .. '/autoload/xlib.vim',
      refs.ImportFile(script, 'xlib.vim', true))
    assert_equal(root .. '/autoload/deep/xsub.vim',
      refs.ImportFile(script, 'deep/xsub.vim', true))
    assert_equal(root .. '/plugin/xhelp.vim',
      refs.ImportFile(script, './xhelp.vim', false))
    assert_equal('', refs.ImportFile(script, 'nothere.vim', true))
    assert_equal(root .. '/autoload/deep/xsub.vim',
      refs.AutoloadFile(script, 'deep/xsub.vim'))
  finally
    delete(root, 'rf')
  endtry
enddef

# vim: ts=2 sw=0 et
