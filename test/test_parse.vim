vim9script

import autoload '../autoload/vim9ls/parse.vim'

export const VIM9_SAMPLE =<< trim END
  vim9script
  import autoload 'foo.vim' as foo
  var count = 0
  const LIMIT: number = 10
  export def Outer(x: number): string
    def Inner()
    enddef
    return ''
  enddef
  class Shape
    var name: string
    static var total = 0
    def new(name: string)
      this.name = name
    enddef
    def Area(): number
      return 0
    enddef
  endclass
  enum Color
    Red,
    Green
    def Describe(): string
      return ''
    enddef
  endenum
  interface Drawable
    def Draw(): void
  endinterface
  augroup MyGroup
    autocmd!
    autocmd BufEnter * echo 'x'
  augroup END
  command! -nargs=1 Hello echo <q-args>
END

def Names(symbols: list<dict<any>>): list<string>
  return symbols->mapnew((_, s) => s.name)
enddef

def g:Test_parse_vim9_symbols()
  var parsed = parse.Parse(VIM9_SAMPLE)
  assert_true(parsed.vim9)
  assert_equal([], parsed.diags)
  var top = parsed.symbols
  assert_equal(['foo', 'count', 'LIMIT', 'Outer', 'Shape', 'Color',
    'Drawable', 'MyGroup', 'Hello'], Names(top))

  assert_equal(parse.KIND_MODULE, top[0].kind)
  assert_equal('foo.vim', top[0].detail)
  assert_equal(parse.KIND_VARIABLE, top[1].kind)
  assert_equal(0, top[1].col)
  assert_equal(4, top[1].name_col)
  assert_equal(parse.KIND_CONSTANT, top[2].kind)
  assert_equal('number', top[2].detail)

  var outer = top[3]
  assert_equal(parse.KIND_FUNCTION, outer.kind)
  assert_equal(4, outer.line)
  assert_equal(8, outer.end_line)
  assert_equal(11, outer.name_col)
  assert_equal(16, outer.name_end)
  assert_equal('(x: number): string', outer.detail)
  assert_equal(['x', 'Inner'], Names(outer.children))
  assert_true(outer.children[0].param)
  assert_equal(17, outer.children[0].name_col)
  assert_equal(6, outer.children[1].end_line)

  var shape = top[4]
  assert_equal(parse.KIND_CLASS, shape.kind)
  assert_equal(18, shape.end_line)
  assert_equal(['name', 'total', 'new', 'Area'], Names(shape.children))
  assert_equal(parse.KIND_FIELD, shape.children[0].kind)
  assert_equal('string', shape.children[0].detail)
  assert_equal(parse.KIND_FIELD, shape.children[1].kind)
  assert_equal(parse.KIND_METHOD, shape.children[2].kind)

  var color = top[5]
  assert_equal(parse.KIND_ENUM, color.kind)
  assert_equal(['Red', 'Green', 'Describe'], Names(color.children))
  assert_equal(parse.KIND_ENUM_MEMBER, color.children[0].kind)
  assert_equal(parse.KIND_METHOD, color.children[2].kind)

  var drawable = top[6]
  assert_equal(parse.KIND_INTERFACE, drawable.kind)
  assert_equal(['Draw'], Names(drawable.children))
  assert_equal(28, drawable.end_line)

  var group = top[7]
  assert_equal(parse.KIND_NAMESPACE, group.kind)
  assert_equal(29, group.line)
  assert_equal(32, group.end_line)

  assert_equal(parse.KIND_FUNCTION, top[8].kind)
  assert_equal(':command', top[8].detail)

  # A type with a colon of its own.
  top = parse.Parse(['vim9script',
    'var Ref: func(string): number = (s) => 1']).symbols
  assert_equal('func(string): number', top[0].detail)
enddef

def g:Test_parse_legacy_symbols()
  var lines =<< trim END
    " a comment
    let s:count = 0
    let g:x = 1
    let g:x += 1
    function! s:Init() abort
      let l:a = 1
    endfunction
    fu Other()
    endfu
    if exists('g:y') | let g:y = 2 | endif
    let [s:p, s:q] = [1, 2]
  END
  var parsed = parse.Parse(lines)
  assert_false(parsed.vim9)
  assert_equal([], parsed.diags)
  assert_equal(['s:count', 'g:x', 's:Init', 'Other', 'g:y', 's:p', 's:q'],
    Names(parsed.symbols))
  assert_equal(['l:a'], Names(parsed.symbols[2].children))
  # Legacy parameters are known under their "a:" name.
  var legacy = parse.Parse(['function Add(x, y, ...)', 'endfunction'])
  assert_equal(['a:x', 'a:y'], Names(legacy.symbols[0].children))
  assert_equal(6, parsed.symbols[2].end_line)
  assert_equal(8, parsed.symbols[3].end_line)
enddef

def g:Test_parse_all_symbols()
  var parsed = parse.Parse(VIM9_SAMPLE)
  var names = Names(parse.AllSymbols(parsed.symbols))
  assert_true(index(names, 'Inner') >= 0)
  assert_true(index(names, 'Area') >= 0)
  assert_true(index(names, 'Green') >= 0)
enddef

# An abstract method is declared and not defined: nothing closes it, as with
# a method of an interface.
def g:Test_parse_abstract_method()
  var lines =<< trim END
    vim9script
    abstract class Base
      var name: string
      abstract def Area(): number
      def Describe(): string
        return this.name
      enddef
    endclass
    def After()
    enddef
  END
  var parsed = parse.Parse(lines)
  assert_equal([], parsed.diags)
  assert_equal(['Base', 'After'], Names(parsed.symbols))
  assert_equal(['name', 'Area', 'Describe'],
    Names(parsed.symbols[0].children))
  assert_equal(7, parsed.symbols[0].end_line)
enddef

# A generated table of a plugin is written on one line, tens of thousands of
# characters of it; the bars in it are what has the line split into commands.
def g:Test_parse_a_very_long_line()
  var table = 'var table = {' .. repeat("'key': {'sig': 'a | b'}, ", 4000)
    .. '}'
  var lines = ['vim9script', 'def Before()', 'enddef', table,
    'def After()', 'enddef']
  var start = reltime()
  var parsed = parse.Parse(lines)
  var took = reltimefloat(reltime(start))

  assert_equal(['Before', 'table', 'After'], Names(parsed.symbols))
  assert_equal([], parsed.diags)
  # Walking the line by character index takes over ten seconds for this
  # one; the bound is loose, a machine under load is nowhere near it.
  assert_true(took < 5.0, printf('%d characters took %.1fs',
    strlen(table), took))
enddef

# The offsets of the commands a bar separates are counted in bytes, the way
# the rest of the parser counts columns.
def g:Test_parse_bar_after_multibyte()
  var parsed = parse.Parse(['vim9script', "var x = 'あいう' | var after = 1"])
  var after = parsed.symbols->filter((_, s) => s.name == 'after')
  assert_equal(1, len(after))
  assert_equal(1, after[0].line)
  # "var x = 'あいう' | var " is 26 bytes, the name starts after it.
  assert_equal(26, after[0].name_col)
  assert_equal(31, after[0].name_end)
enddef

# A comma inside the type or the default of a parameter does not start
# another one.
def g:Test_parse_parameter_types()
  var parsed = parse.Parse(['vim9script',
    "def F(Cb: func(number, string): bool, t: tuple<number, string>,",
    "    d: string = 'a, b', e: list<number> = [1, 2], f = 1 > 0, g = 2)",
    'enddef'])
  assert_equal(['Cb', 't', 'd', 'e', 'f', 'g'],
    Names(parsed.symbols[0].children))
enddef

# A heredoc is "{name} =<< [trim] [eval] {endmarker}", a type after the name
# under Vim9 rules; "=<<" in a string is not one, and neither is an end
# marker that starts with a lower case letter.
def g:Test_parse_heredoc_form()
  var lines =<< trim END
    vim9script
    const OP: string = '\s=<<\s\@=\%(\s\+\%(trim\|eval\)\)\{,2}'
    var after_op = 1
    var s = ' =<< trim END'
    var after_s = 2
    var text =<< trim END
      def NotAFunction()
    END
    var typed: list<string> =<< trim eval EOT
      {after_op}
    EOT
    var lower =<< end
    var after_lower = 3
  END
  var parsed = parse.Parse(lines)
  assert_equal(['OP', 'after_op', 's', 'after_s', 'text', 'typed', 'lower',
    'after_lower'], Names(parsed.symbols))
  assert_equal([6, 7, 9, 10], parsed.heredoc_lines)
enddef

# A heredoc ends at the marker alone on its line, with "trim" after the
# indent of the line of "=<<"; with more indent, or any without "trim", the
# marker is text.
def g:Test_parse_heredoc_end_indent()
  var lines =<< trim END
    vim9script
    var outer =<< trim EOT
        EOT
      var inner = 1
    EOT
    var plain =<< EOS
      EOS
    EOS
    var after = 2
  END
  var parsed = parse.Parse(lines)
  assert_equal(['outer', 'plain', 'after'], Names(parsed.symbols))
  assert_equal([2, 3, 4, 6, 7], parsed.heredoc_lines)

  lines =<< trim END
    vim9script
    def F()
      var outer =<< trim EOT
        EOT
      EOT
      var after = 1
    enddef
  END
  parsed = parse.Parse(lines)
  assert_equal(['outer', 'after'], Names(parsed.symbols[0].children))
  assert_equal([3, 4], parsed.heredoc_lines)
enddef

# A comment may follow the end marker of a heredoc, '"' in legacy script and
# "#" under Vim9 rules; with the other one it is not a heredoc for Vim.
def g:Test_parse_heredoc_comment()
  var lines =<< trim END
    let s:statements =<< trim EOL " {{{2
      acceptfiledrop
    EOL
    let s:other =<< trim EOL # {{{2
      allowfullscreen
    EOL
  END
  var parsed = parse.Parse(lines)
  assert_equal([1, 2], parsed.heredoc_lines)
  assert_equal(['E492: Not an editor command: allowfullscreen'],
    parsed.diags->mapnew((_, d) => d.message))

  lines =<< trim END
    vim9script
    var statements =<< trim EOL # {{{2
      acceptfiledrop
    EOL
    var other =<< trim EOL " {{{2
      allowfullscreen
    EOL
  END
  parsed = parse.Parse(lines)
  assert_equal([2, 3], parsed.heredoc_lines)
enddef

# The text of a heredoc assigned to a variable that is there already is not
# read as statements.
def g:Test_parse_assigned_heredoc()
  var lines =<< trim END
    vim9script
    var text: list<string>
    text =<< trim eval EOT
      var inside = 1
    EOT
    g:text =<< EOT
      def Inside()
    EOT
    var after = 1
  END
  var parsed = parse.Parse(lines)
  assert_equal(['text', 'after'], Names(parsed.symbols))
  assert_equal([3, 4, 6, 7], parsed.heredoc_lines)
  assert_equal([], parsed.diags)
enddef

# The script of another language that ":execute" runs, 'execute py "<< EOF"'
# or 'execute "python3 << trim EOF"', is not read as statements; "<<" of
# another command, 'execute "normal <<"', does not start one.
def g:Test_parse_heredoc_of_execute()
  var lines =<< trim END
    func F()
      let py = 'python3'
      execute py "<< EOF"
    def do_something():
      return 1
    EOF
      execute "python3 << trim EOF"
        def other():
          pass
        EOF
      execute "normal <<"
    endfunc
    if 1
  END
  var parsed = parse.Parse(lines)
  assert_equal([3, 4, 5, 7, 8, 9], parsed.heredoc_lines)
  assert_equal(['E171: Missing :endif'],
    parsed.diags->mapnew((_, d) => d.message))
enddef

# The text of ":append", ":change" and ":insert", up to ".", is not read as
# statements, with a range before the command or not; under Vim9 rules there
# is no such command.
def g:Test_parse_append_text()
  var lines =<< trim END
    func F()
      a
    	cmd;
    .
      0insert!
    if 1
    .
      'a,'bc
    endfunc
    .
    endfunc
    if 1
  END
  var parsed = parse.Parse(lines)
  assert_equal([2, 3, 5, 6, 8, 9], parsed.heredoc_lines)
  assert_equal(['E171: Missing :endif'],
    parsed.diags->mapnew((_, d) => d.message))
  parsed = parse.Parse(['vim9script', 'def F()', '  a', 'enddef'])
  assert_equal([], parsed.heredoc_lines)
  # A heredoc assigned to an option or an environment variable holds text,
  # not ":change".
  parsed = parse.Parse(['let &commentstring =<< trim TEXT', '  change',
    'TEXT', 'let $SOME_VAR =<< TEXT', 'insert', 'TEXT', 'if 1'])
  assert_equal([1, 2, 4, 5], parsed.heredoc_lines)
  assert_equal(['E171: Missing :endif'],
    parsed.diags->mapnew((_, d) => d.message))
enddef

# ":loadkeymap" reads the rest of the script as keymap lines, which are not
# statements.
def g:Test_parse_loadkeymap()
  var lines =<< trim END
    let b:keymap_name = "bg"
    loadkeymap
    yi	ы	CYRILLIC SMALL LETTER YERU
    function Inside()
  END
  var parsed = parse.Parse(lines)
  assert_equal(['b:keymap_name'], Names(parsed.symbols))
  assert_equal([2, 3], parsed.heredoc_lines)
  assert_equal([], parsed.diags)
enddef

# vim: ts=2 sw=0 et
