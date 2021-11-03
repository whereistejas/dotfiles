call plug#begin(stdpath('data').'/plugged')
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-dispatch'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-surround'
Plug 'airblade/vim-gitgutter'

" Colorschemes
Plug 'sainnhe/sonokai'
Plug 'rktjmp/lush.nvim'
Plug 'ellisonleao/gruvbox.nvim'
Plug 'sainnhe/edge'

Plug 'whereistejas/rust.vim', { 'branch': 'save_fold_fix' }
Plug 'cespare/vim-toml'

Plug 'neovim/nvim-lspconfig'
Plug 'simrat39/rust-tools.nvim'

" Plug 'neovim/nvim-lspconfig'
" Plug 'nvim-lua/lsp_extensions.nvim'

" Plug 'hrsh7th/nvim-cmp'
" Plug 'hrsh7th/cmp-nvim-lsp'

Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-lua/popup.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-telescope/telescope-fzf-native.nvim', { 'do': 'make' }

" Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
call plug#end()

syntax on
filetype plugin indent on

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
set statusline=[%n]\ %<%t\ %m%r%h%w%y%q[%{&ff}]\ \ %=\ line:%l/%L\ col:%c\ %p%%\ @%{FugitiveStatusline()}
set background=dark
colorscheme sonokai
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
nnoremap 4 <End>
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
nnoremap <leader>fg :Telescope git_bcommits<CR>
nnoremap <leader>d :Telescope lsp_document_symbols<CR>
nnoremap <leader>g :Telescope git_commits<CR>
" }}}

" LSP {{{
nnoremap <silent> <c-]>	   <cmd>lua vim.lsp.buf.definition()<CR>
nnoremap <silent> K        <cmd>lua vim.lsp.buf.hover()<CR>
nnoremap <silent> gD       <cmd>lua vim.lsp.buf.implementation()<CR>
nnoremap <silent> <c-k>    <cmd>lua vim.lsp.buf.signature_help()<CR>
nnoremap <silent> gr       <cmd>lua vim.lsp.buf.references()<CR>
nnoremap <silent> gd       <cmd>lua vim.lsp.buf.declaration()<CR>
nnoremap <silent> ga       <cmd>lua vim.lsp.buf.code_action()<CR>
nnoremap <silent> ge       <cmd>lua vim.lsp.diagnostic.show_line_diagnostics()<CR>
nnoremap <silent> <Tab>    <cmd>lua vim.lsp.diagnostic.goto_next()<CR>
nnoremap <silent> <S-tab>  <cmd>lua vim.lsp.diagnostic.goto_prev()<CR>
" }}}
" }}}

" Tabs, splits and buffers {{{
set splitbelow
set splitright
" }}}

" Rust {{{
let g:rustfmt_autosave = 2
let g:rust_fold = 1
" autocmd Filetype rust set foldmethod=expr
" autocmd Filetype rust set foldexpr=nvim_treesitter#foldexpr()
" }}}

" LSP {{{

lua << EOF
local opts = {
    tools = { -- rust-tools options
        -- Automatically set inlay hints (type hints)
        autoSetHints = true,

        -- Whether to show hover actions inside the hover window
        -- This overrides the default hover handler 
        hover_with_actions = true,

        -- These apply to the default RustSetInlayHints command
        inlay_hints = {

            -- Only show inlay hints for the current line
            only_current_line = false,

            -- Event which triggers a refersh of the inlay hints.
            -- You can make this "CursorMoved" or "CursorMoved,CursorMovedI" but
            -- not that this may cause  higher CPU usage.
            -- This option is only respected when only_current_line and
            -- autoSetHints both are true.
            only_current_line_autocmd = "CursorHold",

            -- wheter to show parameter hints with the inlay hints or not
            show_parameter_hints = true,

            -- prefix for parameter hints
            -- parameter_hints_prefix = "<- ",

            -- prefix for all the other hints (type, chaining)
            -- other_hints_prefix = "=> ",

            -- whether to align to the length of the longest line in the file
            max_len_align = false,

            -- padding from the left if max_len_align is true
            max_len_align_padding = 1,

            -- whether to align to the extreme right or not
            right_align = false,

            -- padding from the right if right_align is true
            right_align_padding = 7,

            -- The color of the hints
            highlight = "Comment",
        },

        hover_actions = {
            -- the border that is used for the hover window
            -- see vim.api.nvim_open_win()
            -- border = {
            --     {"╭", "FloatBorder"}, {"─", "FloatBorder"},
            --     {"╮", "FloatBorder"}, {"│", "FloatBorder"},
            --     {"╯", "FloatBorder"}, {"─", "FloatBorder"},
            --     {"╰", "FloatBorder"}, {"│", "FloatBorder"}
            -- },

            -- whether the hover action window gets automatically focused
            auto_focus = false
        },

    -- all the opts to send to nvim-lspconfig
    -- these override the defaults set by rust-tools.nvim
    -- see https://github.com/neovim/nvim-lspconfig/blob/master/CONFIG.md#rust_analyzer
    server = {
 			checkOnSave = {
 				command = "clippy"
 			},
             assist = {
                 importGranularity = "module",
                 importPrefix = "by_self",
             },
             cargo = {
                 loadOutDirsFromCheck = true
             },
             procMacro = {
                 enable = true
             },
 			completions = {
 				addCallParenthesis = true,
 				addCallArgumentSnippets = true,
 				autoimport = {
 					enable = true
 				},
 			}
		} -- rust-analyer options
	}
}

require('rust-tools').setup(opts)

vim.lsp.handlers["textDocument/publishDiagnostics"] = vim.lsp.with(
	vim.lsp.diagnostic.on_publish_diagnostics, {
		virtual_text = true,
		signs = true,
		update_in_insert = true,
  }
)

EOF


" " Hover to show Diagnostics
" " autocmd CursorHold *.rs lua vim.lsp.diagnostic.show_line_diagnostics()

" }}}

" " Treesitter {{{
" lua <<EOF
" require'nvim-treesitter.configs'.setup {
" 	ensure_installed = 'rust',
"   	highlight = {
" 		enable = true,
"   	  	additional_vim_regex_highlighting = false,
"   	},
" 	indent = {
"     	enable = true
"   	}
" }
" EOF
" " }}}

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
nnoremap <silent> <C-T> :call MonkeyTerminalToggle()<cr>
tnoremap <silent> <C-T> <C-\><C-n>:call MonkeyTerminalToggle()<cr>
" }}}
" vim: ft=vim
