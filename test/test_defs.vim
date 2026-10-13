vim9script

import autoload '../autoload/vim9ls/parse.vim'
import autoload '../autoload/vim9ls/defs.vim'

def Definitions(lines: list<string>): list<string>
  return defs.Lines(parse.Parse(lines), lines).lines
enddef

# The definitions stay, a declaration loses its value, and everything else
# is blanked, the lines staying where they were.
def g:Test_defs_script()
  var lines =<< trim END
    " a comment in the legacy style
    vim9script
    import './lib.vim'
    import autoload 'other.vim' as other
    var typed: number = system('date')->len()
    var untyped = [
      1, 2]
    const LIMIT = 10
    final NAMES: list<string> = []
    export var shared = 1
    var [first, second] = [1, 2]
    let old = 1
    var text =<< trim EOT
      type Hidden = number
    EOT
    type Alias = list<string>
    command! Cmd echo 1
    augroup Group
      autocmd BufEnter * echo 1
    augroup END
    def F()
      echo 1
    enddef
    call F()
    finish
  END
  assert_equal([
    '',
    'vim9script',
    "import './lib.vim'",
    "import autoload 'other.vim' as other",
    'var typed: number',
    'var untyped: any',
    '',
    'var LIMIT: any',
    'var NAMES: list<string>',
    'export var shared: any',
    'var first: any | var second: any',
    'let old',
    'var text: any',
    '',
    '',
    'type Alias = list<string>',
    '',
    '',
    '',
    '',
    'def F()',
    '  echo 1',
    'enddef',
    '',
    '',
  ], Definitions(lines))
enddef

# A definition inside a block stays, the block goes; one defined again gets
# a name of its own.  A declaration inside a block is not a script variable.
def g:Test_defs_blocks()
  var lines =<< trim END
    vim9script
    if has('win32')
      var inner = 1
      def Platform(): string
        return 'win'
      enddef
    else
      def Platform(): string
        return 'unix'
      enddef
    endif
  END
  assert_equal([
    'vim9script',
    '',
    '',
    '  def Platform(): string',
    "    return 'win'",
    '  enddef',
    '',
    '  def Platform_vim9ls8(): string',
    "    return 'unix'",
    '  enddef',
    '',
  ], Definitions(lines))
enddef

# A class stays as it is, but for the value of a static variable, which
# goes to a static method of its own.
def g:Test_defs_class()
  var lines =<< trim END
    vim9script
    class C
      static var count = Count()
      public static const NAMES: list<string> = [
        'a']
      var width: number = 1
    endclass
  END
  var made = defs.Lines(parse.Parse(lines), lines)
  assert_equal([
    'vim9script',
    'class C',
    '  static var count: any',
    '  public static var NAMES: list<string>',
    '',
    '  var width: number = 1',
    '  static def _Vim9lsCheck1()',
    '    count = Count()',
    '  enddef',
    '  static def _Vim9lsCheck2()',
    "    NAMES = [ 'a']",
    '  enddef',
    'endclass',
  ], made.lines)
  assert_equal([0, 1, 2, 3, 4, 5, 2, 2, 2, 3, 3, 3, 6], made.origin)
enddef

# An enum becomes a class with a static variable for each value, the
# builtins declared, a constructor without arguments when it has none, and
# a static method for the arguments of each value.
def g:Test_defs_enum()
  var lines =<< trim END
    vim9script
    enum Color
      Red('r'),
      Blue('b'), Green(
        'g')
      var code: string
      def new(this.code)
      enddef
    endenum
    export enum Plain implements Shown
      A, B
    endenum
  END
  var made = defs.Lines(parse.Parse(lines), lines)
  assert_equal([
    'vim9script',
    'class Color',
    '  final name: string',
    '  final ordinal: number',
    '  static final values: list<Color>',
    '  static var Red: Color',
    '  static var Blue: Color',
    '  static var Green: Color',
    '',
    '  var code: string',
    '  def new(this.code)',
    '  enddef',
    '  static def _Vim9lsCheck1()',
    "    Color.new('r')",
    '  enddef',
    '  static def _Vim9lsCheck2()',
    "    Color.new('b')",
    '  enddef',
    '  static def _Vim9lsCheck3()',
    "    Color.new( 'g')",
    '  enddef',
    'endclass',
    'export class Plain implements Shown',
    '  final name: string',
    '  final ordinal: number',
    '  static final values: list<Plain>',
    '  def new()',
    '  enddef',
    '  static var A: Plain',
    '  static var B: Plain',
    '  static def _Vim9lsCheck4()',
    '    Plain.new()',
    '  enddef',
    '  static def _Vim9lsCheck5()',
    '    Plain.new()',
    '  enddef',
    'endclass',
  ], made.lines)
  assert_equal([0, 1, 1, 1, 1, 2, 3, 3, 4, 5, 6, 7, 2, 2, 2, 3, 3, 3, 3, 3,
    3, 8, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 11], made.origin)
enddef

# A legacy script keeps its functions and nothing else.
def g:Test_defs_legacy()
  var lines =<< trim END
    let s:count = 1
    function s:Count()
      return s:count
    endfunction
    def Compiled(): number
      return 1
    enddef
    call s:Count()
  END
  assert_equal(['', 'function s:Count()', '  return s:count', 'endfunction',
    'def Compiled(): number', '  return 1', 'enddef', ''], Definitions(lines))
enddef

# vim: ts=2 sw=0 et
