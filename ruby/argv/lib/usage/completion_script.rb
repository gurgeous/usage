module Usage
  class CompletionScript
    BASH = <<~'BASH'
      _usage_complete_{bin}() {
          local out line files=
          out="$(command '{bin}' __complete_word__ --shell bash --line "${COMP_LINE:0:$COMP_POINT}" 2>/dev/null)" || return 1
          COMPREPLY=()
          while IFS= read -r line; do
              case "$line" in
                  $'\001files') files=any ;;
                  $'\001dirs') files=dirs ;;
                  $'\001executables') files=executables ;;
                  $'\001commands') files=commands ;;
                  '') ;;
                  *) COMPREPLY+=("$line") ;;
              esac
          done <<< "$out"
          if [[ -n $files ]]; then
              [[ $files == commands ]] || compopt -o filenames 2>/dev/null
              local cur="${COMP_WORDS[COMP_CWORD]}" path
              local -a paths=()
              if [[ $files == commands ]]; then
                  while IFS= read -r path; do paths+=("$path"); done < <(compgen -c -- "$cur")
              elif [[ $files == dirs ]]; then
                  while IFS= read -r path; do paths+=("$path"); done < <(compgen -d -- "$cur")
              else
                  while IFS= read -r path; do
                      [[ $files != executables || -d "$path" || -x "$path" ]] && paths+=("$path")
                  done < <(compgen -f -- "$cur")
              fi
              (( ${#paths[@]} )) && COMPREPLY+=("${paths[@]}")
          fi
      }
      complete -F _usage_complete_{bin} '{bin}'
    BASH

    FISH = <<~'FISH'
      function __usage_complete_{bin}
          set -l line (commandline -cp)
          set -l out (command '{bin}' __complete_word__ --shell fish --line "$line" 2>/dev/null)
          set -l marker_any (printf '\x01files')
          set -l marker_dirs (printf '\x01dirs')
          set -l marker_executables (printf '\x01executables')
          set -l marker_commands (printf '\x01commands')
          set -l files ""
          for entry in $out
              if test "$entry" = "$marker_any"
                  set files any
              else if test "$entry" = "$marker_dirs"
                  set files dirs
              else if test "$entry" = "$marker_executables"
                  set files executables
              else if test "$entry" = "$marker_commands"
                  set files commands
              else if test -n "$entry"
                  printf '%s\n' $entry
              end
          end
          switch $files
              case any
                  __fish_complete_path (commandline -ct)
              case dirs
                  __fish_complete_directories (commandline -ct)
              case executables
                  for candidate in (__fish_complete_path (commandline -ct))
                      set -l value (string split -m 1 (printf '\t') -- $candidate)[1]
                      if test -d "$value"; or test -x "$value"
                          printf '%s\n' $candidate
                      end
                  end
              case commands
                  __fish_complete_command (commandline -ct)
          end
      end
      complete -c '{bin}' -f -a '(__usage_complete_{bin})'
    FISH

    NU = <<~'NU'
      def --env __usage_complete_{ident} [spans: list<string>] {
          let line = ($spans | each {|span|
              if ($span | str contains " ") { $'"($span)"' } else { $span }
          } | str join " ")
          let out = (^{bin} __complete_word__ --shell nu --line $line | complete)
          if $out.exit_code != 0 { return null }
          let lines = ($out.stdout | lines | where {|line| $line != "" })
          let marker = "\u{1}"
          let wants_files = ($lines | any {|line| $line == $marker + "files" or $line == $marker + "dirs" or $line == $marker + "executables" })
          let wants_commands = ($lines | any {|line| $line == $marker + "commands" })
          let declared = (
              $lines
              | where {|line| not ($line | str starts-with $marker) }
              | each {|line|
                  let parts = ($line | split row (char tab))
                  {
                      value: ($parts | get 0)
                      description: (if ($parts | length) > 1 { $parts | get 1 } else { "" })
                  }
              }
          )
          let commands = (if $wants_commands {
              let prefix = ($spans | last)
              let insensitive = $nu.os-info.name == "windows"
              let match_prefix = if $insensitive { $prefix | str lowercase } else { $prefix }
              which
              | where {|row|
                  let candidate = if $insensitive { $row.command | str lowercase } else { $row.command }
                  $candidate | str starts-with $match_prefix
              }
              | each {|row| { value: $row.command, description: $row.path } }
          } else {
              []
          })
          let candidates = ($declared | append $commands)
          let command_is_path = (($spans | last) | str contains "/") or (($spans | last) | str contains "\\")
          let wants_path_fallback = $wants_files or ($wants_commands and $command_is_path)
          if ($candidates | is-empty) and $wants_path_fallback { null } else { $candidates }
      }
      let __usage_previous_{ident} = ($env.config.completions.external.completer? | default null)
      $env.config.completions.external.completer = {|spans|
          if ($spans | get 0) == "{bin}" {
              __usage_complete_{ident} $spans
          } else if $__usage_previous_{ident} != null {
              do $__usage_previous_{ident} $spans
          } else {
              null
          }
      }
    NU

    POWERSHELL = <<~POWERSHELL
      Register-ArgumentCompleter -Native -CommandName '{bin}' -ScriptBlock {
          param($wordToComplete, $commandAst, $cursorPosition)
          $extent = $commandAst.Extent
          $offset = [Math]::Max(0, [Math]::Min($cursorPosition - $extent.StartOffset, $extent.Text.Length))
          $line = $extent.Text.Substring(0, $offset)
          $out = @(& '{bin}' __complete_word__ --shell powershell --line $line 2>$null)
          $marker = [char]1
          $files = $null
          $results = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
          foreach ($entry in $out) {
              if ([string]::IsNullOrEmpty($entry)) { continue }
              if ($entry -eq ($marker + 'files')) { $files = 'any'; continue }
              if ($entry -eq ($marker + 'dirs')) { $files = 'dirs'; continue }
              if ($entry -eq ($marker + 'executables')) { $files = 'executables'; continue }
              if ($entry -eq ($marker + 'commands')) { $files = 'commands'; continue }
              $parts = $entry -split "`t", 2
              $value = $parts[0]
              $description = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $value }
              $results.Add([System.Management.Automation.CompletionResult]::new($value, $value, 'ParameterValue', $description))
          }
          if ($files -eq 'commands') {
              foreach ($command in Get-Command -Name ($wordToComplete + '*') -CommandType Application, ExternalScript -ErrorAction SilentlyContinue) {
                  $results.Add([System.Management.Automation.CompletionResult]::new($command.Name, $command.Name, 'Command', $command.Source))
              }
          } elseif ($files) {
              foreach ($path in [System.Management.Automation.CompletionCompleters]::CompleteFilename($wordToComplete)) {
                  if ($files -eq 'dirs' -and $path.ResultType -ne 'ProviderContainer') { continue }
                  if ($files -eq 'executables' -and $path.ResultType -ne 'ProviderContainer') {
                      $candidate = $path.CompletionText.Trim([char[]]@([char]39, [char]34))
                      if (-not (Get-Command -Name $candidate -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)) { continue }
                  }
                  $results.Add($path)
              }
          }
          $results
      }
    POWERSHELL

    ZSH = <<~'ZSH'
      _{bin}() {
          local -a values=() descriptions=() inserts=()
          local files= line menu=0
          while IFS= read -r line; do
              case "$line" in
                  $'\001files') files=any; continue ;;
                  $'\001dirs') files=dirs; continue ;;
                  $'\001executables') files=executables; continue ;;
                  $'\001commands') files=commands; continue ;;
                  '') continue ;;
              esac
              local -a parts=("${(@ps:\t:)line}")
              values+=("${parts[1]}"); descriptions+=("${parts[2]}"); inserts+=("${parts[3]}")
              [[ "${parts[3]}" == "'"* ]] && menu=1
          done < <(command '{bin}' __complete_word__ --shell zsh --line "${BUFFER[1,CURSOR]}" 2>/dev/null)
          local ret=1
          (( menu )) && compstate[insert]=menu
          if (( ${#inserts[@]} )); then
              local -a display=()
              local i max=0 value pad
              for value in "${values[@]}"; do
                  (( ${#value} > max )) && max=${#value}
              done
              for (( i = 1; i <= ${#values[@]}; i++ )); do
                  if [[ -n "${descriptions[i]}" ]]; then
                      pad=$(( max - ${#values[i]} ))
                      display+=("${values[i]}${(l:pad:: :)}  -- ${descriptions[i]}")
                  else
                      display+=("${values[i]}")
                  fi
              done
              compadd -l -d display -U -Q -S '' -a inserts && ret=0
          fi
          case "$files" in
              any) _files && ret=0 ;;
              dirs) _files -/ && ret=0 ;;
              executables) _files -g '*(-/,*)' && ret=0 ;;
              commands) _command_names && ret=0 ;;
          esac
          return $ret
      }
      if [ "$funcstack[1]" = "_{bin}" ]; then
          _{bin} "$@"
      else
          compdef _{bin} '{bin}'
      fi
    ZSH

    attr_reader(*%i[bin shell])

    def initialize(bin, shell)
      raise ArgumentError, "binary name must be one plain shell word" unless bin.match?(/\A[A-Za-z0-9_.+-]+\z/)

      @bin = bin
      @shell = normalize_shell(shell)
    end

    def render
      header = "# @generated by usage for `#{bin} __complete_word__ --shell #{shell}`\n"
      script = template.gsub("{bin}", bin).gsub("{ident}", nu_ident)
      (shell == :zsh) ? "#compdef #{bin}\n#{header}#{script}" : "#{header}#{script}"
    end

    private

    def normalize_shell(value)
      value = value.to_s.downcase.to_sym
      value = :nu if value == :nushell
      value = :powershell if value == :pwsh
      raise ArgumentError, "unsupported shell: #{value}" unless %i[bash fish nu powershell zsh].include?(value)

      value
    end

    def nu_ident
      bin.each_char.map { _1.match?(/[A-Za-z0-9]/) ? _1 : "_x#{_1.ord.to_s(16).rjust(2, "0")}" }.join
    end

    def template
      {bash: BASH, fish: FISH, nu: NU, powershell: POWERSHELL, zsh: ZSH}.fetch(shell)
    end
  end
end
