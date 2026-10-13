vim9script

import autoload '../autoload/vim9ls/parse.vim'
import autoload '../autoload/vim9ls/defs.vim'

def Definitions(lines: list<string>): list<string>
  return defs.Lines(parse.Parse(lines), lines)
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

# A class stays as it is, but for the value of a static variable; an enum
# stays as it is.
def g:Test_defs_class()
  var lines =<< trim END
    vim9script
    class C
      static var count = Count()
      public static const NAME: string = Name()
      var width: number = 1
      def Area(): number
        return this.width
      enddef
    endclass
    enum Color
      Red('r'),
      Blue('b')
      var code: string
      def new(this.code)
      enddef
    endenum
  END
  var expected = copy(lines)
  expected[2] = '  static var count: any'
  expected[3] = '  public static var NAME: string'
  assert_equal(expected, Definitions(lines))
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
