let s:lint = {}

function! project_lint#new(linters, data, queue, file_explorers) abort
  return s:lint.new(a:linters, a:data, a:queue, a:file_explorers)
endfunction

function! s:lint.new(linters, data, queue, file_explorers) abort
  let l:instance = copy(self)
  let l:instance.linters = a:linters
  let l:instance.data = a:data
  let l:instance.queue = a:queue
  let l:instance.file_explorers = a:file_explorers
  let l:instance.running = v:false
  let l:instance.queue.on_single_job_finish = function(l:instance.single_job_finished, [], l:instance)
  let l:instance.initialized = v:false
  return l:instance
endfunction

function! s:lint.init() abort
  if !project_lint#utils#check_jobs_support()
    return project_lint#utils#error('Vim 8.* with "jobs" feature required.')
  endif

  if !self.file_explorers.has_valid_file_explorer()
    return project_lint#utils#error('No file explorer found. Install NERDTree, defx.nvim or vimfiler.')
  endif

  if has('timers')
    return timer_start(g:project_lint#init_delay, self.setup)
  endif

  return self.setup()
endfunction

function! s:lint.setup(...) abort
  call self.linters.load()
  call self.file_explorers.register()
  let self.initialized = v:true
  return self.run()
endfunction

function! s:lint.on_vim_leave() abort
  return self.queue.handle_vim_leave()
endfunction

function! s:lint.handle_dir_change(event) abort
  if a:event.scope !=? 'global'
    return a:event
  endif

  let l:new_root = project_lint#utils#get_project_root()
  if l:new_root ==? g:project_lint#root
    return a:event
  endif

  let g:project_lint#root = l:new_root
  return self.init()
endfunction

function! s:lint.run() abort
  if !self.initialized || self.is_project_ignored()
    return
  endif

  if self.running
    return project_lint#utils#error('Project lint already running.')
  endif

  let l:has_cache = self.data.check_cache()

  if l:has_cache
    call self.file_explorers.trigger_callbacks()
  endif

  for l:linter in self.linters.get()
    if l:linter.check_executable() && l:linter.detect()
      call self.set_running(l:linter, '')
      call self.queue.add(l:linter)
    endif
  endfor
  return project_lint#utils#update_statusline()
endfunction

function! s:lint.set_running(linter, file) abort
  let self.running = v:true
  let l:cmd = !empty(a:file) ? a:linter.file_command(a:file) : a:linter.command()

  call project_lint#utils#debug(printf(
        \ 'Linter [%s] running command for [%s]: "%s"',
        \ a:linter.name,
        \ !empty(a:file) ? a:file : 'project',
        \ l:cmd
        \ ))
endfunction

function! s:lint.run_file(file) abort
  if !self.initialized || !empty(&buftype) || self.is_project_ignored()
    return
  endif

  if !self.should_lint_file(a:file)
    return
  endif

  for l:linter in self.linters.get()
    if l:linter.check_executable() && l:linter.detect_for_file()
      if self.queue.already_linting_file(l:linter, a:file)
        continue
      endif

      call self.set_running(l:linter, a:file)
      call self.queue.add_file(l:linter, a:file)
    endif
  endfor
  return project_lint#utils#update_statusline()
endfunction

function! s:lint.should_lint_file(file) abort
  return stridx(a:file, g:project_lint#root) ==? 0
endfunction

function! s:lint.single_job_finished(linter, is_queue_empty, trigger_callbacks, ...) abort
  let l:type = a:0 > 0 ? a:1 : 'project'
  call project_lint#utils#debug(printf('Linter [%s] for [%s] finished.', a:linter.name, l:type))
  call project_lint#utils#update_statusline()

  if a:trigger_callbacks && !a:is_queue_empty
    call project_lint#utils#debug(printf(
          \ 'Refreshing file explorer after linter [%s] finished linting [%s].'
          \ , a:linter.name,
          \ l:type))
    call call(self.file_explorers.trigger_callbacks, a:000)
  endif

  if !a:is_queue_empty
    return
  endif

  call project_lint#utils#debug(
        \ 'All linters finished running. Switching to fresh data and caching it to a file.'
        \ )
  let self.running = v:false
  call self.data.use_fresh_data()
  call call(self.file_explorers.trigger_callbacks, a:000)
  return self.data.cache_to_file()
endfunction

function! s:lint.is_project_ignored() abort
  return index(g:project_lint#ignored_folders, g:project_lint#root) > -1
endfunction
