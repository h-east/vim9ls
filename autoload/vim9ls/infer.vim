vim9script

# vim9ls - the type of an expression, as the Vim9 compiler infers it
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

# The names whose type is known without asking Vim.
const LITERALS = {true: 'bool', false: 'bool', null: 'special',
  null_list: 'list<any>', null_dict: 'dict<any>', null_string: 'string',
  null_blob: 'blob', null_tuple: 'tuple<any>', null_function: 'func',
  null_partial: 'func', null_job: 'job', null_channel: 'channel',
  'v:true': 'bool', 'v:false': 'bool', 'v:none': 'special',
  'v:null': 'special'}

# The operators, longest first so that ".." is not taken as "." twice.
const OPERATOR = '^\%(\.\.\|->\|=>\|[=!][=~][#?]\=\|[<>]=\=[#?]\=\|&&\|||'
  .. '\|??\|[-+*/%!?:.,()[\]{}]\)'
const NAME = '^\%(<SID>\)\=\%([gvsablwt]:\)\=\h[[:alnum:]_#]*'
const NUMBER = '^\%(0[xX]\x\+\|0[bB][01]\+\|0[zZ]\x*\|0[oO]\=\o\+'
  .. '\|\d\+\.\d\+\%([eE][+-]\=\d\+\)\=\|\d\+\)'

# "expr" as tokens: {k: kind, t: text}.  The kinds are "num", "float", "blob",
# "str", "name", "opt", "env", "reg" and "op"; "is" and "isnot" are "op".
def Tokenize(expr: string): list<dict<string>>
  var tokens: list<dict<string>> = []
  var pos = 0
  var length = strlen(expr)
  while pos < length
    var c = strpart(expr, pos, 1)
    var m: list<any> = ['', -1, -1]
    var kind = 'op'
    if c =~ '\s'
      pos += 1
      continue
    elseif c == "'"
      m = matchstrpos(expr, "^'\\%([^']\\|''\\)*'", pos)
      kind = 'str'
    elseif c == '"'
      m = matchstrpos(expr, '^"\%([^"\\]\|\\.\)*"', pos)
      kind = 'str'
    elseif c =~ '\d'
      m = matchstrpos(expr, NUMBER, pos)
      kind = m[0] =~ '^0[zZ]' ? 'blob' : m[0] =~ '\.' ? 'float' : 'num'
    elseif c == '&' && strpart(expr, pos + 1, 1) =~ '\h'
      m = matchstrpos(expr, '^&\%([lg]:\)\=\h\w*', pos)
      kind = 'opt'
    elseif c == '$' && strpart(expr, pos + 1, 1) =~ '\h'
      m = matchstrpos(expr, '^\$\h\w*', pos)
      kind = 'env'
    elseif c == '@'
      m = [strpart(expr, pos, 2), pos, pos + 2]
      kind = 'reg'
    elseif c =~ '\h' || strpart(expr, pos) =~ '^<SID>'
      m = matchstrpos(expr, NAME, pos)
      kind = m[0] == 'is' || m[0] == 'isnot' ? 'op' : 'name'
    else
      m = matchstrpos(expr, OPERATOR, pos)
    endif
    if m[1] < 0
      # Something the tokenizer does not know, or an unclosed string: what
      # follows cannot be typed.
      break
    endif
    add(tokens, {k: kind, t: m[0]})
    pos = m[2]
  endwhile
  return tokens
enddef

# The parser state: the tokens, where it is, and what the caller knows: the
# types of the variables and of the script's functions.
def NewState(tokens: list<dict<string>>, ctx: dict<any>): dict<any>
  return {tokens: tokens, i: 0,
    vars: ctx->get('vars', {}), funcs: ctx->get('funcs', {})}
enddef

def Peek(st: dict<any>, ahead: number = 0): dict<string>
  return st.tokens->get(st.i + ahead, {k: 'end', t: ''})
enddef

def IsOp(st: dict<any>, text: string, ahead: number = 0): bool
  var tok = Peek(st, ahead)
  return tok.k == 'op' && tok.t == text
enddef

def Next(st: dict<any>): dict<string>
  var tok = Peek(st)
  st.i += 1
  return tok
enddef

# Skips "text" when it is next; the expression may be cut short.
def Skip(st: dict<any>, text: string)
  if IsOp(st, text)
    st.i += 1
  endif
enddef

# The type both "a" and "b" fit, as the compiler takes it: the same type, a
# List or Dict with the member type they share, otherwise "any".
export def Common(a: string, b: string): string
  if a == b
    return a
  endif
  for container in ['list', 'dict']
    if a =~ '^' .. container .. '<' && b =~ '^' .. container .. '<'
      return container .. '<' .. Common(Member(a), Member(b)) .. '>'
    endif
  endfor
  return 'any'
enddef

# The type of an item of List or Dict type "t", "any" for anything else.
export def Member(t: string): string
  var m = matchstr(t, '^\%(list\|dict\)<\zs.*\ze>$')
  return m == '' ? 'any' : m
enddef

# What getinfo() reports, an empty Dict when the name is not known.
export def Info(kind: string, name: string, opts: dict<any> = {}): dict<any>
  try
    return getinfo(kind, name, opts)
  catch
    return {}
  endtry
enddef

# The return type of function type "t", "func(number): string"; "void" when
# it has none, "any" when "t" is not a function type that tells.
export def ReturnOf(t: string): string
  if t !~ '^func('
    return 'any'
  endif
  var depth = 0
  for i in range(4, strlen(t) - 1)
    if t[i] == '('
      depth += 1
    elseif t[i] == ')'
      depth -= 1
      if depth == 0
        return t[i + 1 :] =~ '^: ' ? t[i + 3 :] : 'void'
      endif
    endif
  endfor
  return 'any'
enddef

# The return type of a call of "name" with arguments of types "argtypes":
# the script's own function, else the builtin.
def CallType(st: dict<any>, name: string, argtypes: list<string>): string
  if st.funcs->has_key(name)
    return ReturnOf(st.funcs[name])
  endif
  var info = Info('function', name, {argtypes: argtypes})
  if info->empty()
    # A type the argument list cannot pass, or too many arguments.
    info = Info('function', name)
  endif
  return info->get('returns', 'any')
enddef

# The comma separated expressions up to "closer", which is skipped.
def Arguments(st: dict<any>, closer: string): list<string>
  var types: list<string> = []
  while Peek(st).k != 'end' && !IsOp(st, closer)
    add(types, Expr1(st))
    if !IsOp(st, ',')
      break
    endif
    st.i += 1
  endwhile
  Skip(st, closer)
  return types
enddef

# The index of the ")" that closes the "(" at "st.i".
def CloseOf(st: dict<any>): number
  var depth = 0
  for j in range(st.i, len(st.tokens) - 1)
    var tok = st.tokens[j]
    if tok.k == 'op' && tok.t =~ '^[([{]$'
      depth += 1
    elseif tok.k == 'op' && tok.t =~ '^[)\]}]$'
      depth -= 1
      if depth == 0
        return j
      endif
    endif
  endfor
  return -1
enddef

# Whether the "(" at "st.i", closed at "close", starts a lambda: "=>" follows
# the ")", right away or after the return type.  In "b ? (1) : 2" the ":" is
# the ternary's.
def LambdaAhead(st: dict<any>, close: number): bool
  var after = st.tokens->get(close + 1, {k: 'end', t: ''})
  if after.t == '=>'
    return true
  elseif after.t != ':'
    return false
  endif
  var depth = 0
  for j in range(close + 2, len(st.tokens) - 1)
    var tok = st.tokens[j]
    if tok.k != 'op'
      continue
    elseif tok.t == '=>' && depth == 0
      return true
    elseif tok.t == '<'
      depth += 1
    elseif tok.t == '>'
      depth -= 1
    elseif depth == 0 && tok.t =~ '^[,)\]}]$'
      return false
    endif
  endfor
  return false
enddef

# A lambda "(a, b: type): type => body" from the "(" at "st.i", "close" being
# its ")": the parameters are typed as declared, "any" without a type, the
# result as declared or as the body.
def Lambda(st: dict<any>, close: number): string
  var params: list<string> = []
  var vars = copy(st.vars)
  st.i += 1
  while st.i < close
    var name = Next(st).t
    var ptype = 'any'
    if IsOp(st, ':')
      st.i += 1
      ptype = TypeText(st, [','])
    endif
    add(params, ptype)
    vars[name] = ptype
    Skip(st, ',')
  endwhile
  st.i = close + 1
  var returns = ''
  if IsOp(st, ':')
    st.i += 1
    returns = TypeText(st, ['=>'])
  endif
  Skip(st, '=>')
  var saved = st.vars
  st.vars = vars
  var body = Expr1(st)
  st.vars = saved
  return 'func(' .. join(params, ', ') .. '): '
    .. (returns == '' ? body : returns)
enddef

# The text of a type at "st.i", up to a token in "stops" at the top level or
# the ")" of the lambda parameters; "<" and ">" nest.
def TypeText(st: dict<any>, stops: list<string>): string
  var out = ''
  var depth = 0
  while Peek(st).k != 'end'
    var tok = Peek(st)
    if depth == 0 && tok.k == 'op' && (index(stops, tok.t) >= 0
        || tok.t == ')')
      break
    endif
    if tok.k == 'op' && tok.t == '<'
      depth += 1
    elseif tok.k == 'op' && tok.t == '>'
      depth -= 1
    endif
    # ", " between the members of a tuple or the arguments of a func.
    out ..= (tok.t == ',' ? ', ' : tok.t)
    st.i += 1
  endwhile
  return substitute(out, '^\s*\|\s*$', '', 'g')
enddef

# A list literal from "[".
def ListLiteral(st: dict<any>): string
  st.i += 1
  var types = Arguments(st, ']')
  return 'list<' .. (types->empty() ? 'any' : reduce(types, Common)) .. '>'
enddef

# A dict literal from "{": "{key: value, [expr]: value}".
def DictLiteral(st: dict<any>): string
  st.i += 1
  var types: list<string> = []
  while Peek(st).k != 'end' && !IsOp(st, '}')
    if IsOp(st, '[')
      st.i += 1
      Expr1(st)
      Skip(st, ']')
    else
      st.i += 1
    endif
    Skip(st, ':')
    add(types, Expr1(st))
    if !IsOp(st, ',')
      break
    endif
    st.i += 1
  endwhile
  Skip(st, '}')
  return 'dict<' .. (types->empty() ? 'any' : reduce(types, Common)) .. '>'
enddef

# A primary expression: a literal, a name, or what parentheses hold: a
# grouping, a tuple or a lambda.
def Primary(st: dict<any>): string
  var tok = Peek(st)
  if tok.k == 'num' || tok.k == 'float' || tok.k == 'blob'
    st.i += 1
    return tok.k == 'num' ? 'number' : tok.k
  elseif tok.k == 'str' || tok.k == 'env' || tok.k == 'reg'
    st.i += 1
    return 'string'
  elseif tok.k == 'opt'
    st.i += 1
    return Info('option', substitute(tok.t, '^&\%([lg]:\)\=', '', ''))
      ->get('type', 'any')
  elseif tok.k == 'name'
    st.i += 1
    if tok.t == 'new' && Peek(st).k == 'name'
      var class = Next(st).t
      if IsOp(st, '(')
        st.i += 1
        Arguments(st, ')')
      endif
      return 'object<' .. class .. '>'
    endif
    if LITERALS->has_key(tok.t)
      return LITERALS[tok.t]
    endif
    if tok.t =~ '^v:'
      return Info('vimvar', tok.t)->get('type', 'any')
    endif
    if st.vars->has_key(tok.t)
      return st.vars[tok.t]
    endif
    # A function or a class by name: Postfix() types the call or the member.
    if IsOp(st, '(') || IsOp(st, '.')
      return '(' .. tok.t
    endif
    return st.funcs->get(tok.t, 'any')
  elseif tok.k == 'op' && tok.t == '['
    return ListLiteral(st)
  elseif tok.k == 'op' && tok.t == '{'
    return DictLiteral(st)
  elseif tok.k == 'op' && tok.t == '('
    var close = CloseOf(st)
    if close > 0 && LambdaAhead(st, close)
      return Lambda(st, close)
    endif
    st.i += 1
    var types = Arguments(st, ')')
    if len(types) == 1 && !IsOp(st, ',', -2)
      return types[0]
    endif
    return 'tuple<' .. join(types, ', ') .. '>'
  endif
  st.i += 1
  return 'any'
enddef

# A primary with what follows it: an index or slice, a member, a call, a
# method call.
def Postfix(st: dict<any>): string
  var t = Primary(st)
  while true
    if IsOp(st, '[')
      st.i += 1
      var slice = false
      if !IsOp(st, ':')
        Expr1(st)
      endif
      if IsOp(st, ':')
        slice = true
        st.i += 1
        if !IsOp(st, ']')
          Expr1(st)
        endif
      endif
      Skip(st, ']')
      if slice
        t = t =~ '^\%(list<\|string$\|blob$\)' ? t : 'any'
      else
        t = t =~ '^\%(list\|dict\)<' ? Member(t)
          : t == 'string' ? 'string' : t == 'blob' ? 'number' : 'any'
      endif
    elseif IsOp(st, '.') && Peek(st, 1).k == 'name'
      st.i += 1
      var member = Next(st).t
      if IsOp(st, '(')
        st.i += 1
        Arguments(st, ')')
        # "Class.new()" builds an object; another method is not known here.
        t = member == 'new' && t =~ '^([A-Z]' ? 'object<' .. t[1 :] .. '>'
          : 'any'
      else
        t = t =~ '^dict<' ? Member(t) : 'any'
      endif
    elseif IsOp(st, '(') && t[0] == '('
      # The name Primary() left for a call.
      st.i += 1
      t = CallType(st, t[1 :], Arguments(st, ')'))
    elseif IsOp(st, '->') && Peek(st, 1).k == 'name' && IsOp(st, '(', 2)
      st.i += 1
      var name = Next(st).t
      st.i += 1
      t = CallType(st, name, [t] + Arguments(st, ')'))
    else
      break
    endif
  endwhile
  return t[0] == '(' ? 'func' : t
enddef

# Unary "!", "-", "+" and a type cast "<type>".
def Expr7(st: dict<any>): string
  if IsOp(st, '!')
    st.i += 1
    Expr7(st)
    return 'bool'
  elseif IsOp(st, '-') || IsOp(st, '+')
    st.i += 1
    var t = Expr7(st)
    return t == 'float' ? 'float' : 'number'
  elseif IsOp(st, '<')
    st.i += 1
    var cast = TypeText(st, ['>'])
    Skip(st, '>')
    Expr7(st)
    return cast
  endif
  return Postfix(st)
enddef

# "*", "/" and "%".
def Expr6(st: dict<any>): string
  var t = Expr7(st)
  while IsOp(st, '*') || IsOp(st, '/') || IsOp(st, '%')
    st.i += 1
    var right = Expr7(st)
    t = t == 'float' || right == 'float' ? 'float' : 'number'
  endwhile
  return t
enddef

# "+", "-" and "..".
def Expr5(st: dict<any>): string
  var t = Expr6(st)
  while IsOp(st, '+') || IsOp(st, '-') || IsOp(st, '..')
    var op = Next(st).t
    var right = Expr6(st)
    if op == '..'
      t = 'string'
    elseif t == 'float' || right == 'float'
      t = 'float'
    elseif t =~ '^list<' && right =~ '^list<'
      t = Common(t, right)
    elseif t == 'blob' && right == 'blob'
      t = 'blob'
    else
      t = 'number'
    endif
  endwhile
  return t
enddef

# A comparison.
def Expr4(st: dict<any>): string
  var t = Expr5(st)
  var tok = Peek(st)
  if tok.k == 'op' && tok.t =~ '^\%([=!][=~]\|[<>]=\=\|is\|isnot\)'
    st.i += 1
    Expr5(st)
    return 'bool'
  endif
  return t
enddef

# "&&".
def Expr3(st: dict<any>): string
  var t = Expr4(st)
  while IsOp(st, '&&')
    st.i += 1
    Expr4(st)
    t = 'bool'
  endwhile
  return t
enddef

# "||".
def Expr2(st: dict<any>): string
  var t = Expr3(st)
  while IsOp(st, '||')
    st.i += 1
    Expr3(st)
    t = 'bool'
  endwhile
  return t
enddef

# "a ? b : c" and "a ?? b".
def Expr1(st: dict<any>): string
  var t = Expr2(st)
  if IsOp(st, '?')
    st.i += 1
    var yes = Expr1(st)
    Skip(st, ':')
    var no = Expr1(st)
    return yes == no ? yes : Common(yes, no)
  elseif IsOp(st, '??')
    st.i += 1
    var other = Expr1(st)
    return t == other ? t : 'any'
  endif
  return t
enddef

# The type of "expr" in Vim9 script, "any" when it cannot be told.  "ctx" may
# give "vars", the types of the variables by name, and "funcs", the types of
# the functions of the script by name, "func(number): string".  Builtin
# functions are asked of Vim with getinfo().
export def TypeOf(expr: string, ctx: dict<any> = {}): string
  var tokens = Tokenize(expr)
  if tokens->empty()
    return 'any'
  endif
  return Expr1(NewState(tokens, ctx))
enddef
