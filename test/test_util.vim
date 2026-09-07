vim9script

import autoload '../autoload/vim9ls/util.vim'

def g:Test_uri_roundtrip()
  var path = has('win32') ? 'C:\tmp\a b.vim' : '/tmp/a b.vim'
  var uri = util.PathToUri(path)
  assert_match('^file:///', uri)
  assert_match('a%20b\.vim$', uri)
  assert_equal(fnamemodify(path, ':p'), util.UriToPath(uri))
  assert_equal('untitled:x', util.UriToPath('untitled:x'))
enddef

# "aあ😀b" is 1, 3, 4 and 1 bytes; 1, 1, 2 and 1 UTF-16 units.
def g:Test_column_conversion()
  var line = "aあ😀b"
  assert_equal(4, util.ColToLsp(line, 4, 'utf-8'))
  assert_equal(4, util.ColFromLsp(line, 4, 'utf-8'))
  assert_equal(9, util.ColFromLsp(line, 99, 'utf-8'))

  assert_equal(0, util.ColToLsp(line, 0, 'utf-16'))
  assert_equal(1, util.ColToLsp(line, 1, 'utf-16'))
  assert_equal(2, util.ColToLsp(line, 4, 'utf-16'))
  assert_equal(4, util.ColToLsp(line, 8, 'utf-16'))
  assert_equal(5, util.ColToLsp(line, 9, 'utf-16'))
  assert_equal(1, util.ColFromLsp(line, 1, 'utf-16'))
  assert_equal(4, util.ColFromLsp(line, 2, 'utf-16'))
  assert_equal(8, util.ColFromLsp(line, 4, 'utf-16'))
  assert_equal(9, util.ColFromLsp(line, 5, 'utf-16'))
  assert_equal(9, util.ColFromLsp(line, 99, 'utf-16'))

  assert_equal(3, util.ColToLsp(line, 8, 'utf-32'))
  assert_equal(4, util.ColToLsp(line, 9, 'utf-32'))
  assert_equal(8, util.ColFromLsp(line, 3, 'utf-32'))
enddef

def g:Test_range()
  var lines = ['abc', 'aあb']
  var range = util.Range(lines, 0, 1, 1, 4, 'utf-16')
  assert_equal({start: {line: 0, character: 1}, end: {line: 1, character: 2}},
    range)
  range = util.Range(lines, 0, 1, 1, 4, 'utf-8')
  assert_equal({start: {line: 0, character: 1}, end: {line: 1, character: 4}},
    range)
enddef

# vim: ts=2 sw=0 et
