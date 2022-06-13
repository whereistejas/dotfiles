call plug#begin(stdpath('data').'/plugged')
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-dispatch'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-surround'
Plug 'airblade/vim-gitgutter'
Plug 'junegunn/goyo.vim'

" Haskell
Plug 'neovimhaskell/haskell-vim'

" Colorschemes
Plug 'sainnhe/sonokai'
Plug 'rktjmp/lush.nvim'
Plug 'ellisonleao/gruvbox.nvim'
Plug 'sainnhe/edge'
Plug 'rakr/vim-one'
Plug 'cormacrelf/vim-colors-github'

Plug 'whereistejas/rust.vim', { 'branch': 'save_fold_fix' }
Plug 'cespare/vim-toml'

" Collection of common configurations for the Nvim LSP client
Plug 'neovim/nvim-lspconfig'
" Completion framework
Plug 'hrsh7th/nvim-cmp'
" LSP completion source for nvim-cmp
Plug 'hrsh7th/cmp-nvim-lsp'
Plug 'hrsh7th/cmp-vsnip'
Plug 'hrsh7th/cmp-path'
Plug 'hrsh7th/cmp-buffer'
Plug 'hrsh7th/vim-vsnip'

Plug 'simrat39/rust-tools.nvim'

Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-lua/popup.nvim'
Plug 'nvim-lua/lsp-status.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-telescope/telescope-fzf-native.nvim', { 'do': 'make' }

Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
call plug#end()

syntax on
filetype plugin indent on

" Plugin {{{
let g:goyo_linenr = 1
let g:goyo_width = 120
" }}}

" Options {{{
set number
set relativenumber
set cursorline
set incsearch
set hlsearch
set ignorecase
set wildmenu
set wildmode=longest:full,full
set modeline
set termguicolors
set pumblend=30
set winblend=0
set hidden
set undofile
set undodir=~/.config/nvim/undo/
set autowrite
set autoread
set path+=**
set foldmethod=marker
set dictionary=/usr/share/dict/words
set encoding=utf-8
set wrap
set linebreak
set signcolumn=yes:1
set listchars=tab:>\ ,trail:-,nbsp:+,eol:$,
set updatetime=500
set inccommand=nosplit
set mouse=a
set diffopt+=vertical

set rtp+=~/repos/software/fzf

set completeopt=menuone,noinsert,noselect
set shortmess+=c

set clipboard+=unnamedplus

set shiftwidth=4
set tabstop=4
set noexpandtab
" }}}

" Colorscheme and Statusline {{{
set statusline=[%n]       						" Buffer number
set statusline+=\ %f       						" Relative filepath to CWD
set statusline+=\ %m      						" Modified flag
set statusline+=%r      						" Read only flag
set statusline+=%h      						" Helpfile flag
set statusline+=%q      						" Quickfix flag
set statusline+=%w      						" Preview flag
set statusline+=%y      						" Filetype
set statusline+=\ %=      						" Left/right separator
set statusline+=\ %{LspStatus()}				" LSP status
set statusline+=\ L:\ %03.l/%03.L   			" Cursor line/total lines
set statusline+=\ C:\ %03.3c     				" Cursor column
set statusline+=\ P:\ %p    					" Percent through file
set statusline+=\ @%{FugitiveStatusline()}		" Git branch

set background=dark
colorscheme sonokai

let g:sonokai_style = 'andromeda'
let g:sonokai_diagnostic_text_highlight = 1
let g:sonokai_diagnostic_line_highlight = 1
let g:sonokai_diagnostic_virtual_text = 1
" }}}

" Remappings {{{
nnoremap <up> <nop>
nnoremap <down> <nop>
nnoremap <left> <nop>
nnoremap <right> <nop>
inoremap <up> <nop>
inoremap <down> <nop>
inoremap <left> <nop>
inoremap <right> <nop>
nnoremap j gj
nnoremap k gk
nnoremap ; :
nnoremap 1 <End>
nnoremap 5 %
nnoremap qq zczAzz
nnoremap <Space> za
tnoremap <Esc> <C-\><C-n>
nnoremap ? :Telescope live_grep<CR>
nnoremap { <C-U>
nnoremap } <C-D>
nnoremap 0 ^

" Switching buffers {{{
nnoremap <silent> <right> :bn<CR>
nnoremap <silent> <left> :bp<CR>
" }}}

" Switching tabs {{{
nnoremap <silent> <A-right> :tabnext<CR>
nnoremap <silent> <A-left> :tabprevious<CR>
" }}}

" Quickfix {{{
function! ToggleQuickFix()
    if getqflist({'winid' : 0}).winid
        cclose
    else
        copen
    endif
endfunction

command! -nargs=0 -bar ToggleQuickFix call ToggleQuickFix()
nnoremap <silent> <C-q> :ToggleQuickFix<CR>
nnoremap <silent> <C-n> :cnext<CR>
nnoremap <silent> <C-p> :cprev<CR>
" }}}

" Ctrl+h to stop searching {{{
vnoremap <C-h> :nohlsearch<cr>
nnoremap <C-h> :nohlsearch<cr>
" }}}

" Telescope {{{
nnoremap <leader>f :Telescope find_files<CR>
nnoremap <leader>b <cmd>Telescope buffers<cr>
nnoremap <leader>d :Telescope lsp_document_symbols<CR>
nnoremap <leader>g :Telescope git_commits<CR>
" }}}

" LSP {{{
nnoremap <silent> <C-]>	   <cmd>lua vim.lsp.buf.definition()<CR>
nnoremap <silent> <C-I>	   :pop<CR>
nnoremap <silent> <C-I>	   :pop<CR>
nnoremap <silent> K        <cmd>lua vim.lsp.buf.hover()<CR>
nnoremap <silent> gD       <cmd>lua vim.lsp.buf.implementation()<CR>
nnoremap <silent> <C-K>    <cmd>lua vim.lsp.buf.signature_help()<CR>
nnoremap <silent> gr       <cmd>lua vim.lsp.buf.references()<CR>
nnoremap <silent> gd       <cmd>lua vim.lsp.buf.declaration()<CR>
nnoremap <silent> ga       <cmd>lua vim.lsp.buf.code_action()<CR>
nnoremap <silent> gR	   <cmd>lua vim.lsp.buf.rename()<CR>
nnoremap <silent> ge       <cmd>lua vim.diagnostic.open_float()<CR>
nnoremap <silent> <S-tab>  <cmd>lua vim.lsp.diagnostic.goto_prev()<CR>
" }}}

" Git {{{
nnoremap <leader>hh :GitGutterPreviewHunk<CR>
nnoremap <leader>gg :G<CR>
" }}}

" }}}

" Tabs, splits and buffers {{{
set splitbelow
set splitright
" }}}

" Rust {{{
let g:rustfmt_autosave = 1
let g:rust_fold = 1
autocmd Filetype rust set foldmethod=syntax
" autocmd Filetype rust set foldmethod=expr
" autocmd Filetype rust set foldexpr=nvim_treesitter#foldexpr()
" }}}

" LSP {{{
lua <<EOF
local nvim_lsp = require'lspconfig'

local opts = {
    tools = { -- rust-tools options
        autoSetHints = true,
        hover_with_actions = true,
        inlay_hints = {
            show_parameter_hints = true,
            parameter_hints_prefix = "",
            other_hints_prefix = "",
        },
    },

    -- see https://github.com/neovim/nvim-lspconfig/blob/master/CONFIG.md#rust_analyzer
    server = {
        -- on_attach is a callback called when the language server attachs to the buffer
        -- on_attach = on_attach,
        settings = {
            -- to enable rust-analyzer settings visit:
            -- https://github.com/rust-analyzer/rust-analyzer/blob/master/docs/user/generated_config.adoc
            ["rust-analyzer"] = {
                -- enable clippy on save
                checkOnSave = {
                    command = "clippy"
                },
				-- enable proc macro support
				procMacro = {
					enable = true
				},
				cargo = {
					loadOutDirsFromCheck = true,
					runBuildScripts = true
				},
				diagnostics = {
					disabled = {"unresolved-proc-macro"}
				},
				inlayHints = {
					  lifetimeElisionHints = {
							enable = true,
							useParameterNames = true
					  },
				},
            }
        }
    },
}

require('rust-tools').setup(opts)
EOF

" Setup Completion
" See https://github.com/hrsh7th/nvim-cmp#basic-configuration
lua <<EOF
local cmp = require'cmp'
cmp.setup({
	-- Enable LSP snippets
	snippet = {
		expand = function(args)
			vim.fn["vsnip#anonymous"](args.body)
		end,
	},
	mapping = {
		['<C-p>'] = cmp.mapping.select_prev_item(),
		['<C-n>'] = cmp.mapping.select_next_item(),
		-- Add tab support
		['<S-Tab>'] = cmp.mapping.select_prev_item(),
		['<Tab>'] = cmp.mapping.select_next_item(),
		['<C-d>'] = cmp.mapping.scroll_docs(-4),
		['<C-f>'] = cmp.mapping.scroll_docs(4),
		['<C-Space>'] = cmp.mapping.complete(),
		['<C-e>'] = cmp.mapping.close(),
		['<CR>'] = cmp.mapping.confirm({
			  behavior = cmp.ConfirmBehavior.Insert,
			  select = true,
		})
	},

	-- Installed sources
	sources = {
		{ name = 'nvim_lsp' },
		{ name = 'vsnip' },
		{ name = 'path' },
		{ name = 'buffer' },
	},
})
EOF

lua << END
local lsp_status = require('lsp-status')
lsp_status.register_progress()

lsp_status.config({
	indicator_errors = 'E',
	indicator_warnings = 'W',
	indicator_info = 'i',
	indicator_hint = '?',
	indicator_ok = 'Ok',
})

local lspconfig = require('lspconfig')

-- Some arbitrary servers
lspconfig.rust_analyzer.setup({
	on_attach = lsp_status.on_attach,
	capabilities = lsp_status.capabilities
})
END

" Statusline
function! LspStatus() abort
	if luaeval('#vim.lsp.buf_get_clients() > 0')
		return luaeval("require('lsp-status').status()")
	endif

	return ''
endfunction
" }}}

" Treesitter {{{
lua <<EOF
require'nvim-treesitter.configs'.setup {
	ensure_installed = {"rust"},
  	highlight = {
		enable = true,
  	  	additional_vim_regex_highlighting = false,
  	},
	indent = {
    	enable = true
  	},
    incremental_selection = {
        enable = true,
      	keymaps = {
			init_selection = "gv",
			node_incremental = "gvn",
			scope_incremental = "gvs",
			node_decremental = "gvd",
      	},
    }
}
EOF
" }}}

" Telescope {{{
lua <<EOF
require('telescope').setup({  
	defaults = { 
		file_ignore_patterns = { "node_modules", "vendor", "borsh_stable" }
	} 
})
EOF
" }}}

" Terminal toggle {{{
" With this function you can reuse the same terminal in neovim.
" You can toggle the terminal and also send a command to the same terminal.

let s:monkey_terminal_window = -1
let s:monkey_terminal_buffer = -1
let s:monkey_terminal_job_id = -1

function! MonkeyTerminalOpen()
  " Check if buffer exists, if not create a window and a buffer
  if !bufexists(s:monkey_terminal_buffer)
    " Creates a window call monkey_terminal
    new monkey_terminal
    " Moves to the window the right the current one
    " wincmd L
    let s:monkey_terminal_job_id = termopen($SHELL, { 'detach': 1 })

     " Change the name of the buffer to "Terminal 1"
     silent file Terminal\ 1
     " Gets the id of the terminal window
     let s:monkey_terminal_window = win_getid()
     let s:monkey_terminal_buffer = bufnr('%')

    " The buffer of the terminal won't appear in the list of the buffers
    " when calling :buffers command
    set nobuflisted
  else
    if !win_gotoid(s:monkey_terminal_window)
    sp
	resize 15
    " Moves to the window below the current one
    " wincmd L   
    buffer Terminal\ 1
     " Gets the id of the terminal window
     let s:monkey_terminal_window = win_getid()
    endif
  endif
endfunction

function! MonkeyTerminalToggle()
  if win_gotoid(s:monkey_terminal_window)
    call MonkeyTerminalClose()
  else
    call MonkeyTerminalOpen()
  endif
endfunction

function! MonkeyTerminalClose()
  if win_gotoid(s:monkey_terminal_window)
    " close the current window
    hide
  endif
endfunction

" With this maps you can now toggle the terminal
" nnoremap <silent> <C-W> :call MonkeyTerminalToggle()<cr>
" tnoremap <silent> <C-W> <C-\><C-n>:call MonkeyTerminalToggle()<cr>
" }}}

" Haskell {{{
autocmd Filetype haskell set tabstop=2 shiftwidth=2 expandtab
let g:haskell_enable_quantification = 1   " to enable highlighting of `forall`
let g:haskell_enable_recursivedo = 1      " to enable highlighting of `mdo` and `rec`
let g:haskell_enable_arrowsyntax = 1      " to enable highlighting of `proc`
let g:haskell_enable_pattern_synonyms = 1 " to enable highlighting of `pattern`
let g:haskell_enable_typeroles = 1        " to enable highlighting of type roles
let g:haskell_enable_static_pointers = 1  " to enable highlighting of `static`
let g:haskell_backpack = 1                " to enable highlighting of backpack keywords
" }}}
" vim: ft=vim
