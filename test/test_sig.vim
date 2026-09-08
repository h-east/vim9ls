vim9script

import autoload '../autoload/vim9ls/sig.vim'

def g:Test_call()
  var line = "echo matchstr(a, 'x(y', Fn(1, 2), c) .. d"
  # In the first argument, right after the "(".
  var hit = sig.Call(line, 14, true)
  assert_equal('matchstr', hit.name)
  assert_equal(5, hit.col)
  assert_equal(' ', hit.prev)
  assert_equal(false, hit.method)
  assert_equal(0, hit.active)
  # In the third argument; the "(" inside the string does not count.
  assert_equal(2, sig.Call(line, 24, true).active)
  # Inside the nested call, right after its comma, and behind it again.
  hit = sig.Call(line, 29, true)
  assert_equal('Fn', hit.name)
  assert_equal(1, hit.active)
  assert_equal(3, sig.Call(line, 35, true).active)
  # After the closing ")" there is no call.
  assert_equal(null_dict, sig.Call(line, 39, true))

  # A method call, and a member call.
  hit = sig.Call("x->matchstr('a', ", 17, true)
  assert_equal('matchstr', hit.name)
  assert_equal(true, hit.method)
  assert_equal(1, hit.active)
  hit = sig.Call('shape.Area(', 11, true)
  assert_equal('Area', hit.name)
  assert_equal('.', hit.prev)

  # A list or a grouping is not a call.
  assert_equal(null_dict, sig.Call('var x = [1, (2 + ', 16, true))
  # A comment is not code.
  assert_equal(null_dict, sig.Call('# Fn(1, ', 8, true))
enddef

def g:Test_call_over_lines()
  var lines = [
    'echo matchstr(a,',
    "  'b',  # a comment (with parens)",
    '  Fn(1,',
    '    2),',
    '  ',
  ]
  var vim9_at = repeat([true], len(lines))
  var hit = sig.CallAt(lines, 4, 2, vim9_at)
  assert_equal('matchstr', hit.name)
  assert_equal(0, hit.line)
  assert_equal(5, hit.col)
  assert_equal(3, hit.active)
  # Inside the nested call on its own lines.
  hit = sig.CallAt(lines, 3, 4, vim9_at)
  assert_equal('Fn', hit.name)
  assert_equal(2, hit.line)
  assert_equal(1, hit.active)
  # A closed statement above does not count.
  assert_equal(null_dict, sig.CallAt(['echo Fn(1)', 'echo x'], 1, 6,
    [true, true]))
enddef

# The text each parameter span of "label" covers.
def Spans(label: string): list<string>
  return sig.Parameters(label)->mapnew((_, p) => label[p[0] : p[1] - 1])
enddef

def g:Test_parameters()
  assert_equal([[7, 15]], sig.Parameters('strlen({string})'))
  assert_equal(['{expr}', '{pat}', '{start}', '{count}'],
    Spans('matchstr({expr}, {pat} [, {start} [, {count}]])'))
  assert_equal([], sig.Parameters('getpid()'))
  assert_equal(['a: number', 'b: dict<any> = {}', '...rest: any'],
    Spans('Add(a: number, b: dict<any> = {}, ...rest: any): number'))
  assert_equal([[7, 8], [10, 11]], sig.Parameters('s:Init(x, y)'))
enddef

def g:Test_help()
  var help = sig.Help('matchstr({expr}, {pat} [, {start} [, {count}]])', 2,
    'The match')
  assert_equal(0, help.activeSignature)
  assert_equal(2, help.activeParameter)
  var signature = help.signatures[0]
  assert_equal([26, 33], signature.parameters[2].label)
  assert_equal({kind: 'plaintext', value: 'The match'},
    signature.documentation)
  # Past the last parameter stays on the last one.
  assert_equal(3, sig.Help(signature.label, 9).activeParameter)
  assert_equal(0, sig.Help('getpid()', 0).activeParameter)
enddef

# vim: ts=2 sw=0 et
