if exists('b:current_syntax')
  finish
endif

syntax case match
syntax include @avdlJson syntax/json.vim
unlet! b:current_syntax

syntax keyword avdlTodo TODO FIXME XXX contained
syntax region avdlComment start='/\*' end='\*/' contains=avdlTodo,@Spell
syntax match avdlComment '//.*$' contains=avdlTodo,@Spell
syntax keyword avdlDeclaration protocol record error enum fixed schema namespace
syntax keyword avdlStatement import idl protocol schema throws oneway
syntax keyword avdlType array map union boolean bytes double float int long null string void
syntax keyword avdlType date time_ms timestamp_ms local_timestamp_ms uuid decimal
syntax keyword avdlBoolean true false
syntax region avdlString start='"' skip='\\.' end='"'
syntax region avdlIdentifier start='`' end='`'
syntax match avdlAnnotation '@[A-Za-z_][A-Za-z0-9_.]*'
syntax match avdlNumber '\<\d\+\(\.\d\+\)\?\([eE][+-]\?\d\+\)\?\>'
syntax region avdlDefault matchgroup=avdlOperator start='=' end='\ze[,;)]' contains=@avdlJson

highlight default link avdlTodo Todo
highlight default link avdlComment Comment
highlight default link avdlDeclaration Structure
highlight default link avdlStatement Keyword
highlight default link avdlType Type
highlight default link avdlBoolean Boolean
highlight default link avdlString String
highlight default link avdlIdentifier Identifier
highlight default link avdlAnnotation PreProc
highlight default link avdlNumber Number
highlight default link avdlOperator Operator

let b:current_syntax = 'avdl'
