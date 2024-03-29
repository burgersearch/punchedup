#!/usr/bin/env bash

# No errors allowed.

set -e

# Dependencies

if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "Empty env GITHUB_TOKEN"
    exit 1
fi

command -v jj >/dev/null 2>&1 || echo "You must have the JSON stream parser utility 'jj' installed and available in your PATH.
See https://github.com/tidwall/jj for more information."


# Persistence.

GHTD=$HOME/.gh_tasks
mkdir -p "$GHTD"

# -> $GH_TASK_STORAGE_DIR/projects/11/columns/1.json
# -> $GH_TASK_STORAGE_DIR/projects/11/columns/2.json

# API.

PROJECTS_API_PREVIEW_KEY="application/vnd.github.inertia-preview+json"


# Walkthrough:

# - get client project's columns
# - prompt to pick an available project column
# - prompts to CREATE card
#   - fill fields one by one
#   - edit document at end
# - confirm review card and push target
# - push

# Set a hardcoded project id.
# If this turns out to be a useful script,
# then fetching and choosing projects should be added to the workflow.
#project_id=3359007 # etclabscore/client project


PROJECTS=()
select_projects () {
  local org
  org=$(get_org)
  fetch_projects $org
  process_available_projects $org
  select project in "${PROJECTS[@]%%:*}"; do
    if [ -n "$project" ]; then
        echo "selecting project $project" 
        project_id=${PROJECTS[$REPLY - 1]#*:}
        echo "set project id to ${project_id}"
    fi
    break
done
}

get_org () 
{
  local orgs=("etclabscore" "open-rpc")
  select org in "${orgs[@]}"; do
    if [ -n "$org" ]; then
      echo "$org"
    fi
    break;
  done
}

fetch_projects() {
    local _org="$1"
    echo $_org
    mkdir -p ${GHTD}/orgs/${_org}/projects
    rm -rf ${GHTD}/orgs/${_org}/projects/* # Remove all existing column documents. This is kind of ugly, but ensures no dead columns.

    curl >${GHTD}/orgs/${_org}/projects/.response 2>&1 \
        --silent \
        --show-error \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: $PROJECTS_API_PREVIEW_KEY" \
        -D "${GHTD}/.response-header" \
        https://api.github.com/orgs/${_org}/projects


}

process_available_projects() {
    local _org="$1"
    local _d=${GHTD}/orgs/${_org}/projects
    local _responsef=${_d}/.response
    local _n=0
    local _max

    _max=$(jj -i $_responsef '#')
    while [[ $_n -lt $_max ]]; do
        _j_cmd=/"$(which jj) -i $_responsef -n $_n"
        [[ ! -z $($_j_cmd) ]] || break

        _project_id="$($_j_cmd.id)" # HACK
        _name="$($_j_cmd.name)" # HACK
        PROJECTS+=("${_name}:${_project_id}")
        _n=$((_n + 1))
    done
}

fetch_columns_for_project() {

    local _project_id="$1"

    mkdir -p ${GHTD}/projects/${_project_id}/columns/
    rm -rf ${GHTD}/projects/${_project_id}/columns/* # Remove all existing column documents. This is kind of ugly, but ensures no dead columns.

    curl >${GHTD}/projects/${_project_id}/columns/.response 2>&1 \
        --silent \
        --show-error \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: $PROJECTS_API_PREVIEW_KEY" \
        -D "${GHTD}/.response-header" \
        https://api.github.com/projects/$_project_id/columns


}

process_columns_for_project() {
    local _project_id="$1"
    local _d=${GHTD}/projects/${_project_id}/columns
    local _responsef=${_d}/.response

    local _n=0
    local _max
    _max=$(jj -i $_responsef '#')

    while [[ $_n -lt $_max ]]; do
        echo "Processing column index $_n"
        _j_cmd=/"$(which jj) -i $_responsef -n $_n"
        [[ ! -z $($_j_cmd) ]] || break

        _column_id="$($_j_cmd.id)" # HACK

        $_j_cmd >"${_d}/${_column_id}.json"

        _n=$((_n + 1))
    done

    local _n_columns=$(find ${GHTD}/projects/${_project_id}/columns/ -type f -name '*.json' | wc -l)
    if [[ $_n_columns -eq 0 ]]; then
        echo "Did not find any columns for this project."
        echo "Please check your authentication (env GITHUB_TOKEN), and the (currently hardcoded) project id."
        echo "  Note that the project id is NOT the number you're seeing it the HTML URL; it must be obtained via the API."
        exit 1
    fi
}

get_project_columns() {
    local _project_id="$1"
    fetch_columns_for_project $_project_id
    process_columns_for_project $_project_id
}

human_read_github_link()
{
    # https://github.com/etclabscore/multi-geth/issues/40 -> etclabscore multi-geth issues #40

    link="$1"

    if ! grep -q 'github.com' <<< "$link"; then
	    echo "$link"
	    return
    fi

    link=${link#https://github.com/}

    local _refid=$(basename "$link")

    if [[ $((RANDOM % 3)) -eq 0 ]]; then
        link=${link/$_refid/$_refid}
    else
        link=${link/$_refid/'#'$_refid}
    fi

    link=$(echo $link | tr / ' ')

    if [[ $((RANDOM % 2)) -eq 0 ]]; then
        link=${link/etclabscore/}
        link=${link/pull/pr}
    else
        link=${link/pull/pull request}
    fi

    if [[ $((RANDOM % 2)) -eq 0 ]]; then
        link=${link/issues/Issue}
    fi

    if [[ $((RANDOM % 5)) -eq 0 ]]; then
        link=${link/pr/}
        link=${link/issue/}
    fi

    echo $link
}

input_new_task_card() {
    mkdir -p $GHTD/newtasks/
    task_store=$GHTD/newtasks/$(date +'%FT%T').txt

    read -p "Task: " task_tracker
    read -p "Effort estimation: " effort_estimate

    start_date="$(date +'%F')"
    local r=$((RANDOM))
    if [[ $((r % 3)) ]]; then
        start_date="$(date +'%D')"
    elif [[ $((r % 13)) ]]; then
        start_date="$(date +'%A %B')"
    fi

    read -p "Effort spent: " effort_spent
    read -p "Reference (issue or PR): " reference

    echo "Task: $task_tracker
Effort estimation: $effort_estimate
Start date: $start_date
Effort spent: $effort_spent" >$task_store

    echo Reference: $(human_read_github_link $reference) >> $task_store

    vim $task_store <$(tty) >$(tty)

    echo $task_store
}

select_column_id_for_project() {
    local _project_id="$1"

    [[ -z "$_project_id" ]] && echo Column select received empty project id && exit 1

    column_names=()
    column_ids=()

    local _column_id="" # Selected column id

    for f in ${GHTD}/projects/${_project_id}/columns/*.json; do
        name=$(cat "$f" | jj name)
        id=$(cat "$f" | jj id)
        column_names+=("$name [$id]")
        column_ids+=("$id")
    done

    PS3='Please choose a column: '
    # options=("Option 1" "Option 2" "Option 3" "Quit")
    select opt in "${column_names[@]}"; do
        case $opt in
        *)
            col=${column_ids[$((REPLY - 1))]}
            if [[ !  -z $col ]]; then
                echo ${column_ids[$((REPLY - 1))]}
                break
             fi
            ;;
        esac
    done

    echo $_column_id
}

with_confirm_post_task() {

    local _project_id="$1"
    local _column_id="$2"
    local _task_store="$3"

    echo
    echo "Project ID: $1"
    echo "Column ID: $2"
    echo "New task ($3):"
    echo
    while read -r line; do
        echo "    $line"
    done <$3
    echo

    while true; do
        read -p "Do you wish to post this card?" yn
        case $yn in
        [Yy]*)
            post_task $1 $2 $3
            break
            ;;
        [Nn]*) exit ;;
        *) echo "Please answer yes or no." ;;
        esac
    done
}

post_task() {

    local _project_id="$1"
    local _column_id="$2"
    local _task_store="$3"

    # Assemble raw .txt as {note: file.txt} object,
    # storing it in own file
    echo '' | jj -v "$(cat $_task_store)" note > $_task_store.json

    echo curl -X POST w/ $_project_id $_column_id $_task_store...

    curl >${GHTD}/.response.json -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: $PROJECTS_API_PREVIEW_KEY"  \
        -H "Content-Type: application/json" \
       --data @$_task_store.json \
       https://api.github.com/projects/columns/$_column_id/cards

    local _card_id=$(cat ${GHTD}/.response.json | jj id)

    # Ensure dirs exist.
    mkdir -p ${GHTD}/projects/${_project_id}/columns/${_column_id}/cards

    # Copy response JSON (describing the newly created card) to our store for safekeeping.
    # Maybe later we'll want to add UPDATE functionality, and these may become kind of useful...?
    cp ${GHTD}/.response.json ${GHTD}/projects/${_project_id}/columns/${_column_id}/cards/${_card_id}.json
}

select_projects
get_project_columns $project_id
task_store=$(input_new_task_card)
column_id=$(select_column_id_for_project $project_id)
with_confirm_post_task $project_id $column_id $task_store
