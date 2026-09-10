vim9script

import autoload '../autoload/vim9ls/parse.vim'
import autoload '../autoload/vim9ls/wrap.vim'

def Wrapped(lines: list<string>): list<string>
  return wrap.Lines(parse.Parse(lines), lines)
enddef

def g:Test_wrap_script_level()
  var lines =<< trim END
    vim9script
    import autoload './util.vim'
    export def Exported(): number
      return 1
    enddef
    var typed: string = system('date')
    var untyped = Exported()
    export var shared = 3
    const LIMIT = 10
    final NAME =<< trim EOT
      text
    EOT
    var [first, second] = [1, 2]
    var d = {
      a: 1,
    }
    var later: number
    class C
      var x: number
    endclass
    type Alias = list<string>
    if has('win32')
      def Platform(): string
        return 'win'
      enddef
    endif
    command! -nargs=1 Cmd echo <q-args>
    echo undefined_name
    finish
    defcompile
  END
  var expected =<< trim END





    typed = system('date')
    untyped = Exported()
    shared = 3
    var LIMIT_dryrun = 10
    var NAME_dryrun =<< trim EOT
      text
    EOT
    [first, second] = [1, 2]
    d = {
      a: 1,
    }





    if has('win32')



    endif
    command! -nargs=1 Cmd echo <q-args>
    echo undefined_name
    return

  END
  # The trim leaves the indent of a blank line as is; compare without it.
  assert_equal(expected->mapnew((_, l) => l =~ '^\s*$' ? '' : l),
    Wrapped(lines))
enddef

# A user command is left out, its continuation lines with it: a plugin or a
# ":command" the dry run skipped may define it.  A declaration inside a block
# stays a declaration, the block ends its scope.
def g:Test_wrap_commands_and_blocks()
  var lines =<< trim END
    vim9script
    Plug 'vim-jp/vimdoc-ja'
    Plug 'x/y', {
      \ 'on': 'Y',
      \ }
    Log
    Cmd! arg
    Value = 1
    Value += 1
    Func()
    Obj.method()
    List[0] = 1
    Name .. 's'
    F->call()
    if has('iconv')
      var enc = 'euc-jp'
      const LIMIT = 1
      enc = 'eucjp-ms'
    endif
    var top = 1
  END
  var expected =<< trim END







    Value = 1
    Value += 1
    Func()
    Obj.method()
    List[0] = 1
    Name .. 's'
    F->call()
    if has('iconv')
      var enc = 'euc-jp'
      const LIMIT = 1
      enc = 'eucjp-ms'
    endif
    top = 1
  END
  assert_equal(expected->mapnew((_, l) => l =~ '^\s*$' ? '' : l),
    Wrapped(lines))
enddef

# A legacy function and a command keep their lines out of and in the body.
def g:Test_wrap_legacy_function()
  var lines =<< trim END
    vim9script
    function Old()
      return 1
    endfunction
    Old()
  END
  assert_equal(['', '', '', '', 'Old()'], Wrapped(lines))
enddef

# vim: ts=2 sw=0 et
