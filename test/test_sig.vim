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

def g:Test_typed()
  # The info is what getinfo() reports.
  var info = {
    args: [{name: 'expr', types: ['string', 'list<any>']},
      {name: 'pat', types: ['string']}, {name: 'start', types: ['number']},
      {name: 'count', types: ['number']}],
    returns: 'string',
  }
  extend(info, {minargs: 2, maxargs: 4})
  var typed = sig.Typed('matchstr({expr}, {pat} [, {start} [, {count}]])',
    info)
  assert_equal('matchstr({expr}: string | list<any>, {pat}: string'
    .. ' [, {start}: number [, {count}: number]]): string', typed.label)
  assert_equal([[9, 35], [37, 50], [54, 69], [73, 88]], typed.parameters)
  assert_equal(['{expr}: string | list<any>', '{pat}: string',
    '{start}: number', '{count}: number'],
    typed.parameters->mapnew((_, p) => typed.label[p[0] : p[1] - 1]))
  # The spans go into the help as they are.
  var help = sig.Help(typed.label, 1, '', typed.parameters)
  assert_equal([[9, 35], [37, 50], [54, 69], [73, 88]],
    help.signatures[0].parameters->mapnew((_, p) => p.label))

  # No arguments; "any" and an empty return type are not shown.
  assert_equal('getpid()', sig.Typed('getpid()',
    {args: [], minargs: 0, maxargs: 0, returns: ''}).label)
  assert_equal('foo({x}: any)', sig.Typed('foo({x})',
    {args: [{name: 'x', types: ['any']}], minargs: 1, maxargs: 1,
      returns: 'any'}).label)

  # The help writes "..." for the arguments the info has more of.
  typed = sig.Typed('printf({fmt} [, {expr1} ...])', {
    args: [{name: 'fmt', types: ['string']}, {name: 'expr1', types: ['any']}]
      + repeat([{types: ['any']}], 17),
    minargs: 1, maxargs: 19, returns: 'string'})
  assert_equal('printf({fmt}: string [, {expr1}: any ...]): string',
    typed.label)
  assert_equal([[7, 20], [24, 40]], typed.parameters)
  # No maximum: the last argument stands for the rest.
  typed = sig.Typed('instanceof({object}, {class} ...)', {
    args: [{name: 'object', types: ['object<any>']},
      {name: 'class', types: ['class']}],
    minargs: 2, maxargs: -1, returns: 'bool'})
  assert_equal('instanceof({object}: object<any>, {class}: class ...): bool',
    typed.label)
  assert_equal([[11, 32], [34, 52]], typed.parameters)

  # A name that is a type contradicts the other types the argument accepts: it
  # becomes the number of the argument.  With one type it stays.
  typed = sig.Typed('get({list}, {idx} [, {default}])', {
    args: [{name: 'list', types: ['blob', 'list<any>', 'dict<any>']},
      {name: 'idx', types: ['string', 'number']},
      {name: 'default', types: ['any']}],
    minargs: 2, maxargs: 3, returns: 'any'})
  assert_equal('get({arg1}: blob | list<any> | dict<any>,'
    .. ' {idx}: string | number [, {default}: any])', typed.label)
  assert_equal([[4, 40], [42, 64], [68, 82]], typed.parameters)
  typed = sig.Typed('strlen({string})', {args: [{name: 'string',
    types: ['string', 'number']}], minargs: 1, maxargs: 1,
    returns: 'number'})
  assert_equal('strlen({arg1}: string | number): number', typed.label)
  typed = sig.Typed('add({list}, {expr})', {args: [{name: 'list',
    types: ['list<any>']}, {name: 'expr', types: ['any']}], minargs: 2,
    maxargs: 2, returns: 'any'})
  assert_equal('add({list}: list<any>, {expr}: any)', typed.label)

  # The info names the arguments, the help line need not name them all:
  # remove() has a line for two arguments and one for three.
  typed = sig.Typed('remove({list}, {idx})', {
    args: [{name: 'list', types: ['list<any>', 'dict<any>', 'blob']},
      {name: 'idx', types: ['number', 'string']},
      {name: 'end', types: ['any']}],
    minargs: 2, maxargs: 3, returns: 'any'})
  assert_equal('remove({arg1}: list<any> | dict<any> | blob,'
    .. ' {idx}: number | string [, {end}: any])', typed.label)
  assert_equal([[7, 43], [45, 67], [71, 81]], typed.parameters)
  # An argument the info does not name is its number: the second of getreg()
  # is a value in the help.
  typed = sig.Typed('getreg([{regname} [, 1 [, {list}]]])', {
    args: [{name: 'regname', types: ['string']}, {types: ['bool']},
      {name: 'list', types: ['bool']}],
    minargs: 0, maxargs: 3, returns: 'any'})
  assert_equal('getreg([{regname}: string [, {arg2}: bool [, {list}: bool]]])',
    typed.label)
  # Without the info the names come from the help line.
  assert_equal(['{expr}', '{pat}', '{start}', '{count}'],
    sig.Names('matchstr({expr}, {pat} [, {start} [, {count}]])', {}))

  # A name that is one of the types of the argument.
  assert_true(sig.TypeNamed('{list}', ['list<any>', 'blob']))
  assert_true(sig.TypeNamed('{string}', ['string']))
  assert_false(sig.TypeNamed('{expr}', ['string', 'number']))
  assert_false(sig.TypeNamed('{list}', ['dict<any>']))
enddef

# vim: ts=2 sw=0 et
