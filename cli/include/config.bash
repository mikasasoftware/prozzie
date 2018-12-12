#!/usr/bin/env bash

# Prozzie - Wizzie Data Platform (WDP) main entrypoint
# Copyright (C) 2018 Wizzie S.L.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# Reads user input, using readline completions interface to fill paths.
# Arguments:
#  $1 - Variable to store user introduced text
#  $2 - Prompt to user
#  $3 - Default answer (optional)
zz_read_path () {
    read -e -i "$3" -r -p "$2: " "$1"
}

# Reads user input, forbidding tab (or other keys) completions but enabling
# the rest of readline features, like navigate through arrow keys
# Arguments:
#  $1 - Variable to store user introduced text
#  $2 - Prompt to user
#  $3 - Default answer (optional)
zz_read () {
    read -r "$1" < <(
        # Process substitution avoids overriding complete un-binding. Another
        # way, exiting with Ctrol-C would cause binding ruined.
        bind -u 'complete' 2>/dev/null
        zz_read_path "$1" "$2" "$3" >/dev/tty
        printf '%s' "${!1}"
    )
}

# ZZ variables treatment. Checks if an environment variable is defined, and ask
# user for value if not. It will check with a dry-run of config module set.
# After that, Save the variable in the environment one.
# Arguments:
#  [--no-check-valid] Do not check if the value is valid
#  $1 The connector name
#  $2 The variable name.
#  $3 Default value if empty text introduced ("" for error raising)
#  $4 Question text
# Environment:
#  module_envs - Associated array to update.
#
# Out:
#  User Interface
#
# Exit status:
#  Always 0
zz_variable () {
  declare new_value check_for_valid=y

  if [[ $1 == --no-check-valid ]]; then
    check_for_valid=n
    shift
  fi

  declare -r module="$1"
  declare default="$3"
  shift

  if [[ -v $1 ]]; then
    declare -r env_provided=y
  else
    declare -r env_provided=n
  fi

  if [[ "$1" == PREFIX || "$1" == *_PATH ]]; then
    declare -r read_callback=zz_read_path
  else
    declare -r read_callback=zz_read
  fi

  if func_exists "$1_hint" && [[ -z "$default" ]]; then
    default=$("$1_hint")
  fi
  declare -r default

  while [[ -z "${!1}" || $env_provided == y ]]; do
    if [[ $env_provided == n ]]; then
      "$read_callback" "$1" "$3" "$default"
    fi

    if [[ -z "${!1}" && -z "$default" ]]; then
      log fail "Empty $1 not allowed"$'\n'
      continue
    fi

    # Check if the value is valid
    if [[ $check_for_valid == n ]]; then
      new_value="${!1}"
    elif ! new_value=$("${PREFIX}/bin/prozzie" config set --no-reload-prozzie \
                                           "$module" --dry-run "$1=${!1}"); then
      if [[ $env_provided == y ]]; then
        # Tried to force and it fails
        exit 1
      fi

      unset -v "$1"
      continue
    else
      new_value="${new_value#*=}"
    fi

    # Set environment variable to actual new value
    printf -v "$1" '%s' "${new_value#*=}"
    break
  done
}

# Update zz variables array default values using a docker-compose .env file. If
# variable it's not contained in module_envs, copy it to .env file
# Arguments:
#  1 - File to read previous values
#
# Environment:
#  module_envs - Associated array to update and iterate searching for variables
#
# Out:
#  -
#
# Exit status:
#  Always 0
zz_variables_env_update_array () {
  declare prompt var_key var_val
  while IFS='=' read -r var_key var_val || [[ -n "$var_key" ]]; do
    if ! exists_key_in_module_envs "$var_key"; then
      continue
    fi

    # Update zz variable
    prompt="${module_envs[$var_key]#*|}"
    module_envs[$var_key]=$(printf "%s|%s" "$var_val" "$prompt").
  done < "$1"
}

# Print a warning saying that "$src_env_file" has not been modified.
# Arguments:
#  -
#
# Environment:
#  src_env_file - Original file to print in warning. It will print no message if
#  it does not exist or if it is under /dev/fd/.
#
# Out:
#  -
#
# Exit status:
#  Always 0
print_not_modified_warning () {
    echo
    if [[ "$src_env_file" != '/dev/fd/'* && -f "$src_env_file" ]]; then
        log warn "No changes made to $src_env_file"$'\n'
    fi
}

# Print value of variable.
# Arguments:
#  1 - File from get variables
#  2 - Key to filter
# Environment:
#  -
#
# Out:
#  -
#
# Exit status:
#  Always 0
zz_get_var() {
        grep "${2}" "${1}"|sed 's/^'"${2}"'=//'
}

# Print value of all variables.
# Arguments:
#  1 - File from get variables
#  @ - What variables to get. It will get all module variables if empty.
#
# Environment:
#  module_envs - Array of variables
#
# Out:
#  -
#
# Exit status:
#  Always 0
zz_get_vars () {
        declare -r env_file="$1"
        shift

        # If keys list is empty then show all variables
        if [[ $# -eq 0 ]]; then
            declare -A env_content
            # Read from env_file
            while IFS='=' read -r key val || [[ -n "$key" ]]; do
                env_content[$key]=$val
            done < "$env_file"
            # Show variables
            for key in "${!module_envs[@]}"; do
                declare value=${env_content[$key]}
                if [[ -n  $value ]]; then
                        printf '%s=%s\n' "$key" "$value"
                fi
            done
        fi

        for key in "$@"; do
            zz_get_var "$env_file" "$key" || \
                                           printf "Key '%s' is not valid" "$key"
        done
}

# Set variable in env file and prints it in order to check sanitations applied.
# Arguments:
#  [[ --dry-run ]] Do not change anything in env file or in actual variables
#  1 - File from get variables
#  2 - Variable to set
#  3 - Value to set
# Environment:
#  -
#
# Out:
#  New key=val
#
# Exit status:
#  0 - Variable is set without error
#  1 - An error has ocurred while set a variable (variable not found or mispelled)
zz_set_var () {
    declare dry_run=n key_value file
    if [[ $1 == --dry-run ]]; then
        dry_run=y
        shift
    fi

    if ! exists_key_in_module_envs "$2"; then
        printf "Variable '%s' not recognized! No changes made to %s\\n" \
                                                                   "$2" "$1" >&2
        return 1
    fi

    declare value="$3"
    if func_exists "$2_sanitize" && ! value="$("$2_sanitize" "${3}")"; then
        # Can't sanitize value from command line
        return 1
    fi

    printf -v key_value "%s=%s" "$2" "$value"
    printf '%s\n' "$key_value"

    if [[ $dry_run == y ]]; then
        return 0
    fi

    declare -a env_files=("$1")
    declare -r is_dot_env_variable="$2_is_dot_env"
    if [[ ${!is_dot_env_variable:=n} == y ]]; then
        env_files+=("${PREFIX}/etc/prozzie/.env")
    fi

    for file in "${env_files[@]}"; do
        # Can suppress stderr: If no such file, printf will try to create it
        if grep -q . "$file" 2>/dev/null; then
            # shellcheck disable=SC2094
            sed -n -e "/^$2=/!p; \$a$key_value" < "$file" | zz_sponge "$file"
            #         ^^^^^^^^^^
            #         Do not copy non interesting values
            #                    ^^^^^^^^^^^^^^^
            #                    Append interesting values
        else
            # Sed does not work with empty files
            printf '%s\n' "$key_value" > "$file"
        fi
    done
}

# Check and set a list of key-value pairs separated by delimiter
# Arguments:
#  [[--dry-run]] - Do not make any actual change
#  1 - File from get variables
#  2 - List of key-value pairs separated by delimiter
# Environment:
#  -
#
# Out:
#  -
#
# Exit status:
#  Always 0
zz_set_vars () {
    declare key val

    declare dry_run_arg
    if [[ "$1" == '--dry-run' ]]; then
        dry_run_arg=--dry-run
        shift
    fi

    declare -r env_file="$1"
    shift

    if [[ -z $dry_run_arg ]]; then
        # Check that all parameters are OK before do any change
        zz_set_vars --dry-run "$env_file" "$@" >/dev/null || return 1
        dry_run_arg=
    fi
    declare -r dry_run_arg

    for pair in "$@"; do
        if [[ $pair != *=* ]]; then
            printf "The argument '%s' isn't a valid key=value pair " "$pair" >&2
            printf "and won't be applied\\n" >&2
            return 1
        else
            key=${pair%%=*}
            val="${pair#*=}"

            zz_set_var $dry_run_arg "$env_file" "$key" "$val" || return 1
        fi
    done
}

# Set variable in env file by default
# Arguments:
#  1 - Module to set by default
# Environment:
#  -
#
# Out:
#  -
#
# Exit status:
# Always true
zz_set_default () {
    declare -a default_config=( '#Default configuration' )

    for var_key in "${!module_envs[@]}"; do
        printf -v new_value '%s=%s' "${var_key}" "${module_envs[$var_key]%|*}"
        default_config+=("$new_value")
    done
    printf '%s\n' "${default_config[@]}" > "$1"
}

# Search for modules in a specific directory and offers them to the user to
# setup them
# Arguments:
#  1 - Directory to search modules from
#  2 - Current temp env file
#  3 - (Optional) list of modules to configure
wizard () {
    declare -r PS3='Do you want to configure modules? (Enter for quit): '
    declare -r search_prefix='*/cli/config/'
    declare -r suffix='.bash'

    declare -a modules config_modules
    declare reply
    read -r -a config_modules <<< "$3"

    for module in "${PROZZIE_CLI_CONFIG}"/*.bash; do
        if [[ "$module" == *base.bash ]]; then
            continue
        fi

        # Parameter expansion deletes '../cli/config/' and '.bash'
        module="${module#$search_prefix}"
        modules[${#modules[@]}]="${module%$suffix}"
    done

    while :; do
        if [[ -z ${3+x} ]]; then
            reply=$(zz_select "${modules[@]}")
        elif [[ ${#config_modules[@]} -gt 0 ]]; then
            reply=${config_modules[-1]}
        else
            reply=''
        fi

        if [[ -z ${reply} ]]; then
            break
        fi

        set +m  # Send SIGINT only to child
        "${PREFIX}"/bin/prozzie config setup ${reply}
        set -m
    done
}

# Set up connector in prozzie, asking the user the connector variables and
# applying them in the provided env file.
# Arguments:
#  1 - The connector name
#
# Environment:
#  module_envs - The variables to ask for, in form:
#    ([global_var]="default|description").
#
# Out:
#  User interface
#
# Note
#  It will call set with --no-reload-prozzie always, so the caller function
#  needs to reload it.
#
# Exit status:
#  Always 0
connector_setup () {
  declare var_key var_default var_prompt var_help
  declare -a new_connector_vars

  declare -r connector="$1"
  declare src_env_file
  src_env_file="$(connector_env_file "$connector")"
  declare -r src_env_file
  shift

  # shellcheck disable=SC2034
  declare zz_trap_stack
  zz_trap_push zz_trap_stack print_not_modified_warning EXIT

  # Check if the user previously provided the variables. In that case,
  # offer user to mantain previous value.
  if [[ -f "$src_env_file" ]]; then
    zz_variables_env_update_array "$src_env_file"
  else
    touch "$src_env_file"
  fi

  for var_key in "${!module_envs[@]}"; do
    IFS='|' read -r var_default var_prompt var_help < \
                                <(squash_spaces <<<"${module_envs[$var_key]}")

    if [[ ! -v "$var_key" && $var_help ]]; then
        printf "%s\\n" "$var_help"
    fi
    zz_variable "$connector" "$var_key" "$var_default" "$var_prompt"

    if [[ "${!var_key}" != \
            "$("${PREFIX}/bin/prozzie" config get "$connector" "${var_key}")" ]]; then
        new_connector_vars+=("${var_key}=${!var_key}")
    fi
  done

  "${PREFIX}/bin/prozzie" config set --no-reload-prozzie "$connector" \
                                                      "${new_connector_vars[@]}"

  # Hurray! app installation end!
  zz_trap_pop zz_trap_stack EXIT
}

# List enable modules
# Arguments:
#  [--quiet|-q] Only show modules
# Exit status:
#  Always 0
zz_list_enabled_modules() {
    [[ $# -lt 1 || ($1 != -q && $1 != --quiet) ]] && printf 'Enabled modules:\n'
    declare -r search_prefix='*/compose/'
    declare -r suffix='.yaml'

    # zz_trap_push/pop use this variable
    # shellcheck disable=SC2034
    declare zz_trap_stack
    # If can't write, return properly. It may be grep -q or similar.
    zz_trap_push zz_trap_stack 'return 0' SIGPIPE

    # Yaml modules
    for module in "${PREFIX}"/etc/prozzie/compose/*.yaml; do
        if [[ $module =~ /base.yaml$ ]]; then
            continue
        fi
        module=${module#$search_prefix}
        printf '%s\n' "${module%$suffix}"
    done

    # Kafka connect modules
    for module in $("${PREFIX}"/bin/prozzie kcli ps); do
        "${PREFIX}/bin/prozzie" kcli status "$module" | head -n 1 | \
                        grep -q 'RUNNING' && printf '%s\n' "$module"
    done

    zz_trap_pop zz_trap_stack SIGPIPE
}

##
## @brief      Prints description of every variable in module_envs and
##             module_hidden_envs environment variables via stdout.
##
## No Arguments
##
## Environment:
##  module_envs - Module's environment as usual
##  module_hidden_envs - Module's hidden environment as usual
##
## Out:
##  User interface
##
## @return     Always 0
##
zz_connector_show_vars_description () {
    declare -r not_pipe='[^\|]'
    declare var_key var_description

    # module_{hidden_}envs is supposed to be present when prozzie calls this
    # function
    # shellcheck disable=2154
    for var_key in "${!module_envs[@]}" "${!module_hidden_envs[@]}"; do
        var_description="${module_envs[$var_key]-${module_hidden_envs[$var_key]}}"
        # Variable description is in between '|'
        # Shellcheck say that we must replace '\' for '\\', but is simply wrong
        # shellcheck disable=1117
        var_description=$(sed \
                          "s%${not_pipe}*|\(${not_pipe}*\).*%\1%" \
                          <<<"$var_description" | squash_spaces)

        printf '\t%-40s%s\n' "${var_key}" "${var_description}"
    done
}
